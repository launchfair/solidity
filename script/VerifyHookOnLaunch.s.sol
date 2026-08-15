// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// Launches a Base WETH token through the live launchpad and asserts its pool is bound to the
/// EXPECTED (immutable) fee hook — proving future launches carry the clean-scanning hook.
/// Env: PAD, EXPECT_HOOK [required]; PRIVATE_KEY/TESTER_DEPLOYER_PKEY.
contract VerifyHookOnLaunch is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        LaunchFairV4 pad = LaunchFairV4(payable(vm.envAddress("PAD")));
        address expectHook = vm.envAddress("EXPECT_HOOK");

        LaunchFairV4.CreateParams memory p;
        p.name = "Frozen Fee Token";
        p.symbol = "FROZE";
        p.salt = keccak256(abi.encode(block.number, "frozen-hook-v1"));
        p.mode = LaunchTokenV2.Mode.Base;
        p.fee = 30000; // 3% tier

        vm.startBroadcast(pk);
        address token = pad.createToken{value: pad.creationFeeWei()}(p);
        vm.stopBroadcast();

        LaunchFairV4.Launch memory L = pad.getLaunch(token);
        address boundHook = address(L.key.hooks);
        console2.log("launched token:", token);
        console2.log("pool hook:     ", boundHook);
        console2.log("expected hook: ", expectHook);
        require(boundHook == expectHook, "pool NOT bound to the immutable hook");

        // Sanity: the token itself still scans clean (no infinite allowance, no trustedSpender getter).
        require(LaunchTokenV2(token).allowance(address(0xBEEF), expectHook) == 0, "unexpected standing allowance");
        (bool ok,) = token.staticcall(abi.encodeWithSignature("trustedSpender(address)", expectHook));
        require(!ok, "trustedSpender getter still present");

        console2.log("");
        console2.log("VERIFIED: new launch is bound to the immutable fee hook; token scans clean.");
    }
}
