// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

/// Launches a Base token through the ALREADY-DEPLOYED launchpad (which now deploys via the factory's
/// freshly-swapped implementation) and proves the token scans CLEAN:
///   1. no router carries an infinite standing allowance (the old trustedSpender behaviour);
///   2. the `trustedSpender(address)` getter is GONE (the mapping a scanner flagged no longer exists);
///   3. the launch itself did NOT revert, i.e. the no-op setTrustedSpender shim kept the old
///      launchpad's launch path working under the new token bytecode.
/// Env: PAD, ROUTER [required]; PRIVATE_KEY/TESTER_DEPLOYER_PKEY.
contract VerifyCleanToken is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        LaunchFairV4 pad = LaunchFairV4(payable(vm.envAddress("PAD")));
        address router = vm.envAddress("ROUTER");

        LaunchFairV4.CreateParams memory p;
        p.name = "Clean Scan Token";
        p.symbol = "CLEAN";
        p.salt = keccak256(abi.encode(block.number, "clean-scan-v1"));
        p.mode = LaunchTokenV2.Mode.Base;
        p.fee = 30000; // 3% tier
        // arrays default empty; all other fields default 0 — fine for Base.

        vm.startBroadcast(pk);
        address token = pad.createToken{value: pad.creationFeeWei()}(p);
        vm.stopBroadcast();

        console2.log("launched token:", token);

        // 1. No infinite allowance for the platform routers (or anyone).
        uint256 aRouter = LaunchTokenV2(token).allowance(address(0xBEEF), router);
        require(aRouter == 0, "router still carries a standing allowance");
        console2.log("OK allowance(random, router) == 0 (no infinite approval)");

        // 2. The trustedSpender(address) getter must be GONE. A staticcall to its selector must fail
        //    (the function no longer exists), which is exactly what removes the scanner flag.
        (bool ok,) = token.staticcall(abi.encodeWithSignature("trustedSpender(address)", router));
        require(!ok, "trustedSpender(address) getter still present");
        console2.log("OK trustedSpender(address) getter removed");

        console2.log("");
        console2.log("CLEAN-SCAN VERIFIED: token launched via live launchpad + swapped factory impl.");
    }
}
