// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Uniswap v4 imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

// Local imports
import {PhantomTWAMM} from "../src/PhantomTWAMM.sol";

/// @title SimpleDeploy
/// @notice Simple deployment script for PhantomTWAMM hook
contract SimpleDeploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy pool manager
        IPoolManager poolManager = new PoolManager(address(0));
        console.log("PoolManager deployed at:", address(poolManager));

        // Deploy PhantomTWAMM hook
        PhantomTWAMM phantomTWAMM = new PhantomTWAMM(poolManager);
        console.log("PhantomTWAMM deployed at:", address(phantomTWAMM));

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT SUCCESSFUL ===");
        console.log("PoolManager:", address(poolManager));
        console.log("PhantomTWAMM:", address(phantomTWAMM));
        console.log("Deployment completed successfully!");
    }
}
