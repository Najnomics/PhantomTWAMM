// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// Uniswap v4 imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IProtocolFees} from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

// Local imports
import {PhantomTWAMM} from "../src/PhantomTWAMM.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @title DeployPhantomTWAMM
/// @notice Deployment script for PhantomTWAMM hook
contract DeployPhantomTWAMM is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Deployment addresses (will be updated during deployment)
    IPoolManager poolManager;
    PhantomTWAMM phantomTWAMM;

    // Constants
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy pool manager if needed
        poolManager = _deployOrGetPoolManager();
        console.log("PoolManager deployed at:", address(poolManager));

        // Deploy PhantomTWAMM hook with mined address
        phantomTWAMM = _deployPhantomTWAMM();
        console.log("PhantomTWAMM deployed at:", address(phantomTWAMM));

        // Verify hook permissions
        _verifyHookPermissions();

        // Deploy demo tokens and create pool (optional)
        if (vm.envOr("DEPLOY_DEMO_POOL", false)) {
            _deployDemoPool();
        }

        vm.stopBroadcast();

        // Log deployment summary
        _logDeploymentSummary();
    }

    /// @notice Deploy or get existing pool manager
    function _deployOrGetPoolManager() internal returns (IPoolManager) {
        address existingManager = vm.envOr("POOL_MANAGER_ADDRESS", address(0));

        if (existingManager != address(0)) {
            console.log("Using existing PoolManager at:", existingManager);
            return IPoolManager(existingManager);
        } else {
            console.log("Deploying new PoolManager...");
            return new PoolManager(address(0));
        }
    }

    /// @notice Deploy PhantomTWAMM hook with correct permissions
    function _deployPhantomTWAMM() internal returns (PhantomTWAMM) {
        // Define required hook permissions
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        console.log("Mining hook address with flags:", flags);

        // Mine hook address with correct permissions
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(deployer, flags, type(PhantomTWAMM).creationCode, abi.encode(address(poolManager)));

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", Strings.toHexString(uint256(salt)));

        // Deploy hook at mined address
        PhantomTWAMM hook = new PhantomTWAMM{salt: salt}(poolManager);

        require(address(hook) == hookAddress, "Hook address mismatch");

        return hook;
    }

    /// @notice Verify that hook has correct permissions
    function _verifyHookPermissions() internal view {
        Hooks.Permissions memory permissions = phantomTWAMM.getHookPermissions();

        require(permissions.afterInitialize, "Missing afterInitialize permission");
        require(permissions.beforeSwap, "Missing beforeSwap permission");
        require(!permissions.afterSwap, "Should not have afterSwap permission");

        console.log("Hook permissions verified");
    }

    /// @notice Deploy demo pool for testing
    function _deployDemoPool() internal {
        console.log("Deploying demo pool...");

        // Deploy mock tokens
        MockERC20 token0 = new MockERC20("Demo Token A", "DTKA");
        MockERC20 token1 = new MockERC20("Demo Token B", "DTKB");

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        console.log("Token0:", address(token0));
        console.log("Token1:", address(token1));

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(phantomTWAMM))
        });

        // Initialize pool
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        console.log("Demo pool initialized");
        PoolId poolId = poolKey.toId();
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
    }

    /// @notice Log deployment summary
    function _logDeploymentSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("PoolManager:", address(poolManager));
        console.log("PhantomTWAMM:", address(phantomTWAMM));

        // Get hook permissions for logging
        Hooks.Permissions memory permissions = phantomTWAMM.getHookPermissions();
        console.log("\nHook Permissions:");
        console.log("- afterInitialize:", permissions.afterInitialize);
        console.log("- beforeSwap:", permissions.beforeSwap);
        console.log("- afterSwap:", permissions.afterSwap);
        console.log("- beforeAddLiquidity:", permissions.beforeAddLiquidity);

        console.log("Deployment completed successfully!");
        console.log("\nTo interact with the hook:");
        console.log("1. Create pool with PhantomTWAMM as hook");
        console.log("2. Call commitPhantomTWAMM to create encrypted orders");
        console.log("3. Public swaps will trigger phantom order processing");
        console.log("4. Use revealForAuditability for compliance");
    }
}

/// @notice Mock ERC20 for demo deployment
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        totalSupply = 1000000 * 10 ** 18;
        balanceOf[msg.sender] = totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
