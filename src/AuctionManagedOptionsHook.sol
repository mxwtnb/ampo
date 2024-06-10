// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {console2} from "forge-std/console2.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol"; // TODO: Use test/utils/CurrencySettler.sol instead?
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title   AuctionManagedOptionsHook
 * @author  mxwtnb
 * @notice  A Uniswap V4 hook that lets users trade perpetual options.
 *
 *          Perpetual options are options that never expire and can be exercise at any point in the future.
 *          They can be synthetically constructed by borrowing a narrow Uniswap concentrated liquidity
 *          position, withdrawing it and swapping for one of the tokens if needed. Users with an open
 *          perpetual options position have to pay funding each block, similar to funding on perpetual futures.
 *
 *          The pricing of these options is auction-managed. A continuous auction is run
 *          where anyone can bid for the right to change the funding rate and to receive funding from
 *          open options positions. They are therefore incentivized to set it in a way that maximizes
 *          their profit and the revenue that goes to LPs via the auction.
 */
contract AuctionManagedOptionsHook is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error AddLiquidityNotAllowed();
    error CannotWithdrawMoreThanDeposited();
    error NotEnoughDeposit();
    error OnlyManager();
    error SwapFeeNotZero();

    /// @notice When a pool is initialized with this hook, the fixed range must be specified.
    /// `tickLower` and `tickUpper` are the lower and upper ticks of this range.
    /// TODO: Rename to Range
    struct PoolParams {
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Data passed to `PoolManager.unlock` when modifying liquidity
    struct CallbackData {
        PoolKey key;
        address sender;
        int256 liquidityDelta;
        int256 delta0; // Allows additional token0 to be settled or taken
    }

    /// @notice Period for which manager deposit needs to cover rent
    uint256 public constant MIN_DEPOSIT_PERIOD = 300;
    uint256 public constant MIN_HEALTHY_PERIOD = 100;

    mapping(PoolId => PoolParams) public poolParams;

    /// @notice Store notional value of option. This is the amount of token0 that user
    /// will receive if they exercise the option. For example, if the pool is the ETH/DAI pool
    /// and token0 is ETH, then the notional value of 1 option would just be 1 ETH.
    /// Here, `amount`, the amount of options, is specified in liquidity units so the notional
    /// value is calculated by seeing how much the LP position that was withdrawn would be
    /// worth if it's completely in terms of token0.
    mapping(PoolId => uint256) public notionalPerLiquidity;

    /// @notice The "Manager" of a pool is the highest bidder in the auction who has the sole right to set the option funding rate.
    /// The manager can be changed by submitting a higher bid. Set to 0x0 if no manager is set.
    mapping(PoolId => address) public optionManager;

    /// @notice "Rent" is the amount of ETH that the manager pays to LPs per block
    mapping(PoolId => uint256) public managerRent;

    /// @notice Block at which rent was last charged. Used to keep track of how much rent the manager owes.
    mapping(PoolId => uint256) public lastRentBlock;

    /// @notice Current funding rate of the pool. This is the amount option holders pay per block to the manager.
    /// It can be changed at any time by the manager.
    mapping(PoolId => uint256) public currentFundingRate;

    /// @notice Cumulative funding of the pool. This is the sum of `currentFundingRate` across all blocks.
    mapping(PoolId => uint256) public cumulativeFunding;

    /// @notice Block at which `cumulativeFunding` was last updated
    mapping(PoolId => uint256) public lastCumulativeFundingBlock;

    /// @notice Cumulative funding at the last time the user was charged. Used to keep track of
    /// how much funding the user owes to the manager.
    mapping(PoolId => mapping(address => uint256)) public cumulativeFundingAtLastCharge;

    // TODO: Rename to balanceOf?
    // TODO: Add events on transfer/mint etc
    mapping(PoolId => mapping(address => uint256)) public balances;
    mapping(PoolId => mapping(address => uint256)) public positions;

    /**
     * Constructor
     */
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /**
     * Hook Permissions
     */

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

    /// @notice Revert if swap fee is not set to zero. Swap fee should be zero
    /// as we instead charge a fee in `beforeSwap` and send it to the manager.
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata hookData)
        external
        override
        returns (bytes4)
    {
        if (key.fee != 0) revert SwapFeeNotZero();
        poolParams[key.toId()] = abi.decode(hookData, (PoolParams));

        notionalPerLiquidity[key.toId()] = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtPriceAtTick(poolParams[key.toId()].tickLower),
            TickMath.getSqrtPriceAtTick(poolParams[key.toId()].tickUpper),
            1e18
        );
        return this.beforeInitialize.selector;
    }

    // TODO: change to beforeModifyPosition?
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityNotAllowed();
        // return this.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address manager = optionManager[key.toId()];

        // If no manager is set, just pass fees to LPs like a standard Uniswap pool
        if (manager == address(0)) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(int128(0), int128(0)), 0);
        }

        // Calculate swap fees. The fees don't go to LPs, they instead go to the manager of the pool
        // TODO: Fee is currency hardcoded. Use key.fee instead.
        int128 fees = int128(params.amountSpecified) / 50;
        int128 absFees = fees > 0 ? fees : -fees;

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in
        // so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne ? key.currency0 : key.currency1;

        // Send fees to manager
        feeCurrency.take(poolManager, manager, uint256(int256(absFees)), true);
        return (this.beforeSwap.selector, toBeforeSwapDelta(-fees, int128(0)), 0);
    }

    function modifyBid(PoolKey calldata key, uint256 rent) external {
        PoolId poolId = key.toId();
        if (balances[poolId][msg.sender] < rent * MIN_DEPOSIT_PERIOD) {
            revert NotEnoughDeposit();
        }

        if (optionManager[poolId] == msg.sender) {
            // Modify or cancel bid
            managerRent[poolId] = rent;
        } else if (rent > managerRent[poolId]) {
            // Submit new highest bid
            address prevManager = optionManager[poolId];
            _pokeUserBalance(key, prevManager);
            _modifyOptionsPositionForUser(key, -positions[poolId][prevManager].toInt256(), prevManager);

            optionManager[poolId] = msg.sender;
            managerRent[poolId] = rent;
            lastRentBlock[poolId] = block.number;
        }
    }

    /// @notice Deposit ETH into this contract. This can be used to cover rent payments
    /// as the manager or funding payments as an options holder.
    /// @dev Deposits are split by pool to simplify calculating whether a user can be liquidated.
    /// @param key The pool for which the deposit will be used
    function deposit(PoolKey calldata key) external payable {
        balances[key.toId()][msg.sender] += msg.value;
    }

    /// @notice Withdraw ETH from this contract.
    /// @param key The pool specified in the deposit
    /// @param amount The amount of ETH to withdraw
    function withdraw(PoolKey calldata key, uint256 amount) external {
        PoolId poolId = key.toId();
        if (
            msg.sender == optionManager[poolId]
                && balances[poolId][msg.sender] - amount < managerRent[poolId] * MIN_DEPOSIT_PERIOD
        ) {
            revert NotEnoughDeposit();
        }

        balances[poolId][msg.sender] -= amount;
    }

    /// @notice Charge rent to the current manager of the given pool
    // TODO: add tests for this method
    function _chargeRent(PoolKey calldata key) internal {
        PoolId poolId = key.toId();

        // Skip if no manager
        address manager = optionManager[poolId];
        if (manager == address(0)) {
            return;
        }

        uint256 timeSinceLastCharge = block.number - lastRentBlock[poolId];
        uint256 rentOwed = managerRent[poolId] * timeSinceLastCharge;

        // Manager is out of collateral so kick them out
        if (balances[poolId][manager] < rentOwed) {
            rentOwed = balances[poolId][manager];
            optionManager[poolId] = address(0);
        }

        lastRentBlock[poolId] = block.number;
        balances[poolId][manager] -= rentOwed;
    }

    function _pokeUserBalance(PoolKey calldata key, address user) internal returns (uint256 balance) {
        PoolId poolId = key.toId();
        balance = calcBalance(key, user);
        balances[poolId][user] = balance;
    }

    function _pokeManagerBalance(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        address manager = optionManager[poolId];
        _pokeUserBalance(key, manager);
        if (manager != address(0) && balances[poolId][manager] == 0) {
            optionManager[poolId] = address(0);
        }
    }

    // TODO: add updateBalance() which calls this
    // TODO: subtract funding payments from balance
    function calcBalance(PoolKey calldata key, address user) public view returns (uint256 balance) {
        PoolId poolId = key.toId();
        balance = balances[poolId][user];

        if (user == optionManager[poolId]) {
            uint256 timeSinceLastCharge = block.number - lastRentBlock[poolId];
            uint256 rentOwed = managerRent[poolId] * timeSinceLastCharge;
            if (rentOwed > balance) rentOwed = balance;
            balance -= rentOwed;
        }

        if (positions[poolId][user] > 0) {
            uint256 funding = calcCumulativeFunding(key) - cumulativeFundingAtLastCharge[poolId][user];
            balance -= funding * positions[poolId][user];
        }
    }

    /// @notice Modify liquidity in a pool. This method should be used instead of the default modifyLiquidity
    /// in the PoolManager.
    /// @dev This is needed so this contract owns all the liquidity and can withdraw it whenever an option is minted.
    /// @param key The pool to modify liquidity in
    /// @param liquidityDelta The change in liquidity - positive means deposit and negative means withdraw
    function modifyLiquidity(PoolKey memory key, int256 liquidityDelta) public payable returns (BalanceDelta delta) {
        delta =
            abi.decode(poolManager.unlock(abi.encode(CallbackData(key, msg.sender, liquidityDelta, 0))), (BalanceDelta));

        int256 position = int256(positions[key.toId()][msg.sender]) + liquidityDelta;
        if (position < 0) revert CannotWithdrawMoreThanDeposited();
        positions[key.toId()][msg.sender] = uint256(position);

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    /// @notice Callback function for PoolManager to modify liquidity
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolId poolId = data.key.toId();

        PoolParams memory pp = poolParams[poolId];
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: pp.tickLower,
            tickUpper: pp.tickUpper,
            liquidityDelta: data.liquidityDelta,
            salt: ""
        });

        (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, params, "");
        int256 delta0 = delta.amount0() + data.delta0;
        int256 delta1 = delta.amount1();

        if (delta0 < 0) data.key.currency0.settle(poolManager, data.sender, uint256(-delta0), false);
        if (delta1 < 0) data.key.currency1.settle(poolManager, data.sender, uint256(-delta1), false);
        if (delta0 > 0) data.key.currency0.take(poolManager, data.sender, uint256(delta0), false);
        if (delta1 > 0) data.key.currency1.take(poolManager, data.sender, uint256(delta1), false);
        return abi.encode(toBalanceDelta(int128(delta0), int128(delta1)));
    }

    /// @notice Called by the manager of a pool to set the options funding rate
    /// @param key The pool to set the funding rate in
    /// @param fundingRate The new funding rate
    function setFunding(PoolKey calldata key, uint256 fundingRate) external {
        if (msg.sender != optionManager[key.toId()]) revert OnlyManager();
        _updateFunding(key, fundingRate);
    }

    function _updateFunding(PoolKey calldata key, uint256 fundingRate) internal {
        PoolId poolId = key.toId();
        cumulativeFunding[poolId] = calcCumulativeFunding(key);
        lastCumulativeFundingBlock[poolId] = block.number;

        // TODO: Override if utilization ratio too high
        currentFundingRate[poolId] = fundingRate;
    }

    function calcCumulativeFunding(PoolKey calldata key) public view returns (uint256) {
        PoolId poolId = key.toId();
        return
            cumulativeFunding[poolId] + (block.number - lastCumulativeFundingBlock[poolId]) * currentFundingRate[poolId];
    }

    function _chargeFunding(PoolKey calldata key, address user) internal {
        PoolId poolId = key.toId();
        uint256 funding = calcCumulativeFunding(key) - cumulativeFundingAtLastCharge[poolId][user];
        uint256 fee = funding * positions[poolId][user];
        balances[poolId][user] -= fee;
        cumulativeFundingAtLastCharge[poolId][user] = calcCumulativeFunding(key);
    }

    function modifyOptionsPosition(PoolKey calldata key, int256 positionDelta) external returns (BalanceDelta delta) {
        delta = _modifyOptionsPositionForUser(key, positionDelta, msg.sender);
    }

    function _modifyOptionsPositionForUser(PoolKey calldata key, int256 positionDelta, address user)
        internal
        returns (BalanceDelta delta)
    {
        _chargeFunding(key, user);
        int256 absPositionDelta = positionDelta > 0 ? positionDelta : -positionDelta;
        uint256 notional = absPositionDelta.toUint256() * notionalPerLiquidity[key.toId()] / 1e18;
        delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(key, user, -positionDelta.toInt128(), -notional.toInt256()))),
            (BalanceDelta)
        );
    }

    function liquidate(PoolKey calldata key, address user) external {
        uint256 balance = _pokeUserBalance(key, user);

        uint256 paymentPerBlock = 0;
        bool isManager = user == optionManager[key.toId()];
        if (isManager) {
            paymentPerBlock += managerRent[key.toId()];
        }
        if (positions[key.toId()][user] > 0) {
            paymentPerBlock += currentFundingRate[key.toId()];
        }

        if (balance < paymentPerBlock * MIN_HEALTHY_PERIOD) {
            if (isManager) {
                optionManager[key.toId()] = address(0);
            }
            _modifyOptionsPositionForUser(key, -positions[key.toId()][user].toInt256(), user);
        }
    }
}
