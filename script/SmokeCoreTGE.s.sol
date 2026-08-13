// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CoreTGE} from "../src/v2/v4/CoreTGE.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

/// E2E smoke of the seeded TGE against a THROWAWAY CoreTGE (deploy one with WIRE_SINKS=0
/// first — never against the real war chest): seed a dust pot, then run the one-shot launch
/// with full metadata, proving the factory deploy + locked pool + on-chain image/socials
/// getters the indexer and DEX terminals read.
/// Env: PRIVATE_KEY (or TESTER_DEPLOYER_PKEY via .env), TGE [required], SEED_WEI [default 1e14].
contract SmokeCoreTGE is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        CoreTGE tge = CoreTGE(payable(vm.envAddress("TGE")));
        uint256 seedWei = vm.envOr("SEED_WEI", uint256(0.0001 ether));

        LaunchTokenV2.Metadata memory meta = LaunchTokenV2.Metadata({
            logoURI: vm.envOr("LOGO", string("https://hood.launchfair.app/android-chrome-512x512.png")),
            website: vm.envOr("WEBSITE", string("https://hood.launchfair.app/")),
            telegram: "",
            discord: "",
            twitter: vm.envOr("TWITTER", string("@launchfair"))
        });

        vm.startBroadcast(pk);
        tge.seed{value: seedWei}();
        address token = tge.launch(
            vm.envOr("NAME", string("Test Core")),
            vm.envOr("SYMBOL", string("TCORE")),
            vm.envOr("SUPPLY", uint256(1_000_000_000 ether)),
            meta
        );
        vm.stopBroadcast();

        LaunchTokenV2 t = LaunchTokenV2(token);
        console2.log("test core token:", token);
        console2.log("  logoURI: ", t.logoURI());
        console2.log("  website: ", t.website());
        console2.log("  twitter: ", t.twitter());
        console2.log("  launchpad (the TGE):", t.launchpad());
        console2.log("  lpTokenId (locked):", tge.lpTokenId());
    }
}
