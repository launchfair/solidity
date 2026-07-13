// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — https://hood.launchfair.app

/// @notice On-chain verification of a **drand quicknet** beacon (BLS12-381) using the
/// EIP-2537 precompiles. This is what makes the LaunchFair lottery *trustless*: the VRF
/// coordinator only accepts a beacon whose BLS signature actually verifies against the
/// quicknet public key, so no keeper/poster can substitute a value of their choosing.
///
/// drand quicknet scheme = `bls-unchained-g1-rfc9380`:
///   - signatures live on **G1**, the group public key on **G2** (min-sig variant);
///   - **unchained**: the signed message is `SHA-256(round)` (round as 8-byte BE);
///   - hash-to-curve is RFC 9380 `..._SSWU_RO_` with DST `BLS_SIG_..._NUL_`.
///
/// Verification is the pairing identity `e(sig, g2) == e(H(m), pk)`, checked as the
/// product `e(sig, -g2) * e(H(m), pk) == 1` via the EIP-2537 pairing precompile.
///
/// All parameters (quicknet public key, -G2 generator, DST, field modulus) are baked in
/// as constants and were cross-checked against a real beacon (round 30364827) with an
/// independent BLS library; see test/v2/DrandBLS.t.sol and the deploy notes.
library DrandBLS {
    // ── EIP-2537 (+ base) precompiles ────────────────────────────────────────────
    address private constant MODEXP = address(0x05); // reduce a wide integer mod p
    address private constant BLS12_G1ADD = address(0x0b);
    address private constant BLS12_PAIRING = address(0x0f);
    address private constant BLS12_MAP_FP_TO_G1 = address(0x10);

    // BLS12-381 base field modulus p (48 bytes).
    bytes private constant P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";

    // RFC 9380 domain separation tag for the drand quicknet (G1, basic scheme).
    bytes private constant DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";

    // drand quicknet group public key (G2), EIP-2537 uncompressed: x.c0|x.c1|y.c0|y.c1,
    // each Fp element left-padded to 64 bytes. Chain hash
    // 52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971.
    bytes private constant PK_G2 =
        hex"000000000000000000000000000000000d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
        hex"0000000000000000000000000000000003cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451"
        hex"000000000000000000000000000000000e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273"
        hex"0000000000000000000000000000000001a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";

    // Negated G2 generator, EIP-2537 uncompressed (same layout). Constant of the curve.
    bytes private constant NEG_G2 =
        hex"00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8"
        hex"0000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e"
        hex"000000000000000000000000000000000d1b3cc2c7027888be51d9ef691d77bcb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa"
        hex"0000000000000000000000000000000013fa4d4a0ad8b1ce186ed5061789213d993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed";

    error PrecompileFailed();

    /// @notice Verify that `sigG1` (a drand quicknet beacon signature, EIP-2537
    /// uncompressed G1, 128 bytes) is the valid BLS signature for `round`.
    /// Returns false for a well-formed-but-wrong signature; reverts only if a
    /// precompile rejects malformed input.
    function verifyBeacon(uint256 round, bytes memory sigG1) internal view returns (bool) {
        if (sigG1.length != 128) return false;
        // drand rounds are uint64; reject anything larger so the storage key can't differ
        // from the value actually signed (audit L-01).
        if (round > type(uint64).max) return false;

        // message = SHA-256(round as 8-byte big-endian); H(m) = hash-to-G1(message).
        bytes32 message = sha256(abi.encodePacked(uint64(round)));
        bytes memory hm = hashToG1(message);

        // Pairing check: e(sig, -g2) * e(H(m), pk) == 1  <=>  e(sig, g2) == e(H(m), pk).
        bytes memory input = abi.encodePacked(sigG1, NEG_G2, hm, PK_G2); // 128+256+128+256
        (bool ok, bytes memory ret) = BLS12_PAIRING.staticcall(input);
        if (!ok || ret.length != 32) revert PrecompileFailed();
        return ret[31] == 0x01;
    }

    /// @notice RFC 9380 hash-to-curve to G1 of a 32-byte `message` with the drand DST.
    /// H(m) = map(u0) + map(u1), where u0,u1 are the two field elements from
    /// expand_message_xmd. EIP-2537's MAP_FP_TO_G1 clears the cofactor per point, and
    /// cofactor clearing is linear, so summing the mapped points equals the RFC result.
    function hashToG1(bytes32 message) internal view returns (bytes memory) {
        bytes memory ub = _expandMessageXmd(message); // 128 bytes = two 64-byte blocks
        bytes memory u0 = abi.encodePacked(bytes16(0), _modP(_block64(ub, 0))); // Fp, 64B
        bytes memory u1 = abi.encodePacked(bytes16(0), _modP(_block64(ub, 64)));
        return _g1Add(_mapToG1(u0), _mapToG1(u1));
    }

    // ── RFC 9380 §5.4.1 expand_message_xmd (SHA-256, len_in_bytes = 128, ell = 4) ──
    function _expandMessageXmd(bytes32 message) private view returns (bytes memory) {
        bytes memory dstPrime = abi.encodePacked(DST, uint8(DST.length)); // DST || len(DST)
        // msg_prime = Z_pad(64) || message || I2OSP(128,2) || I2OSP(0,1) || DST_prime
        bytes32 b0 = sha256(abi.encodePacked(new bytes(64), message, uint16(128), uint8(0), dstPrime));
        bytes32 b1 = sha256(abi.encodePacked(b0, uint8(1), dstPrime));
        bytes32 b2 = sha256(abi.encodePacked(b0 ^ b1, uint8(2), dstPrime));
        bytes32 b3 = sha256(abi.encodePacked(b0 ^ b2, uint8(3), dstPrime));
        bytes32 b4 = sha256(abi.encodePacked(b0 ^ b3, uint8(4), dstPrime));
        return abi.encodePacked(b1, b2, b3, b4); // uniform_bytes (128)
    }

    /// @dev Reduce a 64-byte big-endian value mod p via MODEXP (base^1 mod p). 48B out.
    function _modP(bytes memory wide64) private view returns (bytes memory) {
        bytes memory input =
            abi.encodePacked(uint256(64), uint256(1), uint256(48), wide64, uint8(1), P);
        (bool ok, bytes memory ret) = MODEXP.staticcall(input);
        if (!ok || ret.length != 48) revert PrecompileFailed();
        return ret;
    }

    /// @dev EIP-2537 MAP_FP_TO_G1: a 64-byte field element -> a 128-byte G1 point.
    function _mapToG1(bytes memory fe64) private view returns (bytes memory) {
        (bool ok, bytes memory ret) = BLS12_MAP_FP_TO_G1.staticcall(fe64);
        if (!ok || ret.length != 128) revert PrecompileFailed();
        return ret;
    }

    /// @dev EIP-2537 G1ADD of two 128-byte points -> a 128-byte point.
    function _g1Add(bytes memory a, bytes memory b) private view returns (bytes memory) {
        (bool ok, bytes memory ret) = BLS12_G1ADD.staticcall(abi.encodePacked(a, b));
        if (!ok || ret.length != 128) revert PrecompileFailed();
        return ret;
    }

    /// @dev Copy 64 bytes of `b` starting at `off`.
    function _block64(bytes memory b, uint256 off) private pure returns (bytes memory r) {
        r = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            r[i] = b[off + i];
        }
    }
}
