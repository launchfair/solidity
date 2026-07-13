// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DrandBLS} from "../../src/v2/v4/DrandBLS.sol";

/// @notice Thin wrapper to exercise the DrandBLS internal library externally — used to
/// validate it against the real EIP-2537 precompiles via `eth_call` state-override on
/// Robinhood Chain (the local test EVM has no BLS12-381 precompiles).
contract DrandBLSHarness {
    function verify(uint256 round, bytes calldata sig) external view returns (bool) {
        return DrandBLS.verifyBeacon(round, sig);
    }

    function hashToG1v(bytes32 message) external view returns (bytes memory) {
        return DrandBLS.hashToG1(message);
    }
}
