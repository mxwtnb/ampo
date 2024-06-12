// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol"; // TODO: Use test/utils/CurrencySettler.sol instead?
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title   AmpoHook
 * @author  mxwtnb
 * @notice  Auction-managed perpetual options
 *
 *          A Uniswap V4 hook that lets users trade perpetual options.
 *
 *          Perpetual options are options that never expire and can be exercised at any point in the future.
 *          They can be synthetically constructed by borrowing a narrow Uniswap concentrated liquidity
 *          position and withdrawing the tokens inside it. Users with an open perpetual options position
 *          pay funding each block, analogous to funding on perpetual futures.
 *
 *          The pricing of these options is auction-managed. A continuous auction is run where anyone can
 *          place bids and modify their bids at any time. The current highest bidder is called the
 *          manager. The manager pays their bid amount, called rent, each block to LPs. In return, they
 *          get to set the funding rate for options holders and receive funding from all options positions
 *          as well as LP fees from all swaps (like in the auction-managed AMM).
 *
 *          In summary:
 *          - Managers pay rent to LPs each block
 *          - Managers receive funding from options holders each block
 *          - Managers receive LP fees each swap
 *
 *          Managers are therefore able to make a profit if they can set the funding in a smart way, not
 *          too low which leaves potential income on the table and not too high which discourages users
 *          from buying and holding options. They are incentivized to come up with better ways to
 *          calculate the best funding in order to maximise their profit and be able to bid more in the
 *          manager auction. With a set of competitive managers who are constantly trying to outbid each
 *          other, the system should be able to find the best funding rate for options holders and most
 *          of the potential revenue should flow to LPs.
 */
