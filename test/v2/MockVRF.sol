// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRandomnessConsumer} from "../../src/v2/v4/LaunchFairVRFCoordinator.sol";

/// @notice Test double for LaunchFairVRFCoordinator. Mirrors its push/pull semantics
/// (requestRandomness → id, randomnessOf pull, fulfillRandomness fan-out) but skips the
/// on-chain BLS verification — the real precompiles aren't available in the local test
/// EVM. `deliver(round, value)` stands in for a verified `postRandomness`, letting the
/// distributor's lottery tests drive an arbitrary randomness value. The real
/// coordinator's verification is covered by DrandBLS.t.sol / the live-RPC validation.
contract MockVRFCoordinator {
    struct Request {
        address consumer;
        uint256 round;
        bool fulfilled;
    }

    uint256 public nextRequestId = 1;
    mapping(uint256 => Request) public requests;
    mapping(uint256 => uint256[]) internal _roundRequests;
    mapping(uint256 => bytes32) public randomnessOf;

    function requestRandomness(uint256 round) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        requests[requestId] = Request({consumer: msg.sender, round: round, fulfilled: false});
        _roundRequests[round].push(requestId);
        bytes32 r = randomnessOf[round];
        if (r != bytes32(0)) _fulfill(requestId, r);
    }

    /// @notice Test-only: deliver a (pretend-verified) randomness value for `round`.
    function deliver(uint256 round, bytes32 randomness) external {
        randomnessOf[round] = randomness;
        uint256[] memory ids = _roundRequests[round];
        for (uint256 i; i < ids.length; i++) {
            _fulfill(ids[i], randomness);
        }
    }

    function _fulfill(uint256 requestId, bytes32 randomness) internal {
        Request storage req = requests[requestId];
        if (req.fulfilled || req.consumer == address(0)) return;
        req.fulfilled = true;
        try IRandomnessConsumer(req.consumer).fulfillRandomness(requestId, randomness) {} catch {}
    }
}
