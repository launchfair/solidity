// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — https://hood.launchfair.app

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Anything that consumes randomness from the coordinator implements this.
/// The coordinator PUSHES the beacon here when it's posted (self-emitting); a
/// consumer may also PULL `randomnessOf(round)` as a fallback.
interface IRandomnessConsumer {
    function fulfillRandomness(uint256 requestId, bytes32 randomness) external;
}

/// @notice Our own reusable randomness coordinator for LaunchFair lotteries — so
/// we never pay a third-party VRF, and one contract serves every lottery we
/// deploy.
///
/// The entropy is **drand** (a public, BLS-signed randomness beacon) which is
/// free; this contract just brings it on-chain and fans it out. Flow:
///   1. a lottery `requestRandomness(round)` for a FUTURE drand round (its beacon
///      doesn't exist yet, so it can't be known or ground in advance);
///   2. our keeper `postRandomness(round, beacon)` ONCE per round — that single
///      transaction PUSHES the value to every consumer waiting on that round
///      (self-emitting; no one has to pull it);
///   3. any consumer whose push reverted can still read `randomnessOf(round)`.
///
/// A round's value is write-once (can't be changed once posted) and identical for
/// every consumer, and re-verifiable off-chain against the drand round. The keeper
/// (`poster`) is trusted only to post the *real* drand value — publicly checkable —
/// it cannot fabricate randomness that verifiers would accept.
contract LaunchFairVRFCoordinator is Ownable {
    address public poster; // the keeper that brings drand beacons on-chain

    struct Request {
        address consumer;
        uint256 round;
        bool fulfilled;
    }

    uint256 public nextRequestId = 1;
    mapping(uint256 requestId => Request) public requests;
    mapping(uint256 round => uint256[]) internal _roundRequests; // ids awaiting a round
    mapping(uint256 round => bytes32) public randomnessOf; // 0 until posted (pull path)

    event PosterSet(address poster);
    event Requested(uint256 indexed requestId, address indexed consumer, uint256 indexed round);
    event Posted(uint256 indexed round, bytes32 randomness, uint256 consumers);
    event Fulfilled(uint256 indexed requestId, address indexed consumer, bool ok);

    error OnlyPoster();
    error ZeroAddress();
    error BadRandomness();
    error AlreadyPosted();

    constructor(address owner_, address poster_) Ownable(owner_) {
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
    }

    /// @notice Point the coordinator at a new keeper wallet.
    function setPoster(address poster_) external onlyOwner {
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
        emit PosterSet(poster_);
    }

    /// @notice A consumer asks for the drand beacon at a FUTURE `round`. Returns an
    /// id it can key its pending draw on. If the round is somehow already posted
    /// (a late request), it's fulfilled inline.
    function requestRandomness(uint256 round) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        requests[requestId] = Request({consumer: msg.sender, round: round, fulfilled: false});
        _roundRequests[round].push(requestId);
        emit Requested(requestId, msg.sender, round);

        bytes32 r = randomnessOf[round];
        if (r != bytes32(0)) _fulfill(requestId, r);
    }

    /// @notice Keeper posts the drand beacon for `round` ONCE. Stores it (pull
    /// path) and pushes it to every consumer that requested it (self-emitting).
    function postRandomness(uint256 round, bytes32 randomness) external {
        if (msg.sender != poster) revert OnlyPoster();
        if (randomness == bytes32(0)) revert BadRandomness();
        if (randomnessOf[round] != bytes32(0)) revert AlreadyPosted();
        randomnessOf[round] = randomness;

        uint256[] memory ids = _roundRequests[round];
        for (uint256 i; i < ids.length; i++) {
            _fulfill(ids[i], randomness);
        }
        emit Posted(round, randomness, ids.length);
    }

    /// @dev Best-effort push (checks-effects-interactions: mark handled, then
    /// notify — so a reentrant consumer can't be pushed twice). A consumer whose
    /// push reverts still reads the value via `randomnessOf(round)`, so one bad
    /// consumer never blocks the fan-out or the others' liveness.
    function _fulfill(uint256 requestId, bytes32 randomness) internal {
        Request storage req = requests[requestId];
        if (req.fulfilled || req.consumer == address(0)) return;
        req.fulfilled = true;
        bool ok;
        try IRandomnessConsumer(req.consumer).fulfillRandomness(requestId, randomness) {
            ok = true;
        } catch {
            ok = false;
        }
        emit Fulfilled(requestId, req.consumer, ok);
    }
}
