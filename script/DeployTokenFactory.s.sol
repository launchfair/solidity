// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {LaunchFairTokenFactory} from "../src/v2/LaunchFairTokenFactory.sol";
import {TokenDeployerV2} from "../src/v2/TokenDeployerV2.sol";

/// Deploys the PERMANENT token factory — the one address we hand to Codex and every other
/// indexer as "LaunchFair created this token".
///
/// Deploy this ONCE, then pass it as `TOKEN_DEPLOYER` to DeployV4 forever. The launchpad's
/// `deployer` is immutable, so each launchpad redeploy must be pointed at this same address; that
/// is the whole point, and it is why the address is worth mining a nice prefix for.
///
/// Order matters: the implementation must exist before the factory, because the implementation
/// address is a constructor argument and therefore part of the mined CREATE2 address.
///
/// Env:
///   PRIVATE_KEY / TESTER_DEPLOYER_PKEY   deployer key (becomes the factory owner)
///   TREASURY        the co-signer that may also repoint the implementation   [default: platform treasury]
///   OWNER           factory owner                                            [default: the deployer]
///   IMPLEMENTATION  an existing TokenDeployerV2 to adopt                     [default: deploy a fresh one]
///   VANITY_PREFIX   hex nibbles the address must start with, no 0x           [default: "1af" = LAF]
///   VANITY_MAX      salts to try before giving up                            [default: 2_000_000]
///
/// Mining cost is ~16^n tries for an n-nibble prefix: 3 nibbles is instant, 4 is quick, 5 takes a
/// while, 6+ wants a native miner rather than the EVM.
contract DeployTokenFactory is Script {
    address constant DEFAULT_TREASURY = 0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3;
    /// Foundry's canonical deterministic CREATE2 deployer (present on this chain).
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) {
            require(!vm.envOr("PROD", false), "PROD deploy needs PRIVATE_KEY (the real deployer) - no tester fallback");
            pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        }
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        address treasury = vm.envOr("TREASURY", DEFAULT_TREASURY);
        string memory prefix = vm.envOr("VANITY_PREFIX", string("1af"));
        uint256 maxTries = vm.envOr("VANITY_MAX", uint256(2_000_000));

        vm.startBroadcast(pk);

        // Mine FIRST: the address is a pure function of (owner, treasury, salt), so it is
        // reproducible at the production deploy and on any other chain — deliberately independent
        // of wherever the implementation lands.
        bytes memory initcode =
            abi.encodePacked(type(LaunchFairTokenFactory).creationCode, abi.encode(owner, treasury));
        (bytes32 salt, address predicted, uint256 tries) = _mine(keccak256(initcode), bytes(prefix), maxTries);
        console2.log("mined salt after tries:", tries);
        console2.log("salt:", uint256(salt));
        console2.log("predicted factory address:", predicted);

        LaunchFairTokenFactory factory = new LaunchFairTokenFactory{salt: salt}(owner, treasury);
        require(address(factory) == predicted, "mined-address mismatch");

        address impl = vm.envOr("IMPLEMENTATION", address(0));
        if (impl == address(0)) impl = address(new TokenDeployerV2());
        factory.setImplementation(impl); // the broadcaster must be the owner or the treasury
        console2.log("TokenDeployerV2 (implementation):", impl);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== PERMANENT TOKEN FACTORY (give this to Codex) ===");
        console2.log("factory:  ", address(factory));
        console2.log("owner:    ", owner);
        console2.log("treasury: ", treasury);
        console2.log("");
        console2.log("Pass this to every future launchpad deploy:");
        console2.log("  TOKEN_DEPLOYER=", address(factory));
        console2.log("Once LaunchTokenV2 is final, call freezeImplementation() to drop the upgrade surface.");
    }

    /// @dev Brute-force a salt whose CREATE2 address starts with `prefix` (lowercase hex nibbles).
    function _mine(bytes32 initcodeHash, bytes memory prefix, uint256 maxTries)
        internal
        pure
        returns (bytes32 salt, address addr, uint256 tries)
    {
        for (uint256 i; i < maxTries; i++) {
            salt = bytes32(i);
            addr = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initcodeHash))))
            );
            if (_hasPrefix(addr, prefix)) return (salt, addr, i);
        }
        revert("no salt found: lower VANITY_PREFIX or raise VANITY_MAX");
    }

    function _hasPrefix(address a, bytes memory prefix) internal pure returns (bool) {
        uint256 v = uint256(uint160(a));
        for (uint256 i; i < prefix.length; i++) {
            // nibble i counting from the most significant of the 40 address nibbles
            uint256 nib = (v >> (4 * (39 - i))) & 0xf;
            if (_nibble(prefix[i]) != nib) return false;
        }
        return true;
    }

    function _nibble(bytes1 c) internal pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 48 && x <= 57) return x - 48; // 0-9
        if (x >= 97 && x <= 102) return x - 87; // a-f
        if (x >= 65 && x <= 70) return x - 55; // A-F
        revert("VANITY_PREFIX must be hex");
    }
}
