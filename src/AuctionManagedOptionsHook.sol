// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {console2} from "forge-std/console2.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol"; // TODO: Use test/utils/CurrencySettler.sol instead?
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title   AuctionManagedOptionsHook
 * @author  mxwtnb
 * @notice  A Uniswap V4 hook that auctions off the rights to create perpetual option
 *          positions by borrowing and withdrawing concentrated liquidity.
 */
contract AuctionManagedOptionsHook is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 public constant MIN_DEPOSIT_PERIOD = 300;

    // TODO: Set range when creating pool
    mapping(PoolId => int24) public tickLowers;
    mapping(PoolId => int24) public tickUppers;

    mapping(PoolId => address) public managers;
    mapping(PoolId => uint256) public rents;
    mapping(PoolId => uint256) public lastRentChargeTimestamps;

    mapping(PoolId => mapping(address => uint256)) public balances;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    error CannotDepositDirectly();
    error NotEnoughDeposit();
    error SwapFeeNotZero();

    // TODO: Add beforeAddLiquidity and check range matches the hook's range
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
    // TODO: Take lower and upper prices for the fixed range
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        if (key.fee != 0) revert SwapFeeNotZero();
        return this.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert CannotDepositDirectly();
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address manager = managers[key.toId()];

        // If no manager is set, just pass fees to LPs like a vanilla uniswap pool
        if (manager == address(0)) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(int128(0), int128(0)), 0);
        }

        // Calculate swap fees. The fees don't go to LPs, they instead go to the manager of the pool
        // TODO: Fee is currency hardcoded. Use manager-set fee instead.
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

        if (managers[poolId] == msg.sender) {
            // Modify or cancel bid
            rents[poolId] = rent;
        } else if (rent > rents[poolId]) {
            // Submit new highest bid
            // TODO: Make sure old manager is charged rent up to now
            managers[poolId] = msg.sender;
            rents[poolId] = rent;
            lastRentChargeTimestamps[poolId] = block.timestamp;
        }
    }

    function deposit(PoolKey calldata key) external payable {
        balances[key.toId()][msg.sender] += msg.value;
    }

    function withdraw(PoolKey calldata key, uint256 amount) external {
        PoolId poolId = key.toId();
        if (
            msg.sender == managers[poolId] && balances[poolId][msg.sender] - amount < rents[poolId] * MIN_DEPOSIT_PERIOD
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
        address manager = managers[poolId];
        if (manager == address(0)) {
            return;
        }

        uint256 timeSinceLastCharge = block.timestamp - lastRentChargeTimestamps[poolId];
        uint256 rentOwed = rents[poolId] * timeSinceLastCharge;

        // Manager is out of collateral so kick them out
        if (balances[poolId][manager] < rentOwed) {
            rentOwed = balances[poolId][manager];
            managers[poolId] = address(0);
        }

        lastRentChargeTimestamps[poolId] = block.timestamp;
        balances[poolId][manager] -= rentOwed;
    }

    // TODO: add updateBalance() which calls this
    function calcBalance(PoolKey calldata key, address user) public view returns (uint256 balance) {
        PoolId poolId = key.toId();
        balance = balances[poolId][user];

        if (user == managers[poolId]) {
            uint256 timeSinceLastCharge = block.timestamp - lastRentChargeTimestamps[poolId];
            uint256 rentOwed = rents[poolId] * timeSinceLastCharge;
            if (rentOwed > balance) rentOwed = balance;
            balance -= rentOwed;
        }
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        int256 liquidityDelta;
    }

    function modifyLiquidity(PoolKey memory key, int256 liquidityDelta) public payable returns (BalanceDelta delta) {
        delta =
            abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, key, liquidityDelta))), (BalanceDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolId poolId = data.key.toId();

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLowers[poolId],
            tickUpper: tickUppers[poolId],
            liquidityDelta: data.liquidityDelta,
            salt: ""
        });

        (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, params, "");
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        if (delta0 < 0) data.key.currency0.settle(poolManager, data.sender, uint256(-delta0), true);
        if (delta1 < 0) data.key.currency1.settle(poolManager, data.sender, uint256(-delta1), true);
        if (delta0 > 0) data.key.currency0.take(poolManager, data.sender, uint256(delta0), true);
        if (delta1 > 0) data.key.currency1.take(poolManager, data.sender, uint256(delta1), true);
        return abi.encode(delta);
    }
}
