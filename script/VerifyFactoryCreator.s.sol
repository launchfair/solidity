// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TokenDeployerV2} from "../src/v2/TokenDeployerV2.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

/// Deploys one throwaway token THROUGH the permanent factory and proves on-chain that:
///   1. the token's CREATE2 creator is the FACTORY address, not the TokenDeployerV2
///      implementation that currently holds the bytecode, and
///   2. `msg.sender` survived the delegatecall, so the caller (in production, the launchpad)
///      is still the token's privileged controller and supply holder.
///
/// Property 1 is exactly what we are asking Codex to key on, so it is worth asserting against a
/// real chain and not only in a unit test.
///
/// Env: FACTORY, IMPLEMENTATION [required]; PRIVATE_KEY / TESTER_DEPLOYER_PKEY.
contract VerifyFactoryCreator is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        address caller = vm.addr(pk);
        address factory = vm.envAddress("FACTORY");
        address impl = vm.envAddress("IMPLEMENTATION");

        LaunchTokenV2.Metadata memory meta;
        meta.website = "https://hood.launchfair.app/";
        TokenDeployerV2.Params memory p = TokenDeployerV2.Params({
            name: "Creator Proof",
            symbol: "CPRF",
            supply: 1_000_000_000 ether,
            platformWebsite: "https://hood.launchfair.app/",
            metadata: meta,
            maxBuyBps: 100,
            maxBuySecs: 60,
            mode: LaunchTokenV2.Mode.Base,
            rewardTokens: new address[](0),
            rewardWeights: new uint16[](0),
            prizeToken: address(0),
            minHoldForRewards: 0
        });
        bytes32 salt = keccak256(abi.encodePacked("creator-proof", block.number));

        vm.startBroadcast(pk);
        address token = TokenDeployerV2(factory).deploy(p, salt);
        vm.stopBroadcast();

        address fromFactory = _predict(factory, salt, p, caller);
        address fromImpl = _predict(impl, salt, p, caller);

        console2.log("token deployed:              ", token);
        console2.log("CREATE2 from FACTORY:        ", fromFactory);
        console2.log("CREATE2 from implementation: ", fromImpl);
        console2.log("token.launchpad() (= caller):", LaunchTokenV2(payable(token)).launchpad());
        console2.log("token.platformWebsite():     ", LaunchTokenV2(payable(token)).platformWebsite());

        require(token == fromFactory, "creator is NOT the permanent factory");
        require(token != fromImpl, "creator collapsed onto the implementation");
        require(LaunchTokenV2(payable(token)).launchpad() == caller, "msg.sender did not survive delegatecall");
        console2.log("");
        console2.log("OK: on-chain creator is the permanent factory; caller role preserved.");
    }

    function _predict(address deployer, bytes32 salt, TokenDeployerV2.Params memory p, address launchpad_)
        internal
        pure
        returns (address)
    {
        bytes memory initcode = abi.encodePacked(
            type(LaunchTokenV2).creationCode,
            abi.encode(
                p.name,
                p.symbol,
                p.supply,
                p.platformWebsite,
                p.metadata,
                p.maxBuyBps,
                p.maxBuySecs,
                p.mode,
                p.rewardTokens,
                p.rewardWeights,
                p.prizeToken,
                p.minHoldForRewards,
                launchpad_
            )
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initcode)))))
        );
    }
}