contract AmpoHook is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error CannotWithdrawMoreThanDeposited();
    error CanOnlyModifyLiquidityViaHook();
    error InvalidTickRange();
    error NotDynamicFee();
    error NotEnoughDeposit();
    error NotLiquidatable();
    error OnlyManager();

    /// @notice Parameters that need to be specified when initializing a pool.
    /// `tickLower` and `tickUpper` specify a concentrated range that all LP deposits must use.
    /// They correspond to the strike price of the call and put options minted from the pool.
    /// The range should be wide enough to reliably capture fees when the price is in that
    /// area but narrow enough to provide enough leverage.
    /// @dev Dynamic fee flag needs to be set in the pool key so we have to pass in the `lpFee` here.
    struct InitializeParams {
        int24 tickLower; // Lower tick of the fixed liquidity range
        int24 tickUpper; // Upper tick of the fixed liquidity range
        uint24 lpFee; // Fixed LP fee as a multiple of 1_000_000
        bool payInTokenZero; // Whether rent and funding are paid in token0 or token1
    }

    /// @notice State stored for each pool.
    struct PoolState {
        int24 tickLower;
        int24 tickUpper;
        uint24 lpFee;
        bool payInTokenZero;
        address manager; // The highest bidder in the auction who sets the funding rate. 0x0 if no manager set.
        uint256 rent; // Amount paid per block by the manager to LPs
        uint256 fundingRate; // Amount paid per block per option by option holders to the manager
        uint256 cumulativeFunding; // Keeps track of the sum of `fundingRate` across all blocks
        uint256 lastCumulativeFundingUpdateBlock; // Last block `cumulativeFunding` was updated
        uint256 amount0PerLiquidity; // Amount of token0 per 1e18 liquidity
        uint256 amount1PerLiquidity; // Amount of token1 per 1e18 liquidity
    }

    /// @notice Data passed to `PoolManager.unlock` when modifying liquidity.
    struct CallbackData {
        PoolKey key;
        address sender;
        int256 liquidityDelta;
        int256 paymentFromThis0; // Pay `sender` from this contract's token0 claims
        int256 paymentFromThis1; // Pay `sender` from this contract's token1 claims
        uint256 rentAmount; // Amount of rent to pay to LPs from the manager
    }

    /// @notice When manager bids, they must deposit enough to cover the rent for this period.
    /// Period is in blocks.
    uint256 public constant MIN_DEPOSIT_PERIOD = 300;

    /// @notice If a user's balance can't cover payments for this period, they can be liquidated.
    /// Period is in blocks.
    uint256 public constant MIN_HEALTHY_PERIOD = 100;

    mapping(PoolId => PoolState) public pools;

    /// @notice Cumulative funding at the last time the user was charged. Used to keep track of
    /// how much funding the user owes to the manager.
    mapping(PoolId => mapping(address => uint256)) public cumulativeFundingAtLastCharge;

    // @notice Block at which user was last charged rent and funding.
    mapping(PoolId => mapping(address => uint256)) public lastPaymentBlock;

    /// @notice How much tokens user has deposited into the contract. This is in token0 if `payInTokenZero`
    /// is true and token1 otherwise.
    mapping(PoolId => mapping(address => uint256)) public balanceOf;
    mapping(PoolId => uint256) public totalSupply;

    /// @notice How much liquidity is held by the hook on behalf of each user.
    /// @dev Hook needs to own all the liquidity so that it's able to withdraw it when options are minted.
    mapping(PoolId => mapping(address => uint256)) public liquidityOf;

    /// @notice Position sizes of token0 call and token1 call of each user.
    mapping(PoolId => mapping(address => uint256)) public positions0;
    mapping(PoolId => mapping(address => uint256)) public positions1;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /// @notice Specify hook permissions. Hook implements `beforeInitialize`, `beforeAddLiquidity`
    /// and `beforeSwap`. `beforeSwapReturnDelta` is also set to charge custom swap fees that go
    /// to the manager instead of LPs.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Ensure dynamic fee flag is set and the given `hookData` is valid and set up initial
    /// pool state.
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata hookData)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        // Parse hook data to get the tick range. This is a fixed range that every LP deposit must use.
        InitializeParams memory params = abi.decode(hookData, (InitializeParams));

        // Check tick range is valid
        if (params.tickLower >= params.tickUpper) revert InvalidTickRange();
        if (params.tickLower % key.tickSpacing != 0 || params.tickUpper % key.tickSpacing != 0) {
            revert InvalidTickRange();
        }

        // Initialize pool state
        PoolId poolId = key.toId();
        pools[poolId] = PoolState({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            lpFee: params.lpFee,
            payInTokenZero: params.payInTokenZero,
            manager: address(0),
            rent: 0,
            fundingRate: 0,
            cumulativeFunding: 0,
            lastCumulativeFundingUpdateBlock: 0,
            amount0PerLiquidity: 0,
            amount1PerLiquidity: 0
        });

        // Precalculate the amounts per liquidity. These values are used later on when users mint or
        // burn options.
        pools[poolId].amount0PerLiquidity = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtPriceAtTick(params.tickLower), TickMath.getSqrtPriceAtTick(params.tickUpper), 1e18
        );
        pools[poolId].amount1PerLiquidity = LiquidityAmounts.getAmount1ForLiquidity(
            TickMath.getSqrtPriceAtTick(params.tickLower), TickMath.getSqrtPriceAtTick(params.tickUpper), 1e18
        );
        return this.beforeInitialize.selector;
    }

    /// @notice Revert if user tries to add liquidity without doing it via this hook's `modifyLiquidity` method.
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        poolManagerOnly
        returns (bytes4)
    {
        revert CanOnlyModifyLiquidityViaHook();
    }

    /// @notice Redirect swap fees to the manager of the pool.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolState storage pool = pools[key.toId()];
        address manager = pool.manager;

        // Poke manager's balance so they pay rent
        _pokeUserBalance(key, manager);

        // If no manager is set, just pass fees to LPs like a standard Uniswap pool
        if (manager == address(0)) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), pool.lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Calculate swap fees. The fees don't go to LPs, they instead go to the manager of the pool
        int256 fees = params.amountSpecified * uint256(pool.lpFee).toInt256() / 1e6;
        int256 absFees = fees > 0 ? fees : -fees;

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in
        // so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne ? key.currency0 : key.currency1;

        // Send fees to manager
        feeCurrency.take(poolManager, manager, absFees.toUint256(), true);

        // Override LP fee to zero
        return (this.beforeSwap.selector, toBeforeSwapDelta(absFees.toInt128(), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Bid in the auction to become the manager of a pool or modify the bid if already the manager.
    /// @param key The pool to bid in
    /// @param rent The amount of tokens to pay per block to LPs. The token is determined by `payInTokenZero`
    function bid(PoolKey calldata key, uint256 rent) external {
        // Poke so user's balance is up-to-date
        _pokeUserBalance(key, msg.sender);

        PoolId poolId = key.toId();
        if (balanceOf[poolId][msg.sender] < rent * MIN_DEPOSIT_PERIOD) {
            revert NotEnoughDeposit();
        }

        PoolState storage pool = pools[poolId];
        if (pool.manager == msg.sender) {
            // Modify or cancel bid
            pool.rent = rent;
        } else if (rent > pool.rent) {
            // Ensure current manager's balance and payments are up-to-date
            _pokeUserBalance(key, pool.manager);

            // Usurp current manager
            pool.manager = msg.sender;
            pool.rent = rent;
        }
    }

    /// @notice Deposit tokens into this contract. Deposits are used to cover rent payments
    /// as the manager or funding payments as an options holder. Deposits are in token0 if `payInTokenZero`
    /// is true and token1 otherwise.
    /// @dev Deposits are split by pool to simplify calculating whether a user can be liquidated.
    /// @param key The pool for which the deposit will be used
    function deposit(PoolKey calldata key, uint256 amount) external {
        PoolState storage pool = pools[key.toId()];
        balanceOf[key.toId()][msg.sender] += amount;
        totalSupply[key.toId()] += amount;
        Currency currency = pool.payInTokenZero ? key.currency0 : key.currency1;
        IERC20(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw tokens from this contract that were previously deposited with `deposit`.
    /// @param key The pool specified in the deposit
    /// @param amount The amount to withdraw
    function withdraw(PoolKey calldata key, uint256 amount) external {
        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

        // Get user's up-to-date balance
        uint256 balance = _pokeUserBalance(key, msg.sender);

        // Check user has enough balance to withdraw
        if (amount > balance) {
            revert CannotWithdrawMoreThanDeposited();
        }

        balanceOf[poolId][msg.sender] -= amount;
        totalSupply[poolId] -= amount;
        Currency currency = pool.payInTokenZero ? key.currency0 : key.currency1;
        IERC20(Currency.unwrap(currency)).transfer(msg.sender, amount);
    }

    /// @notice Get user's balance in this contract for a given pool. Unlike `balanceOf`, this takes
    /// into account rent and funding payments.
    /// @param key The pool to get the balance for
    /// @param user The user to get the balance of
    function getBalance(PoolKey calldata key, address user) external view returns (uint256 balance) {
        balance = balanceOf[key.toId()][user];
        (uint256 rentOwed, uint256 fundingOwed) = _calcRentOwedAndFundingOwed(key, user);

        // Subtract amount owed from balance
        uint256 totalOwed = rentOwed + fundingOwed;
        if (totalOwed > balance) totalOwed = balance;
        balance -= totalOwed;
    }

    /// @notice Called by users to deposit or withdraw liquidity from the pool. This method should be
    /// used instead of the default modifyLiquidity in the PoolManager.
    /// @dev This is needed so this contract owns all the liquidity and can withdraw it whenever an option is minted.
    /// @param key The pool to modify liquidity in
    /// @param liquidityDelta The change in liquidity - positive means deposit and negative means withdraw
    function modifyLiquidity(PoolKey calldata key, int256 liquidityDelta) public payable returns (BalanceDelta delta) {
        // Poke manager's balance so they pay rent
        _pokeUserBalance(key, pools[key.toId()].manager);

        // Poke user's balance to update funding
        _pokeUserBalance(key, msg.sender);

        delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(key, msg.sender, liquidityDelta, 0, 0, 0))), (BalanceDelta)
        );

        // Calculate new position. Ensure it's positive, i.e. the user is not withdrawing more than they deposited
        int256 liquidity_ = liquidityOf[key.toId()][msg.sender].toInt256() + liquidityDelta;
        if (liquidity_ < 0) revert CannotWithdrawMoreThanDeposited();
        liquidityOf[key.toId()][msg.sender] = liquidity_.toUint256();

        // Sweep any native ETH balance to the user
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    /// @notice Called by the manager of a pool to set the options funding rate
    /// @param key The pool to set the funding rate in
    /// @param fundingRate The new funding rate
    // TODO: Add sanity checks on funding
    // TODO: Override funding rate if utilization ratio too high so LPs can withdraw
    function setFundingRate(PoolKey calldata key, uint256 fundingRate) external {
        PoolState storage pool = pools[key.toId()];

        // Only manager can set funding
        if (msg.sender != pool.manager) revert OnlyManager();

        // Update cumulative funding
        pool.cumulativeFunding = _calcCumulativeFunding(key);
        pool.lastCumulativeFundingUpdateBlock = block.number;
        pool.fundingRate = fundingRate;
    }

    /// @notice Called by a user to modify their options position in a pool. There are two types of
    /// options supported: token0 calls and token1 calls. `positionDelta0` and `positionDelta1` are
    /// used to modify the user's position in each type of option. Positive values mean open position
    /// and negative values mean close or exercise the position.
    /// Note that put options are also supported. A token0 put is equivalent to a token1 call and a
    /// token1 put is equivalent to a token0 call.
    /// @param key The pool to modify the position in
    /// @param positionDelta0 The change in position0
    /// @param positionDelta1 The change in position1
    /// @return delta The change in the user's balance in the two tokens
    function modifyOptionsPosition(PoolKey calldata key, int256 positionDelta0, int256 positionDelta1)
        external
        returns (BalanceDelta delta)
    {
        // Poke manager's balance so they pay rent
        _pokeUserBalance(key, pools[key.toId()].manager);

        // Poke user's balance to update funding
        _pokeUserBalance(key, msg.sender);

        delta = _modifyOptionsPositionForUser(key, positionDelta0, positionDelta1, msg.sender);
    }

    /// @notice Internal method called by `modifyOptionsPosition` and `liquidate` to modify a user's
    /// options position. For out-of-the-money perpetual options, the upfront cost is zero.
    /// For in-the-money options, the user has to deposit the difference between the strike price and
    /// the current price.
    ///
    /// Example 1: The ETH/DAI pool uses a narrow range around 3000 and the current price is 2000.
    /// If a user wants to buy 1 ETH call, they don't have to pay anything upfront. The hook will
    /// withdraw 1 ETH from the pool and store it as a claim token in the Uniswap PoolManager. Let's say
    /// the price rises to 4000 and the user exercises their option. The hook will give them the 1 ETH
    /// and will receive 3000 DAI from them (so user makes $1000 profit) and can deposit the 3000 DAI
    /// back, replenishing the liquidity.
    ///
    /// Example 2: The current price is 4000. If a user wants to buy 1 ETH call, they have to deposit
    /// 1 ETH into the hook. The hook will withdraw 3000 DAI from the pool and send it to the user, so
    /// the user has only paid $1000 upfront for the option. If the price rises to 5000 and the user
    /// exercises their option, the hook will give them 1 ETH and will receive 3000 DAI from them (so
    /// user makes $1000 profit) and can deposit the 3000 DAI back as liquidity.
    function _modifyOptionsPositionForUser(
        PoolKey calldata key,
        int256 positionDelta0,
        int256 positionDelta1,
        address user
    ) internal returns (BalanceDelta delta) {
        // Calculate notional values of token0 and token1. For example, the notional value of 2 ETH calls
        // is 2 ETH. This is used to calculate how much tokens the hook needs to settle or take from the
        // user to ensure it is fully collateralized.
        int256 positionDelta = positionDelta0 + positionDelta1;
        int256 absPositionDelta0 = positionDelta0 > 0 ? positionDelta0 : -positionDelta0;
        int256 absPositionDelta1 = positionDelta1 > 0 ? positionDelta1 : -positionDelta1;
        uint256 notional0 = absPositionDelta0.toUint256() * pools[key.toId()].amount0PerLiquidity / 1e18;
        uint256 notional1 = absPositionDelta1.toUint256() * pools[key.toId()].amount1PerLiquidity / 1e18;

        // Call `PoolManager.unlock` which will call `unlockCallback` in this hook to settle or take tokens
        delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(key, user, -positionDelta.toInt128(), -notional0.toInt256(), -notional1.toInt256(), 0)
                )
            ),
            (BalanceDelta)
        );

        // Update positions
        positions0[key.toId()][user] = (positions0[key.toId()][user].toInt256() + positionDelta0).toUint256();
        positions1[key.toId()][user] = (positions1[key.toId()][user].toInt256() + positionDelta1).toUint256();

        // Sweep any native ETH balance to the user
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(user, ethBalance);
        }
    }

    /// @notice Liquidate a user if their balance can't cover payments for a certain period.
    /// Reverts if the user's balance is healthy enough. Can be called by anyone and rewards them
    /// if the liquidation is successful. Note that this liquidation is significantly less risky than
    /// liquidations in lending protocols or perp dexs as user's balance doesn't fluctuate with price
    /// movements but only decreases gradually as funding and rent are continuously charged.
    /// @param key Pool for which user's balance is liquidated
    /// @param user User to liquidate
    function liquidate(PoolKey calldata key, address user) external {
        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

        // Get updated balance
        uint256 balance = _pokeUserBalance(key, user);

        // Calculate how much the user pays each block
        uint256 paymentPerBlock = 0;
        bool isManager = user == pool.manager;
        if (isManager) {
            // Add rent payment if the user is the manager of the pool
            paymentPerBlock += pool.rent;
        }

        // Add funding payment if user has options position open
        paymentPerBlock += pool.fundingRate * positions0[poolId][user];
        paymentPerBlock += pool.fundingRate * positions1[poolId][user];

        // Check the user can be liquidated, i.e. their balance is insufficient to cover payments
        // for `MIN_HEALTHY_PERIOD` blocks
        if (balance >= paymentPerBlock * MIN_HEALTHY_PERIOD) {
            revert NotLiquidatable();
        }

        // If the user is the manager, kick them out
        if (isManager) {
            pool.manager = address(0);
        }

        // Force close their options positions
        _modifyOptionsPositionForUser(
            key, -positions0[poolId][user].toInt256(), -positions1[poolId][user].toInt256(), user
        );

        // The liquidated user's balance is set to zero and their balance is given to the caller
        // as a reward
        balanceOf[poolId][user] = 0;
        balanceOf[poolId][msg.sender] += balance;
    }

    /// @notice Callback function for PoolManager to modify liquidity or transfer tokens
    /// `liquidityDelta` being non-zero means modifying the liquidity in the position.
    /// `paymentFromThis0` and `paymentFromThis1` are used to transfer tokens between this contract and
    /// the user.
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolState storage pool = pools[data.key.toId()];

        // Calculate deltas. Positive means user gets tokens, negative means user gives tokens.
        int256 delta0 = data.paymentFromThis0;
        int256 delta1 = data.paymentFromThis1;

        // Also modify liquidity if `liquidityDelta` is non-zero
        if (data.liquidityDelta != 0) {
            // Create params for `PoolManager.modifyLiquidity`
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: pool.tickLower,
                tickUpper: pool.tickUpper,
                liquidityDelta: data.liquidityDelta,
                salt: ""
            });

            (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, params, "");
            delta0 += delta.amount0();
            delta1 += delta.amount1();
        }

        // Settle and take tokens from user
        _settleOrTake(data.key, data.sender, delta0, delta1, false);

        // Settle and take tokens from this contract as claim tokens
        _settleOrTake(data.key, address(this), -data.paymentFromThis0, -data.paymentFromThis1, true);

        // Distribute rent to LPs
        if (data.rentAmount > 0) {
            uint256 rentOwed0 = pool.payInTokenZero ? data.rentAmount : 0;
            uint256 rentOwed1 = pool.payInTokenZero ? 0 : data.rentAmount;

            // Send to all LPs
            poolManager.donate(data.key, rentOwed0, rentOwed1, "");

            // Take rent amount from this contract
            _settleOrTake(data.key, address(this), -rentOwed0.toInt256(), -rentOwed1.toInt256(), false);
        }

        return abi.encode(toBalanceDelta(int128(delta0), int128(delta1)));
    }

    /// @notice Calls settle or take depending on the signs of `delta0` and `delta1`
    function _settleOrTake(PoolKey memory key, address user, int256 delta0, int256 delta1, bool useClaims) internal {
        if (delta0 < 0) key.currency0.settle(poolManager, user, uint256(-delta0), useClaims);
        if (delta1 < 0) key.currency1.settle(poolManager, user, uint256(-delta1), useClaims);
        if (delta0 > 0) key.currency0.take(poolManager, user, uint256(delta0), useClaims);
        if (delta1 > 0) key.currency1.take(poolManager, user, uint256(delta1), useClaims);
    }

    /// @notice Update user's balance by charging them rent if they are the manager and funding
    /// if they have an open options position.
    function _pokeUserBalance(PoolKey calldata key, address user) internal returns (uint256 balance) {
        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

        (uint256 rentOwed, uint256 fundingOwed) = _calcRentOwedAndFundingOwed(key, user);

        // Give funding to manager
        if (fundingOwed > 0) {
            balanceOf[poolId][pool.manager] += fundingOwed;
        }

        // Deduct rent and funding from user balance
        balance = balanceOf[poolId][user];
        uint256 totalOwed = rentOwed + fundingOwed;
        if (totalOwed > balance) totalOwed = balance;
        balance -= totalOwed;
        balanceOf[poolId][user] = balance;

        // Update blocks on which user was last charged rent and funding
        lastPaymentBlock[poolId][user] = block.number;

        // If user is the manager, pay rent to LPs
        if (rentOwed > 0) {
            poolManager.unlock(abi.encode(CallbackData(key, user, 0, 0, 0, rentOwed)));
        }

        // If user is the manager and they has no collateral left, kick them out
        if (user == pool.manager && balanceOf[poolId][user] == 0) {
            pool.manager = address(0);
        }
    }

    /// @notice Calculate rent and funding owed by a user in a pool since the last time these were
    /// deducted from the `balanceOf` variable.
    function _calcRentOwedAndFundingOwed(PoolKey calldata key, address user)
        internal
        view
        returns (uint256 rentOwed, uint256 fundingOwed)
    {
        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];
        uint256 blocksSinceLastPayment = block.number - lastPaymentBlock[poolId][user];

        // Calculate rent payments if user is the manager
        if (user == pool.manager) {
            rentOwed = pool.rent * blocksSinceLastPayment;
        }

        // Calculate funding payments if user has an open options position
        uint256 position = positions0[poolId][user] + positions1[poolId][user];
        if (position > 0) {
            uint256 fundingSinceLastCharge = _calcCumulativeFunding(key) - cumulativeFundingAtLastCharge[poolId][user];
            fundingOwed = fundingSinceLastCharge * position * blocksSinceLastPayment;
        }
    }

    /// @notice Calculate the cumulative funding of a pool. This is the sum of the funding rate
    /// across all blocks in the past. For example, if the current funding rate is 0.0001, after 100 blocks the
    /// cumulative funding would increase by 0.01.
    function _calcCumulativeFunding(PoolKey calldata key) internal view returns (uint256) {
        PoolState storage pool = pools[key.toId()];
        uint256 blocksSinceLastUpdate = block.number - pool.lastCumulativeFundingUpdateBlock;
        return pool.cumulativeFunding + blocksSinceLastUpdate * pool.fundingRate;
    }
}
