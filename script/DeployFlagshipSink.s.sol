// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FlagshipSink} from "../src/flywheel/FlagshipSink.sol";

/// Deploys the FlagshipSink forwarder that the immutable fee hooks point their flagshipSink at.
/// It hoards the flagship fee ETH until an owner-set target (CoreTGE war-chest, then the buyback
/// vault) is swept in. Deploy FIRST, then pass its address as FLAGSHIP_SINK to the hook deploys.
/// Env: PRIVATE_KEY [+ PROD guard]; OWNER (default deployer); KEEPER (optional, authorized to sweep).
contract DeployFlagshipSink is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) {
            require(!vm.envOr("PROD", false), "PROD deploy needs PRIVATE_KEY (the real deployer) - no tester fallback");
            pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        }
        address owner = vm.envOr("OWNER", vm.addr(pk));
        address keeper = vm.envOr("KEEPER", address(0));

        vm.startBroadcast(pk);
        FlagshipSink sink = new FlagshipSink(owner);
        if (keeper != address(0)) sink.setKeeper(keeper, true);
        vm.stopBroadcast();

        console2.log("FlagshipSink:", address(sink));
        console2.log("  owner:  ", owner);
        console2.log("  keeper: ", keeper);
        console2.log("  target is UNSET (hoarding); setTarget(CoreTGE) then setTarget(vault) later.");
    }
}
