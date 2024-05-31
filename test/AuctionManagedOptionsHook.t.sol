// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {AuctionManagedOptionsHook} from "../src/AuctionManagedOptionsHook.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract AuctionManagedOptionsHookTest is Test, Deployers {
    AuctionManagedOptionsHook public hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        deployCodeTo("AuctionManagedOptionsHook.sol", abi.encode(manager), hookAddress);
    }

    function test_Increment() public {}
}
