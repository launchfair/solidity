// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {WethFeeHookImmutable} from "../src/v2/v4/WethFeeHookImmutable.sol";
import {HookMiner} from "./HookMiner.sol";

/// Deploys the IMMUTABLE V4 WETH fee hook (fee/split/destinations fixed at construction, no owner,
/// no setters — so a scanner sees no admin surface) at a mined address, then repoints the launchpad
/// (`setFeeHook`) so FUTURE tokens launch with it, and allow-lists it as a distributor fee source.
/// Existing pools keep their current hook. All config is read from env so it matches the live hook.
///
/// Env: PRIVATE_KEY/TESTER_DEPLOYER_PKEY (launchpad + distributor owner); POOL_MANAGER, WETH,
///   TREASURY, DISTRIBUTOR, LAUNCHPAD [required]; HOOK_FEE_BPS (default 100), FLAGSHIP_SINK (default 0).
contract DeployWethFeeHookImmutable is Script {
    // Canonical deterministic-deployment proxy — forge routes `new{salt:}` CREATE2 through it.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address weth = vm.envAddress("WETH");
        uint16 feeBps = uint16(vm.envOr("HOOK_FEE_BPS", uint256(100)));
        address treasury = vm.envAddress("TREASURY");
        address distributor = vm.envAddress("DISTRIBUTOR");
        address launchpad = vm.envAddress("LAUNCHPAD");
        address flagshipSink = vm.envOr("FLAGSHIP_SINK", address(0)); // 0 folds flagship to treasury

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(pm, weth, feeBps, treasury, distributor, flagshipSink, launchpad);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WethFeeHookImmutable).creationCode, args);

        vm.startBroadcast(pk);
        WethFeeHookImmutable hook =
            new WethFeeHookImmutable{salt: salt}(pm, weth, feeBps, treasury, distributor, flagshipSink, launchpad);
        require(address(hook) == hookAddr, "mined-address mismatch");

        // Repoint: FUTURE WETH tokens launch with this immutable hook. Existing pools keep their hook.
        ILaunchpadFeeHook(launchpad).setFeeHook(address(hook));
        // Additive: allow the hook's mechanism notify() without revoking any existing fee source.
        IDistributorFeeSource(distributor).setFeeSource(address(hook), true);
        vm.stopBroadcast();

        console2.log("WethFeeHookImmutable:", address(hook));
        console2.log("  feeBps:            ", feeBps);
        console2.log("  wired: launchpad.setFeeHook + distributor.setFeeSource(hook,true)");
        console2.log("  NO owner, NO setFeeBps/setDestinations/setSplit -> scans clean.");
    }
}

interface ILaunchpadFeeHook {
    function setFeeHook(address hook) external;
}

interface IDistributorFeeSource {
    function setFeeSource(address source, bool allowed) external;
}
