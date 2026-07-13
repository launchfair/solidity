// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DrandBLS} from "../../src/v2/v4/DrandBLS.sol";

/// @notice DrandBLS verified against a REAL drand quicknet beacon (round 30364827).
/// Requires the EIP-2537 precompiles, which the local test EVM lacks, so these skip
/// locally. They pass on a chain with EIP-2537; the same vector was also validated
/// end-to-end against the live Robinhood Chain RPC via eth_call state-override — every
/// value here (hashToG1, verify=true, wrong-round=false) matched an independent BLS
/// library (see LAUNCHFAIR.md §7).
contract DrandBLSTest is Test {
    uint256 constant ROUND = 30_364_827;

    // Beacon signature (EIP-2537 uncompressed G1, 128 bytes).
    bytes constant SIG =
        hex"000000000000000000000000000000000f25e09fd32971105ebf2f62b39acaf45f50b21851571dc64116500bfa2fe1e3fd206f6a951a2ab54aa3386cde3ad99b"
        hex"000000000000000000000000000000000f8643dd4077b49b43bb7f6de0b1bd0f957e9284f4ddffe91581f6ccce09f2557ea810264158b56938c3069bc7a36f6d";

    // Reference hash-to-G1 of sha256(round) with the quicknet DST (from noble-curves).
    bytes constant HASH_G1 =
        hex"00000000000000000000000000000000067955d45bc2d9779fa99faa004d8cbc199810bf395f387a9ce2458c7b07d4b07e3ab17cd1eb5a7dfc4d625a3fb5e482"
        hex"0000000000000000000000000000000019a17641311f0c3cf5d92331dacb00660e379655b78e9b1805ffae0a8dab1eced44187de8c540fac7f7e43fbba90d9da";

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

    function test_verifiesRealBeacon() public requiresBls {
        assertTrue(DrandBLS.verifyBeacon(ROUND, SIG), "real beacon must verify");
    }

    function test_rejectsWrongRound() public requiresBls {
        assertFalse(DrandBLS.verifyBeacon(ROUND + 1, SIG), "wrong round must fail");
    }

    function test_rejectsWrongLength() public requiresBls {
        assertFalse(DrandBLS.verifyBeacon(ROUND, hex"deadbeef"), "malformed length must fail");
    }

    function test_hashToG1MatchesReference() public requiresBls {
        bytes32 message = sha256(abi.encodePacked(uint64(ROUND)));
        assertEq(DrandBLS.hashToG1(message), HASH_G1, "hash-to-G1 matches the reference");
    }
}
