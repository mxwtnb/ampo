// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {AuctionManagedOptionsHook} from "../src/AuctionManagedOptionsHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract AuctionManagedOptionsHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    AuctionManagedOptionsHook public hook;

    int24 TICK_SPACING = 60;
    bytes constant INIT_PARAMS =
        abi.encode(AuctionManagedOptionsHook.InitializeParams({tickLower: -60, tickUpper: 60, payInTokenZero: true}));

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy our hook
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo("AuctionManagedOptionsHook.sol", abi.encode(manager), hookAddress);
        hook = AuctionManagedOptionsHook(hookAddress);

        // Also approve hook to spend our tokens
        IERC20(Currency.unwrap(currency0)).approve(hookAddress, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(hookAddress, type(uint256).max);

        // Initialize a pool with 1% fee
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, hook);
        manager.initialize(key, SQRT_PRICE_1_1, INIT_PARAMS);

        // Add some liquidity
        hook.modifyLiquidity(key, 100 ether);
    }

    function test_beforeInitialize_dynamicFeeOnly() public {
        uint24 feeWithNoDynamicFlag = 100;
        PoolKey memory badKey = PoolKey(currency0, currency1, feeWithNoDynamicFlag, TICK_SPACING, hook);

        // Should fail because no dynamic fee flag is set
        vm.expectRevert(AuctionManagedOptionsHook.NotDynamicFee.selector);
        manager.initialize(badKey, SQRT_PRICE_1_1, INIT_PARAMS);
    }

    function test_beforeInitialize_checkRanges() public {
        AuctionManagedOptionsHook.InitializeParams memory params;
        PoolKey memory key2 = PoolKey(currency0, currency1, 20_000 | LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, hook);

        // Should fail because not multiple of `tickSpacing`
        params = AuctionManagedOptionsHook.InitializeParams({tickLower: -61, tickUpper: 60, payInTokenZero: true});
        vm.expectRevert(AuctionManagedOptionsHook.InvalidTickRange.selector);
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));

        // Should fail because not multiple of `tickSpacing`
        params = AuctionManagedOptionsHook.InitializeParams({tickLower: -60, tickUpper: -33, payInTokenZero: true});
        vm.expectRevert(AuctionManagedOptionsHook.InvalidTickRange.selector);
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));

        // Should fail because `tickLower` is not less than `tickUpper`
        params = AuctionManagedOptionsHook.InitializeParams({tickLower: -180, tickUpper: -180, payInTokenZero: true});
        vm.expectRevert(AuctionManagedOptionsHook.InvalidTickRange.selector);
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));

        // Should fail because `tickLower` is not less than `tickUpper`
        params = AuctionManagedOptionsHook.InitializeParams({tickLower: -180, tickUpper: -240, payInTokenZero: true});
        vm.expectRevert(AuctionManagedOptionsHook.InvalidTickRange.selector);
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));
    }

    function test_beforeInitialize_setsPoolState() public {
        int24 tickLower;
        int24 tickUpper;
        bool payInTokenZero;
        (tickLower, tickUpper, payInTokenZero,,,,,,) = hook.pools(key.toId());
        assertEq(tickLower, -60);
        assertEq(tickUpper, 60);
        assertTrue(payInTokenZero);

        PoolKey memory key2 = PoolKey(currency0, currency1, 20_000 | LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, hook);
        AuctionManagedOptionsHook.InitializeParams memory params =
            AuctionManagedOptionsHook.InitializeParams({tickLower: -120, tickUpper: 180, payInTokenZero: false});
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));
        (tickLower, tickUpper, payInTokenZero,,,,,,) = hook.pools(key2.toId());
        assertEq(tickLower, -120);
        assertEq(tickUpper, 180);
        assertFalse(payInTokenZero);
    }

    function test_beforeAddLiquidity_blockModifyLiquidityUnlessViaHook() public {
        // Should fail as we aren't allowed to add liquidity to the pool via a router
        vm.expectRevert(AuctionManagedOptionsHook.ModifyLiquidityViaHookOnly.selector);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 100 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    function test_beforeSwap_feesChargedWhenNoManager() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Add more liquidity to the pool
        hook.modifyLiquidity(key, 100 ether);

        // Swap 0.001 token0 -> token1
        BalanceDelta delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Check loss is around 30 bps. Initial price was set to 1 and price impact should be small so
        // loss should be similar to the default fee of 30 bps.
        int128 loss = 1e18 + delta.amount1() * 1e18 / delta.amount0();
        assertGt(loss, 0.0029e18);
        assertLt(loss, 0.0031e18);
    }

    // function test_SwapFeeShouldBeZero() public {
    //     PoolKey memory key_ = PoolKey(currency0, currency1, 100, int24(60), hook);
    //     vm.expectRevert(AuctionManagedOptionsHook.SwapFeeNotZero.selector);
    //     manager.initialize(key_, SQRT_PRICE_1_1, ZERO_BYTES);
    // }

    // function test_Swap() public {
    //     PoolSwapTest.TestSettings memory settings =
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    //     // Swap exact input 100 Token A
    //     uint256 balance0 = key.currency0.balanceOfSelf();
    //     uint256 balance1 = key.currency1.balanceOfSelf();
    //     swapRouter.swap(
    //         key,
    //         IPoolManager.SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: -0.001 ether,
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         settings,
    //         ZERO_BYTES
    //     );

    //     console2.log("balance0 change", int256(key.currency0.balanceOfSelf()) - int256(balance0));
    //     console2.log("balance1 change", int256(key.currency1.balanceOfSelf()) - int256(balance1));
    // }
}
