// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SeasonMerkleDistributor} from "../src/flywheel/SeasonMerkleDistributor.sol";

/// Deploys the SeasonMerkleDistributor for the flagship flywheel.
///
/// Run this AFTER the flagship token is launched — `flagship` is an immutable
/// constructor arg. The `rootPublisher` should be the flagship keeper wallet (the
/// same wallet set as the V1 FeeLocker `flagshipSink`): it funds each season and
/// publishes roots. The owner (deployer) keeps the admin-recovery powers.
///
/// Env:
///   PRIVATE_KEY    — deployer key (becomes the owner)                    [required]
///   FLAGSHIP       — the flagship ERC20 address                          [required]
///   ROOT_PUBLISHER — keeper wallet that publishes roots (= flagshipSink) [required]
///   TREASURY       — safe rescue destination (default 0x82C8…)           [optional]
contract DeploySeasonDistributor is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) {
            require(!vm.envOr("PROD", false), "PROD deploy needs PRIVATE_KEY (the real deployer) - no tester fallback");
            pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        }
        address deployer = vm.addr(pk);
        address flagship = vm.envAddress("FLAGSHIP");
        address rootPublisher = vm.envAddress("ROOT_PUBLISHER");
        address treasury = vm.envOr("TREASURY", address(0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3));

        vm.startBroadcast(pk);
        SeasonMerkleDistributor dist =
            new SeasonMerkleDistributor(deployer, IERC20(flagship), treasury, rootPublisher);
        vm.stopBroadcast();

        console2.log("SeasonMerkleDistributor:", address(dist));
        console2.log("  owner (deployer):     ", deployer);
        console2.log("  flagship:             ", flagship);
        console2.log("  treasury:             ", treasury);
        console2.log("  rootPublisher/keeper: ", rootPublisher);
    }
}
