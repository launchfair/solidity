// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LaunchFairVRFCoordinator, IRandomnessConsumer} from "../../src/v2/v4/LaunchFairVRFCoordinator.sol";

/// @notice A consumer that records its last push. `boom` makes it revert, to test
/// that one bad consumer can't block the fan-out.
contract MockConsumer is IRandomnessConsumer {
    uint256 public lastRequestId;
    bytes32 public lastRandomness;
    uint256 public calls;
    bool public boom;

    function setBoom(bool b) external {
        boom = b;
    }

    function request(LaunchFairVRFCoordinator vrf, uint256 round) external returns (uint256) {
        return vrf.requestRandomness(round); // msg.sender = this consumer
    }

    function fulfillRandomness(uint256 requestId, bytes32 randomness) external {
        require(!boom, "boom");
        lastRequestId = requestId;
        lastRandomness = randomness;
        calls++;
    }
}

contract VRFCoordinatorTest is Test {
    LaunchFairVRFCoordinator vrf;

    function setUp() public {
        vrf = new LaunchFairVRFCoordinator(address(this), address(this)); // owner + poster = this
    }

    function test_requestAndPost_pushesToConsumer() public {
        MockConsumer c = new MockConsumer();
        uint256 id = c.request(vrf, 100);
        assertEq(id, 1, "first request id");

        vrf.postRandomness(100, keccak256("r"));
        assertEq(vrf.randomnessOf(100), keccak256("r"), "stored for pull");
        assertEq(c.calls(), 1, "pushed once");
        assertEq(c.lastRequestId(), id, "request id delivered");
        assertEq(c.lastRandomness(), keccak256("r"), "randomness delivered");
    }

    function test_fansOutToEveryConsumerOnTheRound() public {
        MockConsumer a = new MockConsumer();
        MockConsumer b = new MockConsumer();
        a.request(vrf, 200);
        b.request(vrf, 200);
        vrf.postRandomness(200, keccak256("x"));
        assertEq(a.calls(), 1, "a fulfilled");
        assertEq(b.calls(), 1, "b fulfilled");
    }

    function test_onlyPosterCanPost() public {
        MockConsumer c = new MockConsumer();
        c.request(vrf, 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(LaunchFairVRFCoordinator.OnlyPoster.selector);
        vrf.postRandomness(1, keccak256("r"));
    }

    function test_doublePostReverts() public {
        vrf.postRandomness(1, keccak256("r"));
        vm.expectRevert(LaunchFairVRFCoordinator.AlreadyPosted.selector);
        vrf.postRandomness(1, keccak256("r2"));
    }

    function test_zeroRandomnessReverts() public {
        vm.expectRevert(LaunchFairVRFCoordinator.BadRandomness.selector);
        vrf.postRandomness(1, bytes32(0));
    }

    // A consumer that requests AFTER the round was posted is fulfilled inline.
    function test_lateRequestFulfilledInline() public {
        vrf.postRandomness(300, keccak256("y")); // posted with no consumers yet
        MockConsumer c = new MockConsumer();
        c.request(vrf, 300);
        assertEq(c.calls(), 1, "late request fulfilled on request");
        assertEq(c.lastRandomness(), keccak256("y"));
    }

    // A reverting consumer is isolated: the others still get pushed, and the value
    // remains readable via randomnessOf (the pull recovery path).
    function test_revertingConsumerIsolated() public {
        MockConsumer bad = new MockConsumer();
        MockConsumer good = new MockConsumer();
        bad.request(vrf, 400);
        good.request(vrf, 400);
        bad.setBoom(true);

        vrf.postRandomness(400, keccak256("z"));
        assertEq(good.calls(), 1, "good consumer still fulfilled");
        assertEq(bad.calls(), 0, "bad consumer reverted, caught");
        assertEq(vrf.randomnessOf(400), keccak256("z"), "value stored for the bad one to pull");
    }

    function test_setPoster() public {
        vrf.setPoster(address(0xCAFE));
        assertEq(vrf.poster(), address(0xCAFE), "poster rotated");
        vm.expectRevert(LaunchFairVRFCoordinator.OnlyPoster.selector);
        vrf.postRandomness(1, keccak256("r")); // old poster (this) can't post anymore
    }
}
