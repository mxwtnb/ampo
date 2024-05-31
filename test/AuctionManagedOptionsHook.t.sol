// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {AuctionManagedOptionsHook} from "../src/AuctionManagedOptionsHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract AuctionManagedOptionsHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    AuctionManagedOptionsHook public hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy our hook
        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        );
        deployCodeTo("AuctionManagedOptionsHook.sol", abi.encode(manager), hookAddress);
        hook = AuctionManagedOptionsHook(hookAddress);

        // Initialize a pool with zero fee
        key = PoolKey(currency0, currency1, 0, int24(60), hook);
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 100 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    function test_SwapFeeShouldBeZero() public {
        PoolKey memory key_ = PoolKey(currency0, currency1, 100, int24(60), hook);
        vm.expectRevert(AuctionManagedOptionsHook.SwapFeeNotZero.selector);
        manager.initialize(key_, SQRT_PRICE_1_1, ZERO_BYTES);
    }

    function test_Swap() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap exact input 100 Token A
        uint256 balance0 = key.currency0.balanceOfSelf();
        uint256 balance1 = key.currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        console2.log("balance0 change", int256(key.currency0.balanceOfSelf()) - int256(balance0));
        console2.log("balance1 change", int256(key.currency1.balanceOfSelf()) - int256(balance1));
    }
}
