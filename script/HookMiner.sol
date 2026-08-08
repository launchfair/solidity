// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Finds a CREATE2 salt whose resulting address encodes the given hook permission flags
/// in its low 14 bits (Uniswap V4 requires this). Deterministic-deploy-proxy compatible.
library HookMiner {
    uint160 internal constant FLAG_MASK = 0x3FFF; // low 14 bits carry the hook permissions
    uint256 internal constant MAX_LOOP = 1_000_000;

    /// @param deployer The CREATE2 deployer (the deterministic proxy 0x4e59… under forge broadcast).
    /// @param flags The required permission bits (e.g. beforeSwap|afterSwap|*ReturnsDelta).
    /// @param creationCode `type(Hook).creationCode`.
    /// @param constructorArgs abi.encode(...) of the hook's constructor args (must match the deploy).
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initcodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = _addr(deployer, salt, initcodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, salt);
        }
        revert("HookMiner: no salt found");
    }

    function _addr(address deployer, bytes32 salt, bytes32 initcodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initcodeHash)))));
    }
}
