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

/// @title DeployTestnet
/// @notice Testnet deployment script for PhantomTWAMM hook
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory rpcUrl = vm.envString("RPC_URL");

        console.log("Deploying to testnet...");
        console.log("Deployer address:", deployer);
        console.log("RPC URL:", rpcUrl);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy PoolManager if not provided
        IPoolManager poolManager;
        address existingPoolManager = vm.envOr("POOL_MANAGER_ADDRESS", address(0));
        
        if (existingPoolManager != address(0)) {
            poolManager = IPoolManager(existingPoolManager);
            console.log("Using existing PoolManager:", address(poolManager));
        } else {
            console.log("Deploying new PoolManager...");
            poolManager = new PoolManager(address(0));
            console.log("PoolManager deployed at:", address(poolManager));
        }

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
    }
}
