// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Utility for mining hook addresses with specific permissions
library HookMiner {
    /// @notice Find a salt that will produce a hook address with the desired flags
    /// @param deployer The address that will deploy the hook
    /// @param flags The desired flags for the hook
    /// @param creationCode The creation code of the hook contract
    /// @param constructorArgs The constructor arguments for the hook
    /// @return hookAddress The computed hook address
    /// @return salt The salt to use for deployment
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        // Combine creation code with constructor args
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);

        // Try different salts until we find one that produces the desired flags
        for (uint256 i = 0; i < 1000000; i++) {
            salt = bytes32(i);

            // Compute the CREATE2 address
            hookAddress = computeAddress(deployer, salt, initCodeHash);

            // Check if this address has the desired flags
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == flags) {
                return (hookAddress, salt);
            }
        }

        revert("HookMiner: Could not find salt");
    }

    /// @notice Compute the CREATE2 address for given parameters
    /// @param deployer The deployer address
    /// @param salt The salt value
    /// @param initCodeHash The hash of the init code
    /// @return The computed address
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
