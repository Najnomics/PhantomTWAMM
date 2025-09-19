// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FHE, euint128, euint64, euint8, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title OptionalRevealManager
/// @notice Library for managing optional post-settlement reveals for compliance and auditability
library OptionalRevealManager {
    /// @notice Audit receipt structure for compliance reporting
    struct AuditReceipt {
        bytes32 commitmentHash;
        bytes executionProof;
        euint64 revealTimestamp;
        bytes originalParameters;
        bytes complianceMetadata;
    }

    /// @notice Reveal request structure
    struct RevealRequest {
        bytes32 commitmentHash;
        address revealer;
        uint256 timestamp;
        bytes proof;
        bool processed;
    }

    /// @notice Compliance metadata structure
    struct ComplianceMetadata {
        string jurisdiction;
        string regulatoryFramework;
        bytes32 auditTrail;
        uint256 reportingPeriod;
        address complianceOfficer;
    }

    /// @notice Verify proof of ownership for revealing order parameters
    /// @param commitmentHash The commitment to reveal
    /// @param originalSize Original order size (plaintext)
    /// @param originalDirection Original direction (plaintext)
    /// @param originalSchedule Original schedule (plaintext)
    /// @param trader The trader who created the order
    /// @param proof Proof of ownership (signature or ZK proof)
    /// @return isValid Whether the proof is valid
    function verifyRevealProof(
        bytes32 commitmentHash,
        uint256 originalSize,
        uint8 originalDirection,
        uint64 originalSchedule,
        address trader,
        bytes memory proof
    ) internal pure returns (bool isValid) {
        // Simplified proof verification for demo
        // In production, this would verify a digital signature or ZK proof

        if (proof.length < 32) return false;

        // Reconstruct expected parameters hash
        bytes32 parametersHash = keccak256(abi.encode(originalSize, originalDirection, originalSchedule, trader));

        // Expected proof format: signature of (commitmentHash + parametersHash)
        bytes32 expectedMessage = keccak256(abi.encode(commitmentHash, parametersHash));
        bytes32 proofHash = keccak256(proof);
        bytes32 expectedProofHash = keccak256(abi.encode(expectedMessage, "valid_reveal"));

        isValid = (proofHash == expectedProofHash);
        return isValid;
    }

    /// @notice Generate execution proof for audit trail
    /// @param commitmentHash The order commitment
    /// @param executedAmount Final executed amount (encrypted)
    /// @param totalDelta Total delta applied (encrypted)
    /// @param executionTimestamps Array of execution timestamps
    /// @return executionProof Encoded proof of execution
    function generateExecutionProof(
        bytes32 commitmentHash,
        euint128 executedAmount,
        euint128 totalDelta,
        uint256[] memory executionTimestamps
    ) internal returns (bytes memory executionProof) {
        // Grant permissions for proof generation
        FHE.allowThis(executedAmount);
        FHE.allowThis(totalDelta);

        // Create execution proof structure
        executionProof = abi.encode(
            commitmentHash, executedAmount, totalDelta, executionTimestamps, block.timestamp, "execution_proof_v1"
        );

        return executionProof;
    }

    /// @notice Encode original parameters for reveal
    /// @param originalSize Original order size
    /// @param originalDirection Original direction (0=buy, 1=sell)
    /// @param originalSchedule Original execution schedule
    /// @param startTime Order start time
    /// @return encodedParameters Encoded original parameters
    function encodeOriginalParameters(
        uint256 originalSize,
        uint8 originalDirection,
        uint64 originalSchedule,
        uint64 startTime
    ) internal pure returns (bytes memory encodedParameters) {
        encodedParameters =
            abi.encode(originalSize, originalDirection, originalSchedule, startTime, "original_params_v1");

        return encodedParameters;
    }

    /// @notice Generate compliance metadata for regulatory reporting
    /// @param commitmentHash The order commitment
    /// @param jurisdiction Regulatory jurisdiction
    /// @param framework Applicable regulatory framework
    /// @param complianceOfficer Address of compliance officer
    /// @return complianceMetadata Encoded compliance metadata
    function generateComplianceMetadata(
        bytes32 commitmentHash,
        string memory jurisdiction,
        string memory framework,
        address complianceOfficer
    ) internal view returns (bytes memory complianceMetadata) {
        // Create audit trail hash
        bytes32 auditTrail = keccak256(abi.encode(commitmentHash, block.timestamp, block.number, tx.origin, msg.sender));

        // Create compliance structure
        ComplianceMetadata memory metadata = ComplianceMetadata({
            jurisdiction: jurisdiction,
            regulatoryFramework: framework,
            auditTrail: auditTrail,
            reportingPeriod: _getCurrentReportingPeriod(),
            complianceOfficer: complianceOfficer
        });

        complianceMetadata = abi.encode(metadata);
        return complianceMetadata;
    }

    /// @notice Create a full audit receipt for compliance reporting
    /// @param commitmentHash The order commitment
    /// @param executionProof Proof of execution
    /// @param originalParameters Original order parameters
    /// @param complianceMetadata Compliance metadata
    /// @return auditReceipt Complete audit receipt
    function createAuditReceipt(
        bytes32 commitmentHash,
        bytes memory executionProof,
        bytes memory originalParameters,
        bytes memory complianceMetadata
    ) internal returns (AuditReceipt memory auditReceipt) {
        euint64 revealTimestamp = FHE.asEuint64(block.timestamp);
        FHE.allowThis(revealTimestamp);

        auditReceipt = AuditReceipt({
            commitmentHash: commitmentHash,
            executionProof: executionProof,
            revealTimestamp: revealTimestamp,
            originalParameters: originalParameters,
            complianceMetadata: complianceMetadata
        });

        return auditReceipt;
    }

    /// @notice Verify the integrity of an audit receipt
    /// @param receipt The audit receipt to verify
    /// @return isValid Whether the receipt is valid
    /// @return errorCode Error code if invalid (0 = valid)
    function verifyAuditReceipt(AuditReceipt memory receipt) internal pure returns (bool isValid, uint8 errorCode) {
        // Check commitment hash is not zero
        if (receipt.commitmentHash == bytes32(0)) {
            return (false, 1); // Invalid commitment hash
        }

        // Check execution proof exists
        if (receipt.executionProof.length == 0) {
            return (false, 2); // Missing execution proof
        }

        // Check original parameters exist
        if (receipt.originalParameters.length == 0) {
            return (false, 3); // Missing original parameters
        }

        // Check compliance metadata exists
        if (receipt.complianceMetadata.length == 0) {
            return (false, 4); // Missing compliance metadata
        }

        // All checks passed
        return (true, 0);
    }

    /// @notice Generate a privacy-preserving summary for public reporting
    /// @param commitmentHash The order commitment
    /// @param totalValue Total value executed (encrypted)
    /// @param executionDuration Duration of execution
    /// @return summary Privacy-preserving execution summary
    function generatePrivacySummary(bytes32 commitmentHash, euint128 totalValue, uint64 executionDuration)
        internal
        returns (bytes memory summary)
    {
        FHE.allowThis(totalValue);

        // Create summary with limited information
        summary = abi.encode(
            commitmentHash,
            totalValue, // Encrypted value
            executionDuration,
            block.timestamp,
            "privacy_summary_v1"
        );

        return summary;
    }

    /// @notice Batch reveal multiple orders for efficiency
    /// @param commitmentHashes Array of commitments to reveal
    /// @param parameters Array of original parameters
    /// @param proofs Array of ownership proofs
    /// @return successCount Number of successful reveals
    /// @return receipts Array of audit receipts
    function batchReveal(bytes32[] memory commitmentHashes, bytes[] memory parameters, bytes[] memory proofs)
        internal
        returns (uint256 successCount, AuditReceipt[] memory receipts)
    {
        require(
            commitmentHashes.length == parameters.length && parameters.length == proofs.length, "Array length mismatch"
        );

        receipts = new AuditReceipt[](commitmentHashes.length);
        successCount = 0;

        for (uint256 i = 0; i < commitmentHashes.length; i++) {
            // Create audit receipt for each commitment
            AuditReceipt memory receipt = _createIndividualReceipt(commitmentHashes[i], parameters[i], proofs[i]);

            receipts[i] = receipt;
            if (receipt.commitmentHash != bytes32(0)) {
                successCount++;
            }
        }

        return (successCount, receipts);
    }

    /// @notice Internal helper for batch reveal
    function _createIndividualReceipt(bytes32 commitmentHash, bytes memory parameters, bytes memory proof)
        internal
        returns (AuditReceipt memory receipt)
    {
        // This would contain the logic to verify and create individual receipts
        // For demo purposes, create a basic receipt
        euint64 timestamp = FHE.asEuint64(block.timestamp);
        FHE.allowThis(timestamp);

        receipt = AuditReceipt({
            commitmentHash: commitmentHash,
            executionProof: abi.encode("execution_proof", commitmentHash),
            revealTimestamp: timestamp,
            originalParameters: parameters,
            complianceMetadata: abi.encode("compliance_metadata", commitmentHash)
        });

        return receipt;
    }

    /// @notice Get current reporting period for compliance
    /// @return period Current reporting period (e.g., quarter)
    function _getCurrentReportingPeriod() internal view returns (uint256 period) {
        // Calculate quarterly reporting period
        uint256 year = 1970 + (block.timestamp / 365 days);
        uint256 dayOfYear = (block.timestamp % 365 days) / 1 days;
        uint256 quarter = (dayOfYear / 90) + 1; // Approximate quarterly

        period = year * 10 + quarter;
        return period;
    }

    /// @notice Create a merkle proof for order execution (for privacy-preserving verification)
    /// @param commitmentHash The order commitment
    /// @param executionData Execution data to prove
    /// @param siblings Merkle siblings for proof
    /// @return merkleProof Merkle proof for verification
    function createMerkleProof(bytes32 commitmentHash, bytes memory executionData, bytes32[] memory siblings)
        internal
        pure
        returns (bytes memory merkleProof)
    {
        bytes32 leaf = keccak256(abi.encode(commitmentHash, executionData));

        merkleProof = abi.encode(leaf, siblings, "merkle_proof_v1");

        return merkleProof;
    }

    /// @notice Verify a merkle proof of execution
    /// @param proof The merkle proof to verify
    /// @param merkleRoot The expected merkle root
    /// @return isValid Whether the proof is valid
    function verifyMerkleProof(bytes memory proof, bytes32 merkleRoot) internal pure returns (bool isValid) {
        (bytes32 leaf, bytes32[] memory siblings, string memory version) =
            abi.decode(proof, (bytes32, bytes32[], string));

        if (keccak256(bytes(version)) != keccak256(bytes("merkle_proof_v1"))) {
            return false;
        }

        bytes32 computedRoot = leaf;
        for (uint256 i = 0; i < siblings.length; i++) {
            computedRoot = keccak256(abi.encode(computedRoot, siblings[i]));
        }

        isValid = (computedRoot == merkleRoot);
        return isValid;
    }
}
