// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — https://hood.launchfair.app

import {DrandBLS} from "./DrandBLS.sol";

/// @notice A consumer that reads verified randomness from the coordinator. Kept for
/// integration typing; the coordinator is pull-based (consumers read `randomnessOf`).
interface IRandomnessConsumer {
    function fulfillRandomness(uint256 requestId, bytes32 randomness) external;
}

/// @notice Our own reusable randomness coordinator for LaunchFair lotteries — so we
/// never pay a third-party VRF, and one contract serves every lottery we deploy.
///
/// The entropy is **drand quicknet** (a public, BLS-signed randomness beacon), free;
/// this contract brings it on-chain and **verifies the BLS signature**. Flow:
///   1. a lottery `requestRandomness(round)` for a FUTURE drand round (emits an event
///      for indexers; the round's beacon doesn't exist yet, so it can't be ground);
///   2. ANYONE `postRandomness(round, signature)` ONCE per round — the coordinator
///      verifies the drand signature against the quicknet public key (see DrandBLS)
///      and rejects anything that isn't the real beacon, then stores it;
///   3. consumers read `randomnessOf(round)`.
///
/// Because the signature is verified on-chain, `postRandomness` is **permissionless and
/// trustless**: no one can substitute a value of their choosing — a forged beacon simply
/// reverts. The stored value is `keccak256(signature)`: write-once, identical for every
/// reader, and re-derivable by anyone from the public drand signature for the round.
///
/// **Pull-based by design (audit H-01):** posting is O(1) and does NOT iterate any
/// per-round list, so no one can bloat a round's request set to make `postRandomness`
/// run out of gas and block a lottery from ever settling. Consumers read the value; the
/// LaunchFair distributor pulls `randomnessOf(pd.round)` in `settleDraw`.
contract LaunchFairVRFCoordinator {
    uint256 public nextRequestId = 1;
    mapping(uint256 round => bytes32) public randomnessOf; // 0 until posted

    event Requested(uint256 indexed requestId, address indexed consumer, uint256 indexed round);
    event Posted(uint256 indexed round, bytes32 randomness);

    error BadRandomness();
    error AlreadyPosted();

    /// @notice Register interest in a FUTURE round's beacon; returns an id (and emits an
    /// event) a consumer can key its pending draw on. O(1) and stores no per-round list.
    function requestRandomness(uint256 round) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        emit Requested(requestId, msg.sender, round);
    }

    /// @notice Bring the drand quicknet beacon for `round` on-chain, ONCE. `signature` is
    /// the beacon's BLS signature as an EIP-2537 uncompressed G1 point (128 bytes). It is
    /// VERIFIED against the quicknet public key; anything that isn't the real beacon
    /// reverts, so this is permissionless. Stores `keccak256(signature)`. O(1) — no
    /// fan-out loop, so it cannot be gas-griefed into failing (audit H-01).
    function postRandomness(uint256 round, bytes calldata signature) external {
        if (randomnessOf[round] != bytes32(0)) revert AlreadyPosted();
        if (!DrandBLS.verifyBeacon(round, signature)) revert BadRandomness();
        bytes32 randomness = keccak256(signature);
        randomnessOf[round] = randomness;
        emit Posted(round, randomness);
    }
}
