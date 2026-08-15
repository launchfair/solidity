// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TokenDeployerV2} from "../src/v2/TokenDeployerV2.sol";

interface IFactory {
    function setImplementation(address impl) external;
    function implementation() external view returns (address);
    function implementationFrozen() external view returns (bool);
    function owner() external view returns (address);
}

/// Hot-swap the permanent factory's token implementation to a fresh TokenDeployerV2 that bakes the
/// CURRENT LaunchTokenV2 bytecode (trustedSpender mapping + infinite-allowance override removed, so
/// launched tokens scan clean). This is the whole point of the permanent factory: the creator
/// address 0x1Af481... stays fixed, only FUTURE launches get the new token code. Tokens already out
/// there are untouched. No launchpad/distributor/hook redeploy needed.
///
/// Env: FACTORY [required]; PRIVATE_KEY/TESTER_DEPLOYER_PKEY (must be the factory owner or treasury).
contract SwapTokenImpl is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        IFactory factory = IFactory(vm.envAddress("FACTORY"));

        address oldImpl = factory.implementation();
        require(!factory.implementationFrozen(), "factory implementation is frozen");
        console2.log("factory:      ", address(factory));
        console2.log("old impl:     ", oldImpl);

        vm.startBroadcast(pk);
        TokenDeployerV2 newImpl = new TokenDeployerV2();
        factory.setImplementation(address(newImpl));
        vm.stopBroadcast();

        require(factory.implementation() == address(newImpl), "setImplementation did not take");
        console2.log("new impl:     ", address(newImpl));
        console2.log("OK factory now points at the clean-scanning token bytecode.");
    }
}
