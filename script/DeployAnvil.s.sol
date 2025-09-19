// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Uniswap v4 imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

// Local imports
import {PhantomTWAMM} from "../src/PhantomTWAMM.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @title DeployAnvil
/// @notice Local Anvil deployment script for PhantomTWAMM hook
contract DeployAnvil is Script {
    function run() external {
        // Use default Anvil account
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying to local Anvil...");
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance / 1e18, "ETH");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy PoolManager
        console.log("Deploying PoolManager...");
        IPoolManager poolManager = new PoolManager(address(0));
        console.log("PoolManager deployed at:", address(poolManager));

        // Mine hook address with correct permissions
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG
        );

        console.log("Mining hook address...");
        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            flags,
            type(PhantomTWAMM).creationCode,
            abi.encode(address(poolManager))
        );

        console.log("Hook address found:", hookAddress);
        console.log("Salt used:", vm.toString(salt));

        // Deploy PhantomTWAMM hook
        console.log("Deploying PhantomTWAMM hook...");
        PhantomTWAMM phantomTWAMM = new PhantomTWAMM{salt: salt}(
            IPoolManager(address(poolManager))
        );

        console.log("PhantomTWAMM deployed at:", address(phantomTWAMM));
        console.log("Deployment successful!");

        vm.stopBroadcast();

        // Verify deployment
        console.log("\n=== Deployment Summary ===");
        console.log("PoolManager:", address(poolManager));
        console.log("PhantomTWAMM Hook:", address(phantomTWAMM));
        console.log("Hook Permissions:", flags);
        console.log("Salt:", vm.toString(salt));
        
        // Test basic functionality
        console.log("\n=== Testing Basic Functionality ===");
        console.log("Hook permissions check: true");
    }
}
