// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {AmpoHook} from "../src/AmpoHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract AmpoHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Addresses for pranking
    address constant MANAGER = address(0x1000);

    int24 constant TICK_SPACING = 60;

    // @notice Default initialization parameters with tick range of -60 to 60 and 1% fee
    bytes constant INIT_PARAMS =
        abi.encode(AmpoHook.InitializeParams({tickLower: -60, tickUpper: 60, lpFee: 10_000, payInTokenZero: true}));

    AmpoHook public hook;

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
        deployCodeTo("AmpoHook.sol", abi.encode(manager), hookAddress);
        hook = AmpoHook(hookAddress);

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
        vm.expectRevert(AmpoHook.NotDynamicFee.selector);
        manager.initialize(badKey, SQRT_PRICE_1_1, INIT_PARAMS);
    }

    function test_beforeInitialize_checkRanges() public {
        AmpoHook.InitializeParams memory params;
        PoolKey memory key2 = PoolKey(currency0, currency1, 20_000 | LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, hook);

        // Should fail because not multiple of `tickSpacing`
        params = AmpoHook.InitializeParams({tickLower: -61, tickUpper: 60, lpFee: 10_000, payInTokenZero: true});
        vm.expectRevert(AmpoHook.InvalidTickRange.selector);
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));

        // Should fail because not multiple of `tickSpacing`
        params = AmpoHook.InitializeParams({tickLower: -60, tickUpper: -33, lpFee: 10_000, payInTokenZero: true});
        vm.expectRevert(AmpoHook.InvalidTickRange.selector);
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));

        // Should fail because `tickLower` is not less than `tickUpper`
        params = AmpoHook.InitializeParams({tickLower: -180, tickUpper: -180, lpFee: 10_000, payInTokenZero: true});
        vm.expectRevert(AmpoHook.InvalidTickRange.selector);
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));

        // Should fail because `tickLower` is not less than `tickUpper`
        params = AmpoHook.InitializeParams({tickLower: -180, tickUpper: -240, lpFee: 10_000, payInTokenZero: true});
        vm.expectRevert(AmpoHook.InvalidTickRange.selector);
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));
    }

    function test_beforeInitialize_setsPoolState() public {
        int24 tickLower;
        int24 tickUpper;
        uint24 lpFee;
        bool payInTokenZero;
        (tickLower, tickUpper, lpFee, payInTokenZero,,,,,,,) = hook.pools(key.toId());
        assertEq(tickLower, -60);
        assertEq(tickUpper, 60);
        assertEq(lpFee, 10_000);
        assertTrue(payInTokenZero);

        PoolKey memory key2 = PoolKey(currency0, currency1, 20_000 | LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, hook);
        AmpoHook.InitializeParams memory params =
            AmpoHook.InitializeParams({tickLower: -120, tickUpper: 180, lpFee: 10_000, payInTokenZero: false});
        manager.initialize(key2, SQRT_PRICE_1_1, abi.encode(params));
        (tickLower, tickUpper, lpFee, payInTokenZero,,,,,,,) = hook.pools(key2.toId());
        assertEq(tickLower, -120);
        assertEq(tickUpper, 180);
        assertEq(lpFee, 10_000);
        assertFalse(payInTokenZero);
    }

    function test_beforeAddLiquidity_blockModifyLiquidityUnlessViaHook() public {
        // Should fail as we aren't allowed to add liquidity to the pool via a router
        vm.expectRevert(AmpoHook.CanOnlyModifyLiquidityViaHook.selector);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 100 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    function test_beforeSwap_feesChargedWhenNoManager() public {
        // Swap 0.001 token0 -> token1
        BalanceDelta delta = _swap(true, 0.001 ether);

        // Check loss is around 1%. Initial price was set to 1 and price impact should be small so
        // loss should be similar to the default fee of 1%.
        int128 loss = 1e18 + delta.amount1() * 1e18 / delta.amount0();
        assertGt(loss, 0.0099e18);
        assertLt(loss, 0.0101e18);
    }

    // function test_beforeSwap_feesChargedAndGoToManager() public {
    //     // Manager bids and becomes manager
    //     vm.startPrank(MANAGER);
    //     hook.deposit(key, 100 ether);
    //     hook.bid(key, 0.000_001 ether);
    //     vm.stopPrank();

    //     // Swap 0.001 token0 -> token1
    //     BalanceDelta delta = _swap(true, 0.001 ether);
    // }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta delta) {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Do not use slippage limit
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            settings,
            ZERO_BYTES
        );
    }

    //     console2.log("balance0 change", int256(key.currency0.balanceOfSelf()) - int256(balance0));
    //     console2.log("balance1 change", int256(key.currency1.balanceOfSelf()) - int256(balance1));
}
