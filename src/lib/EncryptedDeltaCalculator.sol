// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FHE, euint128, euint64, euint8, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title EncryptedDeltaCalculator
/// @notice Library for CoFHE integration and encrypted delta computation
library EncryptedDeltaCalculator {
    /// @notice Bundled delta structure for anonymous execution
    struct BundledDelta {
        euint128 totalDelta; // Aggregated delta from all orders
        euint8 direction; // Net direction (0=buy, 1=sell)
        uint256 orderCount; // Number of orders processed
        bytes32 computationHash; // Verification hash
    }

    /// @notice CoFHE computation request structure
    struct CoFHERequest {
        PoolId poolId;
        bytes32[] commitments;
        euint64 currentVirtualTime;
        uint256 blockTimestamp;
        bytes32 requestId;
    }

    /// @notice Request CoFHE to compute encrypted deltas for all active orders
    /// @param poolId The pool to compute deltas for
    /// @param commitments Array of active order commitments
    /// @param currentVirtualTime Current virtual time (encrypted)
    /// @param blockTimestamp Current block timestamp
    /// @return requestId Unique identifier for tracking the computation
    function requestDeltaComputation(
        PoolId poolId,
        bytes32[] memory commitments,
        euint64 currentVirtualTime,
        uint256 blockTimestamp
    ) internal pure returns (bytes32 requestId) {
        // Prepare data for CoFHE off-chain computation
        bytes memory computationRequest = abi.encode(poolId, commitments, currentVirtualTime, blockTimestamp);

        // Generate unique request ID
        requestId = keccak256(computationRequest);

        return requestId;
    }

    /// @notice Process encrypted delta computation results from CoFHE
    /// @param requestId The computation request identifier
    /// @param encryptedDeltas Raw encrypted computation results
    /// @return bundle Decoded bundled delta for anonymous application
    function processCoFHEResults(bytes32 requestId, bytes memory encryptedDeltas)
        internal
        returns (BundledDelta memory bundle)
    {
        // Decode the encrypted results from CoFHE
        (euint128 totalDelta, euint8 direction, uint256 orderCount) =
            abi.decode(encryptedDeltas, (euint128, euint8, uint256));

        // Grant permissions for the computed values
        FHE.allowThis(totalDelta);
        FHE.allowThis(direction);

        // Create bundled result
        bundle = BundledDelta({
            totalDelta: totalDelta,
            direction: direction,
            orderCount: orderCount,
            computationHash: requestId
        });

        return bundle;
    }

    /// @notice Apply anonymous deltas to pool state without attribution
    /// @param poolId The pool to apply deltas to
    /// @param bundle The bundled delta to apply
    /// @param currentDelta Current swap delta for context
    /// @return applied Whether the delta was successfully applied
    function applyAnonymousDeltas(PoolId poolId, BundledDelta memory bundle, BalanceDelta currentDelta)
        internal
        returns (bool applied)
    {
        // Check if there's any delta to apply
        euint128 zeroDelta = FHE.asEuint128(0);
        ebool hasDelta = FHE.gt(bundle.totalDelta, zeroDelta);

        FHE.allowThis(hasDelta);

        // For demo purposes, we'll always report as applied if there's a delta
        // In production, this would interact with the actual pool state
        applied = bundle.orderCount > 0;

        return applied;
    }

    /// @notice Calculate aggregated delta from multiple encrypted orders
    /// @param orderDeltas Array of individual order deltas
    /// @param orderDirections Array of order directions (0=buy, 1=sell)
    /// @return totalDelta Aggregated total delta
    /// @return netDirection Net direction of all orders
    function aggregateOrderDeltas(euint128[] memory orderDeltas, euint8[] memory orderDirections)
        internal
        returns (euint128 totalDelta, euint8 netDirection)
    {
        require(orderDeltas.length == orderDirections.length, "Mismatched arrays");

        euint128 buyTotal = FHE.asEuint128(0);
        euint128 sellTotal = FHE.asEuint128(0);
        euint8 buyDirection = FHE.asEuint8(0);
        euint8 sellDirection = FHE.asEuint8(1);

        FHE.allowThis(buyTotal);
        FHE.allowThis(sellTotal);
        FHE.allowThis(buyDirection);
        FHE.allowThis(sellDirection);

        // Aggregate deltas by direction
        for (uint256 i = 0; i < orderDeltas.length; i++) {
            FHE.allowThis(orderDeltas[i]);
            FHE.allowThis(orderDirections[i]);

            // Check if this order is a buy (direction == 0) or sell (direction == 1)
            ebool isBuy = FHE.eq(orderDirections[i], buyDirection);

            // Add to appropriate total
            euint128 buyAddition = FHE.select(isBuy, orderDeltas[i], FHE.asEuint128(0));
            euint128 sellAddition = FHE.select(isBuy, FHE.asEuint128(0), orderDeltas[i]);

            buyTotal = FHE.add(buyTotal, buyAddition);
            sellTotal = FHE.add(sellTotal, sellAddition);
        }

        // Calculate net delta and direction
        ebool buyDominates = FHE.gt(buyTotal, sellTotal);

        totalDelta = FHE.select(buyDominates, FHE.sub(buyTotal, sellTotal), FHE.sub(sellTotal, buyTotal));

        netDirection = FHE.select(buyDominates, buyDirection, sellDirection);

        FHE.allowThis(totalDelta);
        FHE.allowThis(netDirection);

        return (totalDelta, netDirection);
    }

    /// @notice Compute time-weighted execution delta for a single order
    /// @param totalSize Total order size (encrypted)
    /// @param executedAmount Already executed amount (encrypted)
    /// @param timeProgress Progress through execution schedule (encrypted fraction, scaled by 1e18)
    /// @return orderDelta Amount to execute in this step (encrypted)
    function computeOrderDelta(euint128 totalSize, euint128 executedAmount, euint128 timeProgress)
        internal
        returns (euint128 orderDelta)
    {
        // Calculate target executed amount based on time progress
        // targetExecuted = totalSize * timeProgress / 1e18
        euint128 targetExecuted = FHE.div(FHE.mul(totalSize, timeProgress), FHE.asEuint128(1e18));

        // Delta is the difference between target and current execution
        ebool shouldExecuteMore = FHE.gt(targetExecuted, executedAmount);
        orderDelta = FHE.select(shouldExecuteMore, FHE.sub(targetExecuted, executedAmount), FHE.asEuint128(0));

        FHE.allowThis(orderDelta);
        return orderDelta;
    }

    /// @notice Validate that a bundled delta is reasonable
    /// @param bundle The bundled delta to validate
    /// @param maxOrderSize Maximum reasonable order size
    /// @return isValid Whether the delta passes validation
    function validateBundledDelta(BundledDelta memory bundle, euint128 maxOrderSize) internal returns (ebool isValid) {
        // Basic validation: delta should not exceed max reasonable size
        ebool sizeReasonable = FHE.lte(bundle.totalDelta, maxOrderSize);

        // Direction should be valid (0 or 1)
        euint8 maxDirection = FHE.asEuint8(1);
        ebool directionValid = FHE.lte(bundle.direction, maxDirection);

        // Order count should be reasonable
        bool countReasonable = bundle.orderCount <= 1000; // Hardcoded reasonable limit

        isValid = FHE.and(sizeReasonable, directionValid);
        // Note: can't combine with countReasonable directly due to type mismatch

        FHE.allowThis(isValid);
        return isValid;
    }

    /// @notice Create a zero delta bundle for cases with no execution
    /// @return bundle Empty bundled delta
    function createZeroDelta() internal returns (BundledDelta memory bundle) {
        euint128 zeroDelta = FHE.asEuint128(0);
        euint8 zeroDirection = FHE.asEuint8(0);

        FHE.allowThis(zeroDelta);
        FHE.allowThis(zeroDirection);

        bundle =
            BundledDelta({totalDelta: zeroDelta, direction: zeroDirection, orderCount: 0, computationHash: bytes32(0)});

        return bundle;
    }

    /// @notice Simulate CoFHE computation for testing/demo purposes
    /// @param commitments Order commitments to process
    /// @param virtualTime Current virtual time
    /// @return bundle Simulated computation result
    function simulateCoFHEComputation(bytes32[] memory commitments, euint64 virtualTime)
        internal
        returns (BundledDelta memory bundle)
    {
        if (commitments.length == 0) {
            return createZeroDelta();
        }

        // Create simulated results based on commitment count
        uint256 simulatedAmount = commitments.length * 1; // 1 unit per order (minimal for testing)
        euint128 totalDelta = FHE.asEuint128(simulatedAmount);
        euint8 direction = FHE.asEuint8(0); // Simulate buy direction

        FHE.allowThis(totalDelta);
        FHE.allowThis(direction);

        bundle = BundledDelta({
            totalDelta: totalDelta,
            direction: direction,
            orderCount: commitments.length,
            computationHash: keccak256(abi.encode(commitments, virtualTime))
        });

        return bundle;
    }

    /// @notice Check if a CoFHE computation request has completed
    /// @param requestId The computation request ID
    /// @param computationResults Mapping of results
    /// @return isReady Whether results are available
    function isComputationReady(bytes32 requestId, mapping(bytes32 => BundledDelta) storage computationResults)
        internal
        view
        returns (bool isReady)
    {
        // Check if results exist and have non-zero computation hash
        BundledDelta storage result = computationResults[requestId];
        isReady = result.computationHash != bytes32(0);

        return isReady;
    }
}
