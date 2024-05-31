// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {console2} from "forge-std/console2.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract AuctionManagedOptionsHook is BaseHook {
    using CurrencySettleTake for Currency;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    error SwapFeeNotZero();

    // TODO: Add beforeAddLiquidity and check range matches the hook's range
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
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
        override
        returns (bytes4)
    {
        if (key.fee != 0) revert SwapFeeNotZero();
        return this.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Calculate swap fees. The fees don't go to LPs, they instead go to the manager of the pool
        // TODO: Fee is currency hardcoded. Use manager-set fee instead.
        int128 feeDelta = int128(params.amountSpecified) / 50;
        uint256 feeAmount = uint256(int256(feeDelta > 0 ? feeDelta : -feeDelta));

        BeforeSwapDelta bsd = toBeforeSwapDelta(-feeDelta, int128(0));

        // TODO: Redirect fee to manager
        Currency feeCurrency = params.zeroForOne != (params.amountSpecified > 0) ? key.currency0 : key.currency1;
        feeCurrency.take(poolManager, address(this), feeAmount, true);
        return (this.beforeSwap.selector, bsd, 0);
    }
}
