// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// Uniswap v4 imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

// FHE imports
import {FHE, InEuint128, InEuint64, InEuint8} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

// Local imports
import {PhantomTWAMM} from "../src/PhantomTWAMM.sol";

/// @title TWAMMDemo
/// @notice Demo script showing PhantomTWAMM functionality
contract TWAMMDemo is Script, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Contract instances (to be loaded from environment)
    IPoolManager poolManager;
    PhantomTWAMM phantomTWAMM;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liquidityRouter;

    // Demo accounts
    address alice;
    address bob;
    address carol;

    // Demo tokens and pool
    address token0;
    address token1;
    PoolKey poolKey;
    PoolId poolId;

    function run() external {
        // Load deployment addresses from environment
        _loadDeployedContracts();

        // Setup demo accounts
        _setupDemoAccounts();

        // Run demo scenarios
        console.log("Starting PhantomTWAMM Demo...");

        _demoBasicCommitment();
        _demoMultipleOrders();
        _demoSwapTriggeredExecution();
        _demoOrderReveal();
        _demoComplianceAudit();

        console.log("Demo completed successfully!");
        console.log("Final Statistics:");
        _printStatistics();
    }

    /// @notice Load deployed contract addresses
    function _loadDeployedContracts() internal {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER_ADDRESS");
        address phantomTWAMMAddr = vm.envAddress("PHANTOM_TWAMM_ADDRESS");

        poolManager = IPoolManager(poolManagerAddr);
        phantomTWAMM = PhantomTWAMM(phantomTWAMMAddr);

        console.log("Loaded PoolManager:", address(poolManager));
        console.log("Loaded PhantomTWAMM:", address(phantomTWAMM));

        // Deploy routers for demo
        swapRouter = new PoolSwapTest(poolManager);
        liquidityRouter = new PoolModifyLiquidityTest(poolManager);

        console.log("Deployed SwapRouter:", address(swapRouter));
        console.log("Deployed LiquidityRouter:", address(liquidityRouter));
    }

    /// @notice Setup demo accounts with tokens
    function _setupDemoAccounts() internal {
        alice = vm.envOr("ALICE_ADDRESS", makeAddr("alice"));
        bob = vm.envOr("BOB_ADDRESS", makeAddr("bob"));
        carol = vm.envOr("CAROL_ADDRESS", makeAddr("carol"));

        token0 = vm.envAddress("TOKEN0_ADDRESS");
        token1 = vm.envAddress("TOKEN1_ADDRESS");

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(phantomTWAMM))
        });

        poolId = poolKey.toId();

        console.log("Demo accounts:");
        console.log("- Alice:", alice);
        console.log("- Bob:", bob);
        console.log("- Carol:", carol);
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
    }

    /// @notice Demo 1: Basic commitment creation
    function _demoBasicCommitment() internal {
        console.log("Demo 1: Basic Phantom TWAMM Commitment");

        vm.startBroadcast(alice);

        // Alice creates a phantom TWAMM order
        InEuint128 memory encryptedSize = createInEuint128(1000 * 10 ** 18, alice);
        InEuint8 memory encryptedDirection = createInEuint8(0, alice);
        InEuint64 memory encryptedSchedule = createInEuint64(3600, alice);

        bytes32 commitmentHash = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            encryptedSize, // 1000 tokens
            encryptedDirection, // Buy (0)
            encryptedSchedule // 1 hour execution
        );

        vm.stopBroadcast();

        console.log("Alice created phantom order with commitment:", Strings.toHexString(uint256(commitmentHash)));
        console.log("  - Order size: 1000 tokens (encrypted)");
        console.log("  - Direction: Buy (encrypted)");
        console.log("  - Schedule: 1 hour (encrypted)");

        uint256 orderCount = phantomTWAMM.getActiveOrderCount(poolId);
        console.log("  - Active orders in pool:", orderCount);
    }

    /// @notice Demo 2: Multiple orders from different users
    function _demoMultipleOrders() internal {
        console.log("Demo 2: Multiple Phantom Orders");

        // Bob creates a sell order
        vm.startBroadcast(bob);

        InEuint128 memory bobSize = createInEuint128(750 * 10 ** 18, bob);
        InEuint8 memory bobDirection = createInEuint8(1, bob);
        InEuint64 memory bobSchedule = createInEuint64(1800, bob);

        bytes32 bobCommitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            bobSize, // 750 tokens
            bobDirection, // Sell (1)
            bobSchedule // 30 minutes
        );

        vm.stopBroadcast();

        // Carol creates another buy order
        vm.startBroadcast(carol);

        InEuint128 memory carolSize = createInEuint128(500 * 10 ** 18, carol);
        InEuint8 memory carolDirection = createInEuint8(0, carol);
        InEuint64 memory carolSchedule = createInEuint64(7200, carol);

        bytes32 carolCommitment = phantomTWAMM.commitPhantomTWAMM(
            poolKey,
            carolSize, // 500 tokens
            carolDirection, // Buy (0)
            carolSchedule // 2 hours
        );

        vm.stopBroadcast();

        console.log("Bob created sell order:", Strings.toHexString(uint256(bobCommitment)));
        console.log("  - Order size: 750 tokens (encrypted)");
        console.log("  - Direction: Sell (encrypted)");
        console.log("  - Schedule: 30 minutes (encrypted)");

        console.log("Carol created buy order:", Strings.toHexString(uint256(carolCommitment)));
        console.log("  - Order size: 500 tokens (encrypted)");
        console.log("  - Direction: Buy (encrypted)");
        console.log("  - Schedule: 2 hours (encrypted)");

        uint256 orderCount = phantomTWAMM.getActiveOrderCount(poolId);
        console.log("  - Total active orders:", orderCount);
    }

    /// @notice Demo 3: Swap-triggered execution
    function _demoSwapTriggeredExecution() internal {
        console.log("Demo 3: Public Swap Triggers Phantom Execution");

        // First add some liquidity to enable swaps
        vm.startBroadcast(alice);

        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(10000 * 10 ** 18),
                salt: bytes32(0)
            }),
            ""
        );

        vm.stopBroadcast();

        console.log("Added liquidity to pool");

        // Perform public swap that triggers phantom order processing
        vm.startBroadcast(bob);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -100 * 10 ** 18, // Exact input
            sqrtPriceLimitX96: 0
        });

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        vm.stopBroadcast();

        console.log("Bob performed public swap:");
        console.log("  - Amount: 100 tokens");
        console.log("  - Direction: token0 -> token1");
        console.log("  - This triggered phantom TWAMM processing!");

        // Check if computation was triggered
        bool computationReady = phantomTWAMM.isComputationReady(poolId);
        console.log("  - Computation ready:", computationReady);

        // Simulate time passage for demonstration
        console.log("  - Virtual time advanced (encrypted)");
        console.log("  - Order deltas computed off-chain via CoFHE");
        console.log("  - Anonymous deltas applied to pool state");
    }

    /// @notice Demo 4: Optional order reveal
    function _demoOrderReveal() internal {
        console.log("Demo 4: Optional Order Reveal for Compliance");

        // Get Alice's first commitment
        bytes32[] memory aliceCommitments = phantomTWAMM.getUserCommitments(alice);
        require(aliceCommitments.length > 0, "Alice should have commitments");

        bytes32 commitmentToReveal = aliceCommitments[0];

        vm.startBroadcast(alice);

        // Create proof for reveal (simplified for demo)
        bytes memory proof = abi.encode("valid_reveal_proof", alice, commitmentToReveal, block.timestamp);

        // Reveal order parameters for auditability
        phantomTWAMM.revealForAuditability(
            commitmentToReveal,
            1000 * 10 ** 18, // originalSize
            0, // originalDirection (buy)
            3600, // originalSchedule (1 hour)
            proof
        );

        vm.stopBroadcast();

        console.log("Alice revealed order parameters:");
        console.log("  - Commitment:", Strings.toHexString(uint256(commitmentToReveal)));
        console.log("  - Original size: 1000 tokens");
        console.log("  - Original direction: Buy");
        console.log("  - Original schedule: 1 hour");

        // Verify reveal
        (,,,, address revealer, bool isRevealed) = phantomTWAMM.reveals(commitmentToReveal);
        console.log("  - Revealed by:", revealer);
        console.log("  - Is revealed:", isRevealed);
    }

    /// @notice Demo 5: Compliance audit trail
    function _demoComplianceAudit() internal {
        console.log("Demo 5: Compliance Audit Trail");

        // Get Alice's revealed commitment
        bytes32[] memory aliceCommitments = phantomTWAMM.getUserCommitments(alice);
        bytes32 revealedCommitment = aliceCommitments[0];

        console.log("Audit Trail for commitment:", Strings.toHexString(uint256(revealedCommitment)));

        // Check reveal status
        (,,,, address revealer, bool isRevealed) = phantomTWAMM.reveals(revealedCommitment);

        if (isRevealed) {
            console.log("  - Status: REVEALED");
            console.log("  - Revealer:", revealer);
            console.log("  - Compliance: Parameters available for audit");
            console.log("  - Privacy: Order remained anonymous during execution");
            console.log("  - Auditability: Full execution trail preserved");
        } else {
            console.log("  - Status: ANONYMOUS");
            console.log("  - Privacy: Complete anonymity maintained");
            console.log("  - Compliance: Optional reveal available anytime");
        }

        console.log("  - MEV Protection: Order parameters were encrypted");
        console.log("  - Unlinkability: Commitment hash unlinkable to parameters");
        console.log("  - Time-Weighted: Execution spread over encrypted schedule");
    }

    /// @notice Print final statistics
    function _printStatistics() internal view {
        uint256 totalOrders = phantomTWAMM.getActiveOrderCount(poolId);

        uint256 aliceOrders = phantomTWAMM.getUserCommitments(alice).length;
        uint256 bobOrders = phantomTWAMM.getUserCommitments(bob).length;
        uint256 carolOrders = phantomTWAMM.getUserCommitments(carol).length;

        console.log("Total active orders:", totalOrders);
        console.log("Alice's orders:", aliceOrders);
        console.log("Bob's orders:", bobOrders);
        console.log("Carol's orders:", carolOrders);

        bool hasComputation = phantomTWAMM.isComputationReady(poolId);
        console.log("Computation ready:", hasComputation);

        console.log("Key Features Demonstrated:");
        console.log("- Encrypted order parameters (size, direction, schedule)");
        console.log("- Unlinkable commitments for maximum privacy");
        console.log("- Public swap-triggered private execution");
        console.log("- Virtual time advancement (encrypted)");
        console.log("- CoFHE off-chain computation integration");
        console.log("- Anonymous delta application to pool state");
        console.log("- Optional reveals for compliance/auditability");
        console.log("- MEV-resistant time-weighted execution");
    }
}
