// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {AmpoHook} from "../src/AmpoHook.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract AmpoHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Addresses for pranking
    address constant MANAGER = address(0x1000);
    address constant MANAGER2 = address(0x1001);
    address constant USER = address(0x1002);

    int24 constant TICK_SPACING = 60;

    // @notice Default initialization parameters with tick range of -60 to 60 and 1% fee
    bytes constant INIT_PARAMS =
        abi.encode(AmpoHook.InitializeParams({tickLower: -60, tickUpper: 60, lpFee: 10_000, payInTokenZero: true}));

    IPoolManager poolManager;
    AmpoHook public hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // We use the variable name `poolManager` so that it's not confusing with our notion of managers.
        poolManager = manager;

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

        // Set up users
        _setUpUser(MANAGER);
        _setUpUser(MANAGER2);
        _setUpUser(USER);
    }

    function _setUpUser(address user) internal {
        // Mint tokens for user
        MockERC20(Currency.unwrap(currency0)).mint(user, 100 ether);
        MockERC20(Currency.unwrap(currency1)).mint(user, 100 ether);

        // Approve hook to spend user's tokens
        vm.startPrank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
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
        BalanceDelta delta = _swap(key, true, 0.001 ether);

        // Check loss is around 1%. Initial price was set to 1 and price impact should be small so
        // loss should be similar to the default fee of 1%.
        int128 loss = 1e18 + delta.amount1() * 1e18 / delta.amount0();
        assertGt(loss, 0.0099e18);
        assertLt(loss, 0.0101e18);
    }

    function test_beforeSwap_feesChargedAndGoToManager() public {
        // Manager bids and becomes manager
        vm.startPrank(MANAGER);
        hook.deposit(key, 10 ether);
        hook.bid(key, 0.000_001 ether);
        vm.stopPrank();

        // Check claim token balance is zero
        assertEq(poolManager.balanceOf(MANAGER, key.currency0.toId()), 0);
        assertEq(poolManager.balanceOf(MANAGER, key.currency1.toId()), 0);

        // Swap 0.001 token0 -> token1
        BalanceDelta delta = _swap(key, true, 0.001 ether);

        // Check loss is around 1%. Initial price was set to 1 and price impact should be small so
        // loss should be similar to the default fee of 1%.
        int128 loss = 1e18 + delta.amount1() * 1e18 / delta.amount0();
        assertGt(loss, 0.0099e18);
        assertLt(loss, 0.0101e18);

        // Check manager has received fees as claim tokens
        assertEq(poolManager.balanceOf(MANAGER, key.currency0.toId()), 0);
        assertEq(poolManager.balanceOf(MANAGER, key.currency1.toId()), 0.00001e18);
    }

    function test_bid() public {
        // Check there is no manager
        assertEq(_pool(key).manager, address(0));

        // Manager bids and becomes manager
        vm.startPrank(MANAGER);
        hook.deposit(key, 10 ether);
        hook.bid(key, 0.000_001 ether);
        vm.stopPrank();

        // Check manager is now set
        assertEq(_pool(key).manager, MANAGER);
        assertEq(_pool(key).rent, 0.000_001 ether);

        // Manager modifies bid
        vm.prank(MANAGER);
        hook.bid(key, 0.000_002 ether);

        // Check rent has been updated
        assertEq(_pool(key).rent, 0.000_002 ether);

        // Manager2 under-bids so nothing happens
        vm.startPrank(MANAGER2);
        hook.deposit(key, 10 ether);
        hook.bid(key, 0.000_001 ether);
        vm.stopPrank();

        // Check no change
        assertEq(_pool(key).manager, MANAGER);
        assertEq(_pool(key).rent, 0.000_002 ether);

        // Manager2 out-bids so usurps Manager
        vm.prank(MANAGER2);
        hook.bid(key, 0.000_003 ether);

        // Check manager has changed
        assertEq(_pool(key).manager, MANAGER2);
        assertEq(_pool(key).rent, 0.000_003 ether);
    }

    function test_bid_rentChargedOverTime() public {
        // Manager bids and becomes manager and sets funding
        vm.startPrank(MANAGER);
        hook.deposit(key, 10 ether);
        hook.bid(key, 0.001 ether);
        vm.stopPrank();

        uint256 balance0 = IERC20(Currency.unwrap(currency0)).balanceOf(USER);

        // User deposits
        vm.prank(USER);
        hook.modifyLiquidity(key, 50 ether);

        // Manager balance is 10 eth
        assertEq(hook.getBalance(key, MANAGER), 10 ether);

        // Skip forward 1000 blocks
        vm.roll(block.number + 1000);

        // Manager balance is less than 10 eth
        assertLt(hook.getBalance(key, MANAGER), 10 ether);

        // User withdraws
        vm.prank(USER);
        hook.modifyLiquidity(key, -50 ether);

        // Check user has received rent
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(USER), balance0);
    }

    function test_deposit_withdraw() public {
        // Check balance is 0
        assertEq(hook.balanceOf(key.toId(), USER), 0);

        uint256 balance = IERC20(Currency.unwrap(currency0)).balanceOf(USER);

        // Deposit 10
        vm.prank(USER);
        hook.deposit(key, 10 ether);

        // Check balance is 10 and user has 10 less tokens
        assertEq(hook.balanceOf(key.toId(), USER), 10 ether);
        assertEq(hook.getBalance(key, USER), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(USER), balance - 10 ether);
        assertEq(hook.totalSupply(key.toId()), 10 ether);

        // Can't withdraw 11
        vm.expectRevert(AmpoHook.CannotWithdrawMoreThanDeposited.selector);
        vm.prank(USER);
        hook.withdraw(key, 11 ether);

        // Withdraw 6
        vm.prank(USER);
        hook.withdraw(key, 6 ether);

        // Check balance is 4 and user has 6 more tokens
        assertEq(hook.balanceOf(key.toId(), USER), 4 ether);
        assertEq(hook.getBalance(key, USER), 4 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(USER), balance - 4 ether);
        assertEq(hook.totalSupply(key.toId()), 4 ether);
    }

    function test_modifyLiquidity() public {
        // Check liquidity is 0
        assertEq(hook.liquidityOf(key.toId(), USER), 0);

        uint256 balance0 = IERC20(Currency.unwrap(currency0)).balanceOf(USER);
        uint256 balance1 = IERC20(Currency.unwrap(currency1)).balanceOf(USER);

        // Add 10
        vm.prank(USER);
        hook.modifyLiquidity(key, 10 ether);

        // Check liquidity is 10
        assertEq(hook.liquidityOf(key.toId(), USER), 10 ether);

        // Check user has paid tokens
        assertLt(IERC20(Currency.unwrap(currency0)).balanceOf(USER), balance0);
        assertLt(IERC20(Currency.unwrap(currency1)).balanceOf(USER), balance1);

        balance0 = IERC20(Currency.unwrap(currency0)).balanceOf(USER);
        balance1 = IERC20(Currency.unwrap(currency1)).balanceOf(USER);

        // Can't remove 11
        vm.expectRevert(AmpoHook.CannotWithdrawMoreThanDeposited.selector);
        vm.prank(USER);
        hook.modifyLiquidity(key, -11 ether);

        // Remove 6
        vm.prank(USER);
        hook.modifyLiquidity(key, -6 ether);

        // Check liquidity is 4
        assertEq(hook.liquidityOf(key.toId(), USER), 4 ether);

        // Check user has received tokens
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(USER), balance0);
        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(USER), balance1);
    }

    function test_setFundingRate() public {
        vm.startPrank(MANAGER);
        hook.deposit(key, 10 ether);
        hook.bid(key, 0.000_001 ether);
        vm.stopPrank();

        // Check funding rate is 0
        assertEq(_pool(key).fundingRate, 0);

        // Set funding rate to 0.0001
        vm.prank(MANAGER);
        hook.setFundingRate(key, 0.0001 ether);

        // Check funding rate is 0.0001
        assertEq(_pool(key).fundingRate, 0.0001 ether);
    }

    function test_setFundingRate_revertsIfNotManager() public {
        vm.expectRevert(AmpoHook.OnlyManager.selector);
        hook.setFundingRate(key, 0.0001 ether);
    }

    function test_modifyOptionsPosition() public {
        vm.startPrank(USER);
        hook.modifyOptionsPosition(key, 0.0001 ether, 0.0002 ether);

        assertEq(hook.positions0(key.toId(), USER), 0.0001 ether);
        assertEq(hook.positions1(key.toId(), USER), 0.0002 ether);
    }

    function test_modifyOptionsPosition_fundingChargedOverTime() public {
        // Manager bids and becomes manager and sets funding
        vm.startPrank(MANAGER);
        hook.deposit(key, 10 ether);
        hook.bid(key, 0.000_001 ether);
        hook.setFundingRate(key, 0.0001 ether);
        vm.stopPrank();

        // User opens position
        vm.startPrank(USER);
        hook.deposit(key, 1 ether);
        hook.modifyOptionsPosition(key, 0.0001 ether, 0.0002 ether);
        vm.stopPrank();

        // User balance is 1 eth
        assertEq(hook.getBalance(key, USER), 1 ether);

        // Skip forward 1000 blocks
        vm.roll(block.number + 1000);

        // User balance is less than 1 eth
        assertLt(hook.getBalance(key, USER), 1 ether);
    }

    function test_liquidate() public {
        // Manager bids and becomes manager and sets funding
        vm.startPrank(MANAGER);
        hook.deposit(key, 10 ether);
        hook.bid(key, 0.000_001 ether);
        hook.setFundingRate(key, 0.0001 ether);
        vm.stopPrank();

        // User opens position without collateral
        vm.startPrank(USER);
        hook.modifyOptionsPosition(key, 0.0001 ether, 0.0002 ether);
        vm.stopPrank();

        // Skip forward 1000 blocks
        vm.roll(block.number + 1000);

        hook.liquidate(key, USER);

        // Check user is liquidated
        assertEq(hook.positions0(key.toId(), USER), 0);
        assertEq(hook.positions1(key.toId(), USER), 0);
        assertEq(hook.getBalance(key, USER), 0);
    }

    function test_liquidate_revertsIfHealthy() public {
        // User opens position
        vm.startPrank(USER);
        hook.deposit(key, 10 ether);
        hook.modifyOptionsPosition(key, 0.0001 ether, 0.0002 ether);
        vm.stopPrank();

        // Position is healthy so can't be liquidated
        vm.expectRevert(AmpoHook.NotLiquidatable.selector);
        hook.liquidate(key, USER);
    }

    /// @notice Helper method to do a swap without a slippage limit
    function _swap(PoolKey memory key_, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        delta = swapRouter.swap(
            key_,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            settings,
            ZERO_BYTES
        );
    }

    /// @notice Helper method to get the pool state as a PoolState struct
    function _pool(PoolKey memory key_) internal view returns (AmpoHook.PoolState memory) {
        (
            int24 tickLower,
            int24 tickUpper,
            uint24 lpFee,
            bool payInTokenZero,
            address manager,
            uint256 rent,
            uint256 fundingRate,
            uint256 cumulativeFunding,
            uint256 lastCumulativeFundingUpdateBlock,
            uint256 amount0PerLiquidity,
            uint256 amount1PerLiquidity
        ) = hook.pools(key_.toId());
        return AmpoHook.PoolState({
            tickLower: tickLower,
            tickUpper: tickUpper,
            lpFee: lpFee,
            payInTokenZero: payInTokenZero,
            manager: manager,
            rent: rent,
            fundingRate: fundingRate,
            cumulativeFunding: cumulativeFunding,
            lastCumulativeFundingUpdateBlock: lastCumulativeFundingUpdateBlock,
            amount0PerLiquidity: amount0PerLiquidity,
            amount1PerLiquidity: amount1PerLiquidity
        });
    }
}
