// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

// TODO: Remove
import {console2} from "forge-std/console2.sol";

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
 * @title   AuctionManagedOptionsHook
 * @author  mxwtnb
 * @notice  A Uniswap V4 hook that lets users trade perpetual options.
 *
 *          Perpetual options are options that never expire and can be exercise at any point in the future.
 *          They can be synthetically constructed by borrowing a narrow Uniswap concentrated liquidity
 *          position, withdrawing it and swapping for one of the tokens. Users with an open
 *          perpetual options position pay funding each block, similar to funding on perpetual futures.
 *
 *          The pricing of these options is auction-managed. A continuous auction is run
 *          where anyone can bid for the right to change the funding rate and to receive funding from
 *          open options positions. The amount they bid is called the rent and is distributed among in-range LPs
 *          each block. Managers are therefore incentivized to set the funding in a way that maximizes
 *          their profit and most of their profits go to LPs via the auction mechanism.
 */
contract AuctionManagedOptionsHook is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error ModifyLiquidityViaHookOnly();
    error CannotWithdrawMoreThanDeposited();
    error InvalidTickRange();
    error NotDynamicFee();
    error NotEnoughDeposit();
    error NotLiquidatable();
    error OnlyManager();

    /// @notice Parameters that need to be specified when initializing a pool.
    /// `tickLower` and `tickUpper` determine a concentrated liquidity range that all LP deposits
    /// must use.
    struct InitializeParams {
        int24 tickLower;
        int24 tickUpper;
        uint24 lpFee;
        bool payInTokenZero;
    }

    /// @notice State stored for each pool
    struct PoolState {
        int24 tickLower;
        int24 tickUpper;
        uint24 lpFee;
        bool payInTokenZero;
        uint256 notionalPerLiquidity; // Used for calculations when minting and burning options
        address manager;
        uint256 rent; // Rent is amount of ETH paid per block by the manager to LPs
        uint256 fundingRate; // Funding rate is amount of ETH paid per block per option by option holders to the manager
        uint256 cumulativeFunding; // Cumulative funding keeps track of the sum of `fundingRate` across all blocks
        uint256 lastCumulativeFundingUpdateBlock; // Last block `cumulativeFunding` was updated
    }

    /// @notice Data passed to `PoolManager.unlock` when modifying liquidity
    struct CallbackData {
        PoolKey key;
        address sender;
        int256 liquidityDelta;
        int256 delta0; // Allows additional token0 to be settled or taken
        int256 delta1; // Allows additional token1 to be settled or taken
    }

    /// @notice When manager bids, they must deposit enough to cover the rent for this period.
    /// Period is in blocks.
    uint256 public constant MIN_DEPOSIT_PERIOD = 300;

    /// @notice If a user's balance can't cover payments for this period, they can be liquidated.
    /// Period is in blocks.
    uint256 public constant MIN_HEALTHY_PERIOD = 100;

    /// @notice Use LP fee of 30 bps when there's no manager.
    uint24 public constant LP_FEE_WHEN_NO_MANAGER = 3_000 | LPFeeLibrary.OVERRIDE_FEE_FLAG;

    mapping(PoolId => PoolState) public pools;

    /// @notice When a pool is initialized with this hook, the fixed range must be specified.
    // mapping(PoolId => int24) public tickLower;
    // mapping(PoolId => int24) public tickUpper;

    /// @notice Store notional value of option. This is the amount of token0 that user
    /// will receive if they exercise the option. For example, if the pool is the ETH/DAI pool
    /// and token0 is ETH, then the notional value of 1 option would just be 1 ETH.
    /// Here, `amount`, the amount of options, is specified in liquidity units so the notional
    /// value is calculated by seeing how much the LP position that was withdrawn would be
    /// worth if it's completely in terms of token0.
    // mapping(PoolId => uint256) public notionalPerLiquidity;

    /// @notice The "Manager" of a pool is the highest bidder in the auction who has the sole right to set the option funding rate.
    /// The manager can be changed by submitting a higher bid. Set to 0x0 if no manager is set.
    // mapping(PoolId => address) public manager;

    /// @notice "Rent" is the amount of ETH that the manager pays to LPs per block
    // mapping(PoolId => uint256) public rent;

    /// @notice Block at which rent was last charged. Used to keep track of how much rent the manager owes.
    // mapping(PoolId => mapping(address => uint256)) public lastRentPaidBlock;

    /// @notice Current funding rate of the pool. This is the amount option holders pay per block to the manager.
    /// It can be changed at any time by the manager.
    // mapping(PoolId => uint256) public fundingRate;

    /// @notice Cumulative funding of the pool. This is the sum of `fundingRate` across all blocks.
    // mapping(PoolId => uint256) public cumulativeFunding;

    /// @notice Block at which `cumulativeFunding` was last updated
    // mapping(PoolId => mapping(address => uint256)) public lastFundingPaidBlock;

    /// @notice Cumulative funding at the last time the user was charged. Used to keep track of
    /// how much funding the user owes to the manager.
    mapping(PoolId => mapping(address => uint256)) public cumulativeFundingAtLastCharge;

    // @notice Block at which user was last charged rent and funding.
    mapping(PoolId => mapping(address => uint256)) public lastPaymentBlock;

    /// @notice How much ETH user has deposited into the contract.
    // TODO: Add totalSupply
    mapping(PoolId => mapping(address => uint256)) public balances;

    mapping(PoolId => mapping(address => uint256)) public liquidity;

    /// @notice User's options position size.
    mapping(PoolId => mapping(address => uint256)) public positions0;
    mapping(PoolId => mapping(address => uint256)) public positions1;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /// @notice Specify hook permissions. Hook implements `beforeInitialize`, `beforeAddLiquidity`
    /// and `beforeSwap`. `beforeSwapReturnDelta` is also set to charge custom swap fees that go
    /// to the manager.
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

    /// @notice Check dynamic fee flag is set and set up initial pool state.
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
            notionalPerLiquidity: 0,
            manager: address(0),
            rent: 0,
            fundingRate: 0,
            cumulativeFunding: 0,
            lastCumulativeFundingUpdateBlock: 0
        });

        // Precalculate the notional value per liquidity. This is used later on when
        // users mint or burn options.
        pools[poolId].notionalPerLiquidity = LiquidityAmounts.getAmount0ForLiquidity(
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
        revert ModifyLiquidityViaHookOnly();
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
        return (this.beforeSwap.selector, toBeforeSwapDelta(-fees.toInt128(), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function bid(PoolKey calldata key, uint256 rent) external {
        PoolId poolId = key.toId();
        if (balances[poolId][msg.sender] < rent * MIN_DEPOSIT_PERIOD) {
            revert NotEnoughDeposit();
        }

        PoolState storage pool = pools[poolId];
        if (pool.manager == msg.sender) {
            // Modify or cancel bid
            pool.rent = rent;
        } else if (rent > pool.rent) {
            // Submit new highest bid
            address prevManager = pool.manager;
            _pokeUserBalance(key, prevManager);

            pool.manager = msg.sender;
            pool.rent = rent;
        }
    }

    /// @notice Deposit ETH into this contract. This can be used to cover rent payments
    /// as the manager or funding payments as an options holder.
    /// @dev Deposits are split by pool to simplify calculating whether a user can be liquidated.
    /// @param key The pool for which the deposit will be used
    function deposit(PoolKey calldata key, uint256 amount) external {
        PoolState storage pool = pools[key.toId()];
        balances[key.toId()][msg.sender] += amount;

        uint256 amount0 = pool.payInTokenZero ? amount : 0;
        uint256 amount1 = pool.payInTokenZero ? 0 : amount;
        poolManager.unlock(
            abi.encode(CallbackData(key, msg.sender, 0, amount0.toInt256().toInt128(), amount1.toInt256().toInt128()))
        );
    }

    /// @notice Withdraw ETH from this contract.
    /// @param key The pool specified in the deposit
    /// @param amount The amount of ETH to withdraw
    function withdraw(PoolKey calldata key, uint256 amount) external {
        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

        // Get user's up-to-date balance
        uint256 balance = _pokeUserBalance(key, msg.sender);

        // Check user has enough balance to withdraw
        if (balances[poolId][msg.sender] - amount < balance) {
            revert NotEnoughDeposit();
        }

        balances[poolId][msg.sender] -= amount;

        uint256 amount0 = pool.payInTokenZero ? amount : 0;
        uint256 amount1 = pool.payInTokenZero ? 0 : amount;
        poolManager.unlock(
            abi.encode(CallbackData(key, msg.sender, 0, -amount0.toInt256().toInt128(), -amount1.toInt256().toInt128()))
        );
    }

    /// @notice Update user's balance by charging them rent if they are the manager and funding
    /// if they have an open options position.
    function _pokeUserBalance(PoolKey calldata key, address user) internal returns (uint256 balance) {
        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

        (uint256 rentOwed, uint256 fundingOwed) = _calcRentOwedAndFundingOwed(key, user);

        // Give funding to manager
        if (fundingOwed > 0) {
            balances[poolId][pool.manager] += fundingOwed;
        }

        // Update user balance
        uint256 totalOwed = rentOwed + fundingOwed;
        if (totalOwed > balance) totalOwed = balance;
        balance -= totalOwed;
        balances[poolId][user] = balance;

        // Update blocks on which user was last charged rent and funding
        lastPaymentBlock[poolId][user] = block.number;

        // If user is the manager, pay rent to LPs
        if (rentOwed > 0) {
            uint256 rentOwed0 = pool.payInTokenZero ? rentOwed : 0;
            uint256 rentOwed1 = pool.payInTokenZero ? 0 : rentOwed;
            poolManager.donate(key, rentOwed0, rentOwed1, "");
        }

        // If user is the manager and they has no collateral left, kick them out
        if (user == pool.manager && balances[poolId][user] == 0) {
            pool.manager = address(0);
        }
    }

    /// @notice Poke manager's balance.
    function _pokeManagerBalance(PoolKey calldata key) internal {
        address manager = pools[key.toId()].manager;
        _pokeUserBalance(key, manager);
    }

    /// @notice Get user's balance in this contract for a given pool
    /// @param key The pool to get the balance for
    /// @param user The user to get the balance of
    function getBalance(PoolKey calldata key, address user) external view returns (uint256 balance) {
        balance = balances[key.toId()][user];
        (uint256 rentOwed, uint256 fundingOwed) = _calcRentOwedAndFundingOwed(key, user);

        // Subtract amount owed from balance
        uint256 totalOwed = rentOwed + fundingOwed;
        if (totalOwed > balance) totalOwed = balance;
        balance -= totalOwed;
    }

    /// @notice Calculate user's balance in a pool accounting for rent and funding payments
    function _calcRentOwedAndFundingOwed(PoolKey calldata key, address user)
        public
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
            uint256 fundingSinceLastCharge = calcCumulativeFunding(key) - cumulativeFundingAtLastCharge[poolId][user];
            fundingOwed = fundingSinceLastCharge * position * blocksSinceLastPayment;
        }
    }

    /// @notice Called by users to deposit or withdraw liquidity from the pool. This method should be
    /// used instead of the default modifyLiquidity in the PoolManager.
    /// @dev This is needed so this contract owns all the liquidity and can withdraw it whenever an option is minted.
    /// @param key The pool to modify liquidity in
    /// @param liquidityDelta The change in liquidity - positive means deposit and negative means withdraw
    function modifyLiquidity(PoolKey memory key, int256 liquidityDelta) public payable returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(key, msg.sender, liquidityDelta, 0, 0))), (BalanceDelta)
        );

        // Calculate new position. Ensure it's positive, i.e. the user is not withdrawing more than they deposited
        int256 liquidity_ = int256(liquidity[key.toId()][msg.sender]) + liquidityDelta;
        if (liquidity_ < 0) revert CannotWithdrawMoreThanDeposited();
        liquidity[key.toId()][msg.sender] = uint256(liquidity_);

        // Sweep any native eth balance to the user
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    /// @notice Callback function for PoolManager to modify liquidity
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        int256 delta0 = data.delta0;
        int256 delta1 = data.delta1;
        if (data.liquidityDelta != 0) {
            PoolState storage pool = pools[data.key.toId()];

            // Create params for `PoolManager.modifyLiquidity`
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: pool.tickLower,
                tickUpper: pool.tickUpper,
                liquidityDelta: data.liquidityDelta,
                salt: ""
            });

            // Calculate deltas of each token
            (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, params, "");
            delta0 += delta.amount0();
            delta1 += delta.amount1();
        }

        // Settle and take tokens
        if (delta0 < 0) data.key.currency0.settle(poolManager, data.sender, uint256(-delta0), false);
        if (delta1 < 0) data.key.currency1.settle(poolManager, data.sender, uint256(-delta1), false);
        if (delta0 > 0) data.key.currency0.take(poolManager, data.sender, uint256(delta0), false);
        if (delta1 > 0) data.key.currency1.take(poolManager, data.sender, uint256(delta1), false);
        return abi.encode(toBalanceDelta(int128(delta0), int128(delta1)));
    }

    /// @notice Called by the manager of a pool to set the options funding rate
    /// @param key The pool to set the funding rate in
    /// @param fundingRate The new funding rate
    /// TODO: Add sanity checks on funding
    function setFundingRate(PoolKey calldata key, uint256 fundingRate) external {
        PoolState storage pool = pools[key.toId()];

        // Only manager can set funding
        if (msg.sender != pool.manager) revert OnlyManager();

        // Update cumulative funding
        pool.cumulativeFunding = calcCumulativeFunding(key);
        pool.lastCumulativeFundingUpdateBlock = block.number;

        // TODO: Override if utilization ratio too high
        pool.fundingRate = fundingRate;
    }

    /// @notice Calculate the cumulative funding of a pool. This is the sum of the funding rate
    /// across all blocks in the past. For example, if the current funding rate is 0.0001, after 100 blocks the
    /// cumulative funding would increase by 0.01.
    /// @param key The pool to calculate cumulative funding for
    function calcCumulativeFunding(PoolKey calldata key) public view returns (uint256) {
        PoolState storage pool = pools[key.toId()];
        uint256 blocksSinceLastUpdate = block.number - pool.lastCumulativeFundingUpdateBlock;
        return pool.cumulativeFunding + blocksSinceLastUpdate * pool.fundingRate;
    }

    /// @notice Called by a user to modify their options position in a pool
    /// @param key The pool to modify the position in
    /// @param positionDelta0 The change in position - positive means buy and negative means sell
    /// @param positionDelta1 The change in position - positive means buy and negative means sell
    /// @return delta The change in the user's balance in the two tokens
    function modifyOptionsPosition(PoolKey calldata key, int256 positionDelta0, int256 positionDelta1)
        external
        returns (BalanceDelta delta)
    {
        delta = _modifyOptionsPositionForUser(key, positionDelta0, positionDelta1, msg.sender);
    }

    /// @dev Internal method called by `modifyOptionsPosition` and `liquidate` to modify a user's options position
    function _modifyOptionsPositionForUser(
        PoolKey calldata key,
        int256 positionDelta0,
        int256 positionDelta1,
        address user
    ) internal returns (BalanceDelta delta) {
        _pokeManagerBalance(key);
        _pokeUserBalance(key, user);

        int256 positionDelta = positionDelta0 + positionDelta1;
        int256 absPositionDelta0 = positionDelta0 > 0 ? positionDelta0 : -positionDelta0;
        int256 absPositionDelta1 = positionDelta1 > 0 ? positionDelta1 : -positionDelta1;
        uint256 notional0 = absPositionDelta0.toUint256() * pools[key.toId()].notionalPerLiquidity / 1e18;
        uint256 notional1 = absPositionDelta1.toUint256() * pools[key.toId()].notionalPerLiquidity / 1e18;

        // Modify liquidity owned by the hook, equivalent to minting or burning options
        delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(key, user, -positionDelta.toInt128(), -notional0.toInt256(), -notional1.toInt256())
                )
            ),
            (BalanceDelta)
        );

        // Update positions
        positions0[key.toId()][user] = (positions0[key.toId()][user].toInt256() + positionDelta0).toUint256();
        positions1[key.toId()][user] = (positions1[key.toId()][user].toInt256() + positionDelta1).toUint256();

        // Sweep any native eth balance to the user
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(user, ethBalance);
        }
    }

    /// @notice Liquidate a user if their balance can't cover payments for a certain period.
    /// Reverts if the user's balance is healthy enough. Can be called by anyone and rewards them
    /// if the liquidation is successful.
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
            // Rent payment if the user is the manager of the pool
            paymentPerBlock += pool.rent;
        }

        // Funding payment if user has options position open
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

        // Force close their positions
        _modifyOptionsPositionForUser(
            key, -positions0[poolId][user].toInt256(), -positions1[poolId][user].toInt256(), user
        );

        // The liquidated user's balance is set to zero and their balance is given to the caller
        // as a reward
        balances[poolId][user] = 0;
        balances[poolId][msg.sender] += balance;
    }
}
