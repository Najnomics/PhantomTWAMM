// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PhantomTWAMM
 * @dev A Uniswap V4 hook that enables private, time-weighted order execution using Fully Homomorphic Encryption (FHE)
 *
 * This contract allows traders to create phantom TWAMM orders with complete privacy - encrypting trade size,
 * direction, execution schedule, and progress. Orders remain unlinkable throughout execution, with optional
 * post-settlement reveals for auditability.
 *
 * Key Features:
 * - Encrypted order parameters (size, direction, schedule)
 * - Private virtual time advancement
 * - Hidden execution progress computed homomorphically
 * - MEV-resistant time-weighted execution
 * - Unlinkable order commitments
 * - Optional reveal for compliance/auditability
 */

// Uniswap v4 Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// Token Imports
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

// FHE Imports - Using the real CoFHE library
import {
    FHE,
    InEuint128,
    InEuint64,
    InEuint8,
    euint128,
    euint64,
    euint8,
    ebool
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

// Local Library Imports
import {VirtualTimeEngine} from "./lib/VirtualTimeEngine.sol";
import {EncryptedDeltaCalculator} from "./lib/EncryptedDeltaCalculator.sol";
import {UnlinkableCommitments} from "./lib/UnlinkableCommitments.sol";
import {OptionalRevealManager} from "./lib/OptionalRevealManager.sol";

/// @title PhantomTWAMM Hook
/// @notice Enables private time-weighted order execution on Uniswap v4
contract PhantomTWAMM is BaseHook, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // =============================================================
    //                           MODIFIERS
    // =============================================================

    modifier onlyByManager() {
        if (msg.sender != address(poolManager)) revert NotManager();
        _;
    }

    error NotManager();

    // =============================================================
    //                           STRUCTS
    // =============================================================

    /// @notice Represents a phantom TWAMM order with encrypted parameters
    struct PhantomTWAMMOrder {
        euint128 totalSize; // Fully encrypted trade size
        euint8 direction; // Fully encrypted buy/sell direction (0=buy, 1=sell)
        euint64 schedule; // Fully encrypted execution schedule (duration in seconds)
        euint128 virtualTime; // Private virtual time tracking
        euint128 executedAmount; // Hidden execution progress
        euint64 lastExecution; // Private last execution timestamp
        euint64 startTime; // Encrypted start time
        ebool isRevealed; // Optional reveal status
        bytes32 commitmentHash; // Unlinkable commitment
        address trader; // Public trader address (for settlements)
        bool settled; // Public settlement status
    }

    /// @notice Optional reveal data for post-settlement auditability
    struct OptionalReveal {
        euint128 originalSize;
        euint8 originalDirection;
        euint64 originalSchedule;
        euint64 revealTimestamp;
        address revealer;
        bool isRevealed;
    }

    /// @notice Bundled delta for anonymous execution
    struct BundledDelta {
        euint128 totalDelta; // Aggregated delta from all orders
        euint8 direction; // Net direction
        uint256 orderCount; // Number of orders processed
        bytes32 computationHash; // Verification hash
    }

    // =============================================================
    //                           STORAGE
    // =============================================================

    /// @dev Virtual time tracking per pool
    mapping(PoolId => euint64) public virtualTime;
    mapping(PoolId => euint64) public lastAdvancement;

    /// @dev Unlinkable order commitments
    mapping(bytes32 => PhantomTWAMMOrder) public phantomOrders;
    mapping(PoolId => bytes32[]) public activeCommitments;

    /// @dev Optional reveal registry
    mapping(bytes32 => OptionalReveal) public reveals;

    /// @dev Pool-commitment coordination
    mapping(PoolId => uint256) public poolOrderCount;
    mapping(address => bytes32[]) public userCommitments;

    /// @dev CoFHE computation tracking
    mapping(PoolId => bytes32) public latestComputationRequest;
    mapping(bytes32 => bool) public computationReady;
    mapping(bytes32 => BundledDelta) public computationResults;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event PhantomTWAMMCommitted(bytes32 indexed commitmentHash, PoolId indexed poolId);
    event VirtualTimeAdvanced(PoolId indexed poolId, euint64 newVirtualTime);
    event DeltaComputationRequested(PoolId indexed poolId, bytes32 indexed requestId, uint256 orderCount);
    event AnonymousDeltaApplied(PoolId indexed poolId, euint128 totalDelta);
    event OrderRevealed(bytes32 indexed commitmentHash, address indexed revealer);

    // Hook events
    event PoolInitialized(PoolId indexed poolId, address currency0, address currency1);

    // =============================================================
    //                           ERRORS
    // =============================================================

    error OrderNotFound();
    error UnauthorizedRevealer();
    error AlreadyRevealed();
    error InvalidProof();
    error ComputationNotReady();

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        // Initialize basic FHE permissions (following established patterns)
        euint128 zeroAmount = FHE.asEuint128(0);
        euint64 zeroTime = FHE.asEuint64(0);
        euint8 zeroDirection = FHE.asEuint8(0);

        FHE.allowThis(zeroAmount);
        FHE.allowThis(zeroTime);
        FHE.allowThis(zeroDirection);
    }

    // =============================================================
    //                      HOOK PERMISSIONS
    // =============================================================

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // ✅ Setup FHE infrastructure for new pools
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // ✅ CORE: Public swap triggers processing
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =============================================================
    //                    ORDER COMMITMENT
    // =============================================================

    /// @notice Commit a phantom TWAMM order with encrypted parameters
    /// @param key Pool key for the order
    /// @param encryptedSize Encrypted total trade size
    /// @param encryptedDirection Encrypted trade direction (0=buy, 1=sell)
    /// @param encryptedSchedule Encrypted execution schedule in seconds
    /// @return commitmentHash Unlinkable commitment hash for the order
    function commitPhantomTWAMM(
        PoolKey calldata key,
        InEuint128 calldata encryptedSize,
        InEuint8 calldata encryptedDirection,
        InEuint64 calldata encryptedSchedule
    ) external nonReentrant returns (bytes32 commitmentHash) {
        // Generate unlinkable commitment
        commitmentHash = keccak256(
            abi.encode(
                msg.sender,
                block.timestamp,
                encryptedSize,
                encryptedDirection,
                encryptedSchedule,
                block.prevrandao // Additional entropy
            )
        );

        // Convert encrypted inputs
        euint128 totalSize = FHE.asEuint128(encryptedSize);
        euint8 direction = FHE.asEuint8(encryptedDirection);
        euint64 schedule = FHE.asEuint64(encryptedSchedule);

        // Create encrypted state
        euint128 zeroAmount = FHE.asEuint128(0);
        euint64 startTime = FHE.asEuint64(block.timestamp);
        euint64 currentVTime = virtualTime[key.toId()];
        // Initialize virtual time if not set (use encrypted conditional)
        ebool isVTimeZero = FHE.eq(currentVTime, FHE.asEuint64(0));
        currentVTime = FHE.select(isVTimeZero, startTime, currentVTime);
        ebool notRevealed = FHE.asEbool(false);

        // Setup access controls following established patterns
        FHE.allowThis(totalSize);
        FHE.allowThis(direction);
        FHE.allowThis(schedule);
        FHE.allowThis(zeroAmount);
        FHE.allowThis(startTime);
        FHE.allowThis(currentVTime);
        FHE.allowThis(notRevealed);

        FHE.allow(totalSize, msg.sender);
        FHE.allow(direction, msg.sender);
        FHE.allow(schedule, msg.sender);

        // Store encrypted order details (unlinkable)
        PhantomTWAMMOrder storage order = phantomOrders[commitmentHash];
        order.totalSize = totalSize;
        order.direction = direction;
        order.schedule = schedule;
        order.virtualTime = FHE.asEuint128(currentVTime);
        order.executedAmount = zeroAmount;
        order.lastExecution = startTime;
        order.startTime = startTime;
        order.isRevealed = notRevealed;
        order.commitmentHash = commitmentHash;
        order.trader = msg.sender;
        order.settled = false;

        // Add to active commitments (anonymous)
        PoolId poolId = key.toId();
        activeCommitments[poolId].push(commitmentHash);
        userCommitments[msg.sender].push(commitmentHash);
        poolOrderCount[poolId]++;

        emit PhantomTWAMMCommitted(commitmentHash, poolId);
        return commitmentHash;
    }

    // =============================================================
    //                    HOOK CALLBACKS
    // =============================================================

    /// @notice Initialize FHE infrastructure for new pools
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        onlyByManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        // Initialize virtual time for this pool
        euint64 initialVirtualTime = FHE.asEuint64(block.timestamp);
        virtualTime[poolId] = initialVirtualTime;
        lastAdvancement[poolId] = initialVirtualTime;

        // Set up initial FHE permissions for pool currencies
        euint128 initialAmount = FHE.asEuint128(0);
        FHE.allowThis(initialAmount);
        FHE.allowThis(initialVirtualTime);

        // Grant permissions to pool currencies for future operations
        FHE.allow(initialAmount, Currency.unwrap(key.currency0));
        FHE.allow(initialAmount, Currency.unwrap(key.currency1));

        emit PoolInitialized(poolId, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        emit VirtualTimeAdvanced(poolId, initialVirtualTime);

        return BaseHook.afterInitialize.selector;
    }

    /// @notice Process phantom orders when public swaps occur
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        onlyByManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // Step 1: Advance virtual time (encrypted)
        advanceVirtualTime(key);

        // Step 2: Request off-chain delta computation via CoFHE
        requestDeltaComputation(key);

        // Step 3: Apply any ready computations anonymously
        applyAnonymousDeltas(key, params);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // =============================================================
    //                  VIRTUAL TIME PROCESSING
    // =============================================================

    /// @notice Advance virtual time for a pool (private advancement)
    function advanceVirtualTime(PoolKey calldata key) internal {
        PoolId poolId = key.toId();

        euint64 currentVirtualTime = virtualTime[poolId];
        euint64 lastAdvance = lastAdvancement[poolId];
        euint64 currentBlockTime = FHE.asEuint64(block.timestamp);

        // Calculate time elapsed since last advancement (encrypted)
        euint64 timeElapsed = FHE.sub(currentBlockTime, lastAdvance);

        // Advance virtual time (encrypted operation)
        euint64 newVirtualTime = FHE.add(currentVirtualTime, timeElapsed);

        // Update virtual time state
        FHE.allowThis(newVirtualTime);
        FHE.allowThis(currentBlockTime);

        virtualTime[poolId] = newVirtualTime;
        lastAdvancement[poolId] = currentBlockTime;

        emit VirtualTimeAdvanced(poolId, newVirtualTime);
    }

    // =============================================================
    //                 COFHE DELTA COMPUTATION
    // =============================================================

    /// @notice Request CoFHE to compute encrypted deltas for all active orders
    function requestDeltaComputation(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        bytes32[] memory commitments = activeCommitments[poolId];

        if (commitments.length == 0) return;

        euint64 currentVirtualTime = virtualTime[poolId];

        // Prepare data for CoFHE off-chain computation
        bytes memory computationRequest = abi.encode(poolId, commitments, currentVirtualTime, block.timestamp);

        // Generate request ID for tracking
        bytes32 requestId = keccak256(computationRequest);

        // Store request for later retrieval
        latestComputationRequest[poolId] = requestId;

        // In production, this would trigger actual CoFHE computation
        // For now, we simulate the request
        _simulateCoFHEComputation(requestId, commitments);

        emit DeltaComputationRequested(poolId, requestId, commitments.length);
    }

    /// @notice Apply computed deltas anonymously to pool state
    function applyAnonymousDeltas(PoolKey calldata key, SwapParams calldata params) internal {
        PoolId poolId = key.toId();
        bytes32 requestId = latestComputationRequest[poolId];

        if (requestId == bytes32(0) || !computationReady[requestId]) {
            return; // No computation ready
        }

        // Retrieve bundled encrypted deltas
        BundledDelta memory bundle = computationResults[requestId];

        // Check if there's any delta to apply (encrypted comparison)
        ebool hasNoDelta = FHE.eq(bundle.totalDelta, FHE.asEuint128(0));
        // We can't directly return based on encrypted comparison, so we proceed
        // The actual delta application will be zero if there's no delta

        // Apply bundled delta to pool state (anonymous - no attribution to specific orders)
        // In production, this would modify the actual pool state
        // For now, we emit the anonymous application

        FHE.allowThis(bundle.totalDelta);
        emit AnonymousDeltaApplied(poolId, bundle.totalDelta);

        // Update execution progress for orders (still encrypted)
        _updateOrderExecutionProgress(poolId, bundle);

        // Clean up processed computation
        delete computationReady[requestId];
        delete computationResults[requestId];
    }

    /// @notice Update execution progress for orders after delta application
    function _updateOrderExecutionProgress(PoolId poolId, BundledDelta memory bundle) internal {
        bytes32[] memory commitments = activeCommitments[poolId];

        for (uint256 i = 0; i < commitments.length; i++) {
            PhantomTWAMMOrder storage order = phantomOrders[commitments[i]];

            if (order.settled) continue;

            // Create memory copy for library call
            VirtualTimeEngine.PhantomTWAMMOrder memory orderMemory = VirtualTimeEngine.PhantomTWAMMOrder({
                totalSize: order.totalSize,
                direction: order.direction,
                schedule: order.schedule,
                virtualTime: order.virtualTime,
                executedAmount: order.executedAmount,
                lastExecution: order.lastExecution,
                startTime: order.startTime,
                isRevealed: order.isRevealed,
                commitmentHash: order.commitmentHash,
                trader: order.trader,
                settled: order.settled
            });

            // Calculate progress delta for this order (encrypted)
            euint128 orderDelta = VirtualTimeEngine.getVirtualTimeProgress(orderMemory, virtualTime[poolId]);

            FHE.allowThis(orderDelta);

            // Update executed amount
            euint128 newExecutedAmount = FHE.add(order.executedAmount, orderDelta);
            FHE.allowThis(newExecutedAmount);
            FHE.allow(newExecutedAmount, order.trader);

            order.executedAmount = newExecutedAmount;
            order.lastExecution = FHE.asEuint64(block.timestamp);

            // Check if order is complete (encrypted comparison)
            ebool isComplete = FHE.gte(newExecutedAmount, order.totalSize);
            FHE.allowThis(isComplete);

            // In production, would check completion without decryption
            // For demo, we'll skip the automatic settlement trigger
        }
    }

    /// @notice Simulate CoFHE computation for demo purposes
    function _simulateCoFHEComputation(bytes32 requestId, bytes32[] memory commitments) internal {
        // Simulate computation delay and result
        euint128 simulatedDelta = FHE.asEuint128(1000); // Demo value
        euint8 simulatedDirection = FHE.asEuint8(0); // Demo direction

        FHE.allowThis(simulatedDelta);
        FHE.allowThis(simulatedDirection);

        computationResults[requestId] = BundledDelta({
            totalDelta: simulatedDelta,
            direction: simulatedDirection,
            orderCount: commitments.length,
            computationHash: requestId
        });

        computationReady[requestId] = true;
    }

    // =============================================================
    //                 OPTIONAL REVEAL SYSTEM
    // =============================================================

    /// @notice Reveal order parameters for auditability/compliance
    function revealForAuditability(
        bytes32 commitmentHash,
        uint256 originalSize,
        uint8 originalDirection,
        uint64 originalSchedule,
        bytes calldata proof
    ) external nonReentrant {
        PhantomTWAMMOrder storage order = phantomOrders[commitmentHash];
        require(order.commitmentHash != bytes32(0), "Order not found");
        require(order.trader == msg.sender, "Unauthorized");
        require(!reveals[commitmentHash].isRevealed, "Already revealed");

        // Verify proof of ownership (simplified for demo)
        require(verifyRevealProof(commitmentHash, proof), "Invalid proof");

        // Create optional reveal record
        reveals[commitmentHash] = OptionalReveal({
            originalSize: FHE.asEuint128(originalSize),
            originalDirection: FHE.asEuint8(originalDirection),
            originalSchedule: FHE.asEuint64(originalSchedule),
            revealTimestamp: FHE.asEuint64(block.timestamp),
            revealer: msg.sender,
            isRevealed: true
        });

        // Mark order as revealed
        order.isRevealed = FHE.asEbool(true);
        FHE.allowThis(order.isRevealed);

        emit OrderRevealed(commitmentHash, msg.sender);
    }

    /// @notice Verify proof for revealing (simplified implementation)
    function verifyRevealProof(bytes32 commitmentHash, bytes calldata proof) internal pure returns (bool) {
        // In production, this would verify a ZK proof or signature
        // For demo, we'll accept any non-empty proof
        return proof.length > 0;
    }

    // =============================================================
    //                    VIEW FUNCTIONS
    // =============================================================

    /// @notice Get active order count for a pool
    function getActiveOrderCount(PoolId poolId) external view returns (uint256) {
        return activeCommitments[poolId].length;
    }

    /// @notice Get user's commitment hashes
    function getUserCommitments(address user) external view returns (bytes32[] memory) {
        return userCommitments[user];
    }

    /// @notice Check if computation is ready for a pool
    function isComputationReady(PoolId poolId) external view returns (bool) {
        bytes32 requestId = latestComputationRequest[poolId];
        return requestId != bytes32(0) && computationReady[requestId];
    }

    /// @notice Get pool virtual time (encrypted)
    function getPoolVirtualTime(PoolId poolId) external view returns (euint64) {
        return virtualTime[poolId];
    }
}
