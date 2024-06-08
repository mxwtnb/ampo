// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {console2} from "forge-std/console2.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/*



*/

contract AuctionManagedOptionsHook is BaseHook {
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;

    struct Bid {
        address manager;
        uint256 rent;
        uint256 timestamp;
    }

    uint256 public constant MIN_DEPOSIT_PERIOD = 300;
    mapping(PoolId => Bid) public bids;
    mapping(PoolId => mapping(address => uint256)) public deposits;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    error SwapFeeNotZero();
    error NotEnoughDeposit();

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

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in
        // so the currencySpecified should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        Currency currencySpecified = (params.amountSpecified > 0) != params.zeroForOne ? key.currency0 : key.currency1;

        // TODO: Redirect fee to manager
        currencySpecified.take(poolManager, address(this), feeAmount, true);
        return (this.beforeSwap.selector, bsd, 0);
    }

    function modifyBid(PoolKey calldata key, uint256 rent) external {
        if (deposits[key.toId()][msg.sender] < rent * MIN_DEPOSIT_PERIOD) {
            revert NotEnoughDeposit();
        }

        if (bids[key.toId()].manager == msg.sender) {
            // Modify or cancel bid
            bids[key.toId()].rent = rent;
        } else if (rent > bids[key.toId()].rent) {
            // Submit new highest bid
            bids[key.toId()] = Bid(msg.sender, rent, block.timestamp);
        }
    }

    function deposit(PoolKey calldata key) external payable {
        deposits[key.toId()][msg.sender] += msg.value;
    }

    function withdraw(PoolKey calldata key, uint256 amount) external {
        if (msg.sender == bids[key.toId()].manager && deposits[key.toId()][msg.sender] - amount < bids[key.toId()].rent * MIN_DEPOSIT_PERIOD)
        {
            revert NotEnoughDeposit();
        }

        deposits[key.toId()][msg.sender] -= amount;
    }
}
