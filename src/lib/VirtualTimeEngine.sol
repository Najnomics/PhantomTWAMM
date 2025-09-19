// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FHE, euint128, euint64, euint8, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title VirtualTimeEngine
/// @notice Library for encrypted virtual time advancement and progress calculation
library VirtualTimeEngine {
    /// @notice Phantom TWAMM order structure (imported interface)
    struct PhantomTWAMMOrder {
        euint128 totalSize;
        euint8 direction;
        euint64 schedule;
        euint128 virtualTime;
        euint128 executedAmount;
        euint64 lastExecution;
        euint64 startTime;
        ebool isRevealed;
        bytes32 commitmentHash;
        address trader;
        bool settled;
    }

    /// @notice Advance virtual time for a pool (encrypted operation)
    /// @param currentVirtualTime Current encrypted virtual time
    /// @param lastAdvance Last advancement timestamp (encrypted)
    /// @param currentBlockTime Current block timestamp
    /// @return newVirtualTime Advanced virtual time (encrypted)
    function advanceVirtualTime(euint64 currentVirtualTime, euint64 lastAdvance, uint256 currentBlockTime)
        internal
        returns (euint64 newVirtualTime)
    {
        euint64 currentBlockTimeEnc = FHE.asEuint64(currentBlockTime);

        // Calculate time elapsed since last advancement (encrypted)
        euint64 timeElapsed = FHE.sub(currentBlockTimeEnc, lastAdvance);

        // Advance virtual time (encrypted operation)
        newVirtualTime = FHE.add(currentVirtualTime, timeElapsed);

        // Grant permissions for the new virtual time
        FHE.allowThis(newVirtualTime);

        return newVirtualTime;
    }

    /// @notice Calculate execution progress based on virtual time advancement
    /// @param order The phantom order to calculate progress for
    /// @param currentVirtualTime Current pool virtual time (encrypted)
    /// @return deltaAmount Amount to execute in this time step (encrypted)
    function getVirtualTimeProgress(PhantomTWAMMOrder memory order, euint64 currentVirtualTime)
        internal
        returns (euint128 deltaAmount)
    {
        // Calculate execution time elapsed
        euint64 executionTime = FHE.sub(currentVirtualTime, order.startTime);

        // Clamp to total schedule duration
        euint64 clampedTime = FHE.min(executionTime, order.schedule);

        // Calculate proportion of order that should be executed by now
        // proportionExecuted = clampedTime / schedule (with precision scaling)
        euint128 clampedTimeScaled = FHE.mul(
            FHE.asEuint128(clampedTime),
            FHE.asEuint128(1e18) // Precision scale
        );
        euint128 proportionExecuted = FHE.div(clampedTimeScaled, FHE.asEuint128(order.schedule));

        // Calculate target executed amount
        euint128 targetExecuted = FHE.div(
            FHE.mul(order.totalSize, proportionExecuted),
            FHE.asEuint128(1e18) // Remove precision scale
        );

        // Delta is the difference between target and current execution
        deltaAmount = FHE.sub(targetExecuted, order.executedAmount);

        // Ensure delta is not negative (can happen due to rounding)
        ebool deltaIsPositive = FHE.gt(targetExecuted, order.executedAmount);
        deltaAmount = FHE.select(deltaIsPositive, deltaAmount, FHE.asEuint128(0));

        // Grant permissions for the delta
        FHE.allowThis(deltaAmount);
        FHE.allow(deltaAmount, order.trader);

        return deltaAmount;
    }

    /// @notice Calculate time-weighted execution rate for an order
    /// @param order The phantom order
    /// @param virtualTimeElapsed Time elapsed in virtual time (encrypted)
    /// @return executionRate Rate of execution per time unit (encrypted)
    function calculateExecutionRate(PhantomTWAMMOrder memory order, euint64 virtualTimeElapsed)
        internal
        returns (euint128 executionRate)
    {
        // Rate = totalSize / schedule (amount per time unit)
        executionRate = FHE.div(order.totalSize, FHE.asEuint128(order.schedule));

        FHE.allowThis(executionRate);
        return executionRate;
    }

    /// @notice Check if an order is complete based on virtual time
    /// @param order The phantom order
    /// @param currentVirtualTime Current virtual time (encrypted)
    /// @return isComplete Whether the order execution window is complete (encrypted)
    function isOrderComplete(PhantomTWAMMOrder memory order, euint64 currentVirtualTime)
        internal
        returns (ebool isComplete)
    {
        // Check if virtual time has passed the order's end time
        euint64 orderEndTime = FHE.add(order.startTime, order.schedule);
        isComplete = FHE.gte(currentVirtualTime, orderEndTime);

        FHE.allowThis(isComplete);
        return isComplete;
    }

    /// @notice Check if an order should be executed based on virtual time
    /// @param order The phantom order
    /// @param currentVirtualTime Current virtual time (encrypted)
    /// @return shouldExecute Whether the order should execute now (encrypted)
    function shouldExecute(PhantomTWAMMOrder memory order, euint64 currentVirtualTime) internal returns (ebool) {
        // Should execute if:
        // 1. Virtual time is past start time
        // 2. Virtual time is before end time
        // 3. Not fully executed yet

        ebool pastStart = FHE.gte(currentVirtualTime, order.startTime);

        euint64 endTime = FHE.add(order.startTime, order.schedule);
        ebool beforeEnd = FHE.lt(currentVirtualTime, endTime);

        ebool notFullyExecuted = FHE.lt(order.executedAmount, order.totalSize);

        // All conditions must be true
        ebool result = FHE.and(FHE.and(pastStart, beforeEnd), notFullyExecuted);

        FHE.allowThis(result);
        return result;
    }

    /// @notice Calculate remaining execution time for an order
    /// @param order The phantom order
    /// @param currentVirtualTime Current virtual time (encrypted)
    /// @return remainingTime Time remaining for execution (encrypted)
    function getRemainingTime(PhantomTWAMMOrder memory order, euint64 currentVirtualTime)
        internal
        returns (euint64 remainingTime)
    {
        euint64 endTime = FHE.add(order.startTime, order.schedule);

        // If current time is past end time, remaining time is 0
        ebool isPastEnd = FHE.gte(currentVirtualTime, endTime);

        euint64 timeLeft = FHE.sub(endTime, currentVirtualTime);
        remainingTime = FHE.select(isPastEnd, FHE.asEuint64(0), timeLeft);

        FHE.allowThis(remainingTime);
        return remainingTime;
    }

    /// @notice Calculate virtual time delta needed for complete execution
    /// @param order The phantom order
    /// @return timeDelta Virtual time needed to complete order (encrypted)
    function getCompletionTimeDelta(PhantomTWAMMOrder memory order) internal returns (euint64 timeDelta) {
        // Remaining time is schedule minus elapsed time since start
        // But since we don't have current time, we just return the full schedule
        timeDelta = order.schedule;

        FHE.allowThis(timeDelta);
        return timeDelta;
    }

    /// @notice Update order's virtual time tracking
    /// @param order The phantom order (storage reference needed)
    /// @param newVirtualTime New virtual time to set
    function updateOrderVirtualTime(PhantomTWAMMOrder storage order, euint64 newVirtualTime) internal {
        order.virtualTime = FHE.asEuint128(newVirtualTime);

        FHE.allowThis(order.virtualTime);
        FHE.allow(order.virtualTime, order.trader);
    }
}
