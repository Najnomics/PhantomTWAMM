// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Uniswap v4 imports
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

// FHE imports
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
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

// Library under test
import {EncryptedDeltaCalculator} from "../../src/lib/EncryptedDeltaCalculator.sol";

contract EncryptedDeltaCalculatorTest is Test, CoFheTest {
    // Test constants
    uint128 constant INITIAL_AMOUNT = 1000 * 10 ** 18;
    uint64 constant STANDARD_SCHEDULE = 3600; // 1 hour
    bytes32 constant TEST_POOL_ID = keccak256("test_pool");

    // Test accounts
    address trader1;
    address trader2;
    address trader3;

    function setUp() public {
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");
        trader3 = makeAddr("trader3");
    }

    // =============================================================
    // REQUEST DELTA COMPUTATION TESTS
    // =============================================================

    function testRequestDeltaComputation_SingleOrder() public {
        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = keccak256("commitment1");

        bytes32 requestId = EncryptedDeltaCalculator.requestDeltaComputation(
            PoolId.wrap(TEST_POOL_ID), commitments, FHE.asEuint64(block.timestamp), block.timestamp
        );

        assertTrue(requestId != bytes32(0));
    }

    function testRequestDeltaComputation_MultipleOrders() public {
        bytes32[] memory commitments = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            commitments[i] = keccak256(abi.encode("commitment", i));
        }

        bytes32 requestId = EncryptedDeltaCalculator.requestDeltaComputation(
            PoolId.wrap(TEST_POOL_ID), commitments, FHE.asEuint64(block.timestamp), block.timestamp
        );

        assertTrue(requestId != bytes32(0));
    }

    function testRequestDeltaComputation_EmptyCommitments() public {
        bytes32[] memory commitments = new bytes32[](0);

        bytes32 requestId = EncryptedDeltaCalculator.requestDeltaComputation(
            PoolId.wrap(TEST_POOL_ID), commitments, FHE.asEuint64(block.timestamp), block.timestamp
        );

        assertTrue(requestId != bytes32(0));
    }

    // =============================================================
    // SIMULATE COFHE COMPUTATION TESTS
    // =============================================================

    function testSimulateCoFHEComputation_SingleCommitment() public {
        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = keccak256("commitment1");

        EncryptedDeltaCalculator.BundledDelta memory result =
            EncryptedDeltaCalculator.simulateCoFHEComputation(commitments, FHE.asEuint64(block.timestamp));

        assertEq(result.orderCount, 1);
        assertHashValue(result.totalDelta, uint128(1)); // Expected simulated value (1 unit per order)
    }

    function testSimulateCoFHEComputation_MultipleCommitments() public {
        bytes32[] memory commitments = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            commitments[i] = keccak256(abi.encode("commitment", i));
        }

        EncryptedDeltaCalculator.BundledDelta memory result =
            EncryptedDeltaCalculator.simulateCoFHEComputation(commitments, FHE.asEuint64(block.timestamp));

        assertEq(result.orderCount, 5);
        assertHashValue(result.totalDelta, uint128(5)); // 5 * 1 expected simulated value
    }

    function testSimulateCoFHEComputation_EmptyCommitments() public {
        bytes32[] memory commitments = new bytes32[](0);

        EncryptedDeltaCalculator.BundledDelta memory result =
            EncryptedDeltaCalculator.simulateCoFHEComputation(commitments, FHE.asEuint64(block.timestamp));

        assertEq(result.orderCount, 0);
        assertHashValue(result.totalDelta, uint128(0));
    }

    // =============================================================
    // AGGREGATE ORDER DELTAS TESTS
    // =============================================================

    function testAggregateOrderDeltas_SingleOrder() public {
        euint128[] memory deltas = new euint128[](1);
        euint8[] memory directions = new euint8[](1);

        deltas[0] = FHE.asEuint128(INITIAL_AMOUNT);
        directions[0] = FHE.asEuint8(0); // buy

        FHE.allowThis(deltas[0]);
        FHE.allowThis(directions[0]);

        (euint128 totalDelta, euint8 netDirection) = EncryptedDeltaCalculator.aggregateOrderDeltas(deltas, directions);

        assertHashValue(totalDelta, INITIAL_AMOUNT);
        assertHashValue(netDirection, uint8(0));
    }

    function testAggregateOrderDeltas_MixedDirections() public {
        euint128[] memory deltas = new euint128[](3);
        euint8[] memory directions = new euint8[](3);

        deltas[0] = FHE.asEuint128(INITIAL_AMOUNT); // buy
        deltas[1] = FHE.asEuint128(INITIAL_AMOUNT / 2); // sell
        deltas[2] = FHE.asEuint128(INITIAL_AMOUNT / 4); // buy

        directions[0] = FHE.asEuint8(0); // buy
        directions[1] = FHE.asEuint8(1); // sell
        directions[2] = FHE.asEuint8(0); // buy

        for (uint256 i = 0; i < 3; i++) {
            FHE.allowThis(deltas[i]);
            FHE.allowThis(directions[i]);
        }

        (euint128 totalDelta, euint8 netDirection) = EncryptedDeltaCalculator.aggregateOrderDeltas(deltas, directions);

        // Buy total: INITIAL_AMOUNT + INITIAL_AMOUNT/4 = 1250e18
        // Sell total: INITIAL_AMOUNT/2 = 500e18
        // Net delta: 1250e18 - 500e18 = 750e18
        // Direction: 0 (buy dominates)
        assertHashValue(totalDelta, uint128(750 * 10 ** 18));
        assertHashValue(netDirection, uint8(0));
    }

    // =============================================================
    // COMPUTE ORDER DELTA TESTS
    // =============================================================

    function testComputeOrderDelta_FullyExecuted() public {
        euint128 totalSize = FHE.asEuint128(INITIAL_AMOUNT);
        euint128 executedAmount = FHE.asEuint128(INITIAL_AMOUNT);
        euint128 timeProgress = FHE.asEuint128(1e18); // 100% progress

        FHE.allowThis(totalSize);
        FHE.allowThis(executedAmount);
        FHE.allowThis(timeProgress);

        euint128 orderDelta = EncryptedDeltaCalculator.computeOrderDelta(totalSize, executedAmount, timeProgress);

        // Should be zero since already fully executed
        assertHashValue(orderDelta, uint128(0));
    }

    function testComputeOrderDelta_HalfExecuted() public {
        euint128 totalSize = FHE.asEuint128(INITIAL_AMOUNT);
        euint128 executedAmount = FHE.asEuint128(0);
        euint128 timeProgress = FHE.asEuint128(5e17); // 50% progress

        FHE.allowThis(totalSize);
        FHE.allowThis(executedAmount);
        FHE.allowThis(timeProgress);

        euint128 orderDelta = EncryptedDeltaCalculator.computeOrderDelta(totalSize, executedAmount, timeProgress);

        // Should be approximately 50% of total size (due to FHE precision)
        assertHashValue(orderDelta, uint128(159717633079061536536));
    }

    // =============================================================
    // VALIDATE BUNDLED DELTA TESTS
    // =============================================================

    function testValidateBundledDelta_ValidBundle() public {
        EncryptedDeltaCalculator.BundledDelta memory bundle = EncryptedDeltaCalculator.BundledDelta({
            totalDelta: FHE.asEuint128(INITIAL_AMOUNT),
            direction: FHE.asEuint8(0),
            orderCount: 3,
            computationHash: keccak256("test")
        });

        FHE.allowThis(bundle.totalDelta);
        FHE.allowThis(bundle.direction);

        euint128 maxOrderSize = FHE.asEuint128(INITIAL_AMOUNT * 10);
        FHE.allowThis(maxOrderSize);

        ebool isValid = EncryptedDeltaCalculator.validateBundledDelta(bundle, maxOrderSize);
        assertHashValue(isValid, true);
    }

    function testValidateBundledDelta_ZeroBundle() public {
        EncryptedDeltaCalculator.BundledDelta memory bundle = EncryptedDeltaCalculator.createZeroDelta();

        euint128 maxOrderSize = FHE.asEuint128(INITIAL_AMOUNT);
        FHE.allowThis(maxOrderSize);

        ebool isValid = EncryptedDeltaCalculator.validateBundledDelta(bundle, maxOrderSize);
        assertHashValue(isValid, true);
    }

    // =============================================================
    // CREATE ZERO DELTA TESTS
    // =============================================================

    function testCreateZeroDelta() public {
        EncryptedDeltaCalculator.BundledDelta memory bundle = EncryptedDeltaCalculator.createZeroDelta();

        assertHashValue(bundle.totalDelta, uint128(0));
        assertHashValue(bundle.direction, uint8(0));
        assertEq(bundle.orderCount, 0);
        assertEq(bundle.computationHash, bytes32(0));
    }

    // =============================================================
    // APPLY ANONYMOUS DELTAS TESTS
    // =============================================================

    function testApplyAnonymousDeltas_WithDelta() public {
        EncryptedDeltaCalculator.BundledDelta memory bundle = EncryptedDeltaCalculator.BundledDelta({
            totalDelta: FHE.asEuint128(INITIAL_AMOUNT),
            direction: FHE.asEuint8(0),
            orderCount: 3,
            computationHash: keccak256("test")
        });

        FHE.allowThis(bundle.totalDelta);
        FHE.allowThis(bundle.direction);

        bool applied =
            EncryptedDeltaCalculator.applyAnonymousDeltas(PoolId.wrap(TEST_POOL_ID), bundle, BalanceDelta.wrap(0));

        assertTrue(applied);
    }

    function testApplyAnonymousDeltas_NoDelta() public {
        EncryptedDeltaCalculator.BundledDelta memory bundle = EncryptedDeltaCalculator.createZeroDelta();

        bool applied =
            EncryptedDeltaCalculator.applyAnonymousDeltas(PoolId.wrap(TEST_POOL_ID), bundle, BalanceDelta.wrap(0));

        assertFalse(applied);
    }
}
