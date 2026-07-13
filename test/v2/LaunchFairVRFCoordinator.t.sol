// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LaunchFairVRFCoordinator} from "../../src/v2/v4/LaunchFairVRFCoordinator.sol";

/// @notice Coordinator behavior driven by a REAL drand quicknet beacon, since
/// `postRandomness` verifies the BLS signature on-chain (EIP-2537). The local test EVM
/// has no BLS12-381 precompiles, so these skip there; they run — and verification is
/// exercised for real — on a chain that has EIP-2537 (Robinhood Chain does; see
/// DrandBLS.t.sol and the live-RPC validation in LAUNCHFAIR.md §7).
///
/// The coordinator is **pull-based** (audit H-01): posting is O(1) and stores no
/// per-round request list, so it can't be gas-griefed; consumers read `randomnessOf`.
contract VRFCoordinatorTest is Test {
    LaunchFairVRFCoordinator vrf;

    // Real quicknet beacon, round 30364827. Signature as an EIP-2537 uncompressed G1
    // point (128 bytes). The coordinator stores keccak256(signature) as the randomness.
    uint256 constant ROUND = 30_364_827;
    bytes constant SIG =
        hex"000000000000000000000000000000000f25e09fd32971105ebf2f62b39acaf45f50b21851571dc64116500bfa2fe1e3fd206f6a951a2ab54aa3386cde3ad99b"
        hex"000000000000000000000000000000000f8643dd4077b49b43bb7f6de0b1bd0f957e9284f4ddffe91581f6ccce09f2557ea810264158b56938c3069bc7a36f6d";

    function setUp() public {
        vrf = new LaunchFairVRFCoordinator();
    }

    function _blsAvailable() internal view returns (bool) {
        (bool ok, bytes memory out) = address(0x0f).staticcall(new bytes(384));
        return ok && out.length == 32;
    }

    modifier requiresBls() {
        if (!_blsAvailable()) {
            vm.skip(true);
            return;
        }
        _;
    }

    // requestRandomness is O(1): returns an incrementing id and emits, stores no list.
    function test_requestRandomnessReturnsIds() public {
        assertEq(vrf.requestRandomness(ROUND), 1, "first id");
        assertEq(vrf.requestRandomness(ROUND), 2, "second id");
        assertEq(vrf.nextRequestId(), 3, "counter advanced");
    }

    function test_postStoresVerifiedRandomness() public requiresBls {
        vrf.postRandomness(ROUND, SIG);
        assertEq(vrf.randomnessOf(ROUND), keccak256(SIG), "stored = keccak256(sig)");
    }

    // Verification replaces poster trust: ANYONE can bring the real beacon on-chain.
    function test_postIsPermissionless() public requiresBls {
        vm.prank(address(0xBEEF)); // no privileged role exists
        vrf.postRandomness(ROUND, SIG);
        assertEq(vrf.randomnessOf(ROUND), keccak256(SIG));
    }

    // A well-formed signature that isn't the real beacon for `round` is rejected.
    function test_wrongSignatureReverts() public requiresBls {
        // The real sig for ROUND, posted for the WRONG round: valid G1 point, wrong beacon.
        vm.expectRevert(LaunchFairVRFCoordinator.BadRandomness.selector);
        vrf.postRandomness(ROUND + 1, SIG);
    }

    function test_doublePostReverts() public requiresBls {
        vrf.postRandomness(ROUND, SIG);
        vm.expectRevert(LaunchFairVRFCoordinator.AlreadyPosted.selector);
        vrf.postRandomness(ROUND, SIG);
    }
}
