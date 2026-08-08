// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {WethFeeHook} from "../src/v2/v4/WethFeeHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// Deploys the V4 WETH fee hook at a mined address (its low bits must encode its permissions),
/// then wires its fee-split destinations. After this, set the hook on the launchpad
/// (`LaunchFairV4.setFeeHook(hook)`) so NEW pools launch with it + a 0 LP fee.
///
/// Env:
///   PRIVATE_KEY   deployer key (becomes the hook owner)                         [required]
///   POOL_MANAGER  the Uniswap V4 PoolManager                                    [required]
///   WETH          the WETH ERC20                                                [required]
///   HOOK_FEE_BPS  fee in bps of the WETH leg (default 100 = 1%)                 [optional]
///   TREASURY      platform treasury (fallback for unset destinations)          [required]
///   DISTRIBUTOR   V4 reward/lottery distributor (mechanism → notify)           [optional]
///   FLAGSHIP_SINK flagship buyback sink                                         [optional]
///   LAUNCHPAD     LaunchFairV4 (resolves per-token dev via creatorOf)          [optional]
contract DeployWethFeeHook is Script {
    // Canonical deterministic-deployment proxy — forge routes `new{salt:}` CREATE2 through it.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address weth = vm.envAddress("WETH");
        uint16 feeBps = uint16(vm.envOr("HOOK_FEE_BPS", uint256(100)));

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(owner, pm, weth, feeBps);
        (address hookAddr, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(WethFeeHook).creationCode, args);

        vm.startBroadcast(pk);
        WethFeeHook hook = new WethFeeHook{salt: salt}(owner, pm, weth, feeBps);
        require(address(hook) == hookAddr, "mined-address mismatch");
        hook.setDestinations(
            vm.envAddress("TREASURY"),
            vm.envOr("DISTRIBUTOR", address(0)),
            vm.envOr("FLAGSHIP_SINK", address(0)),
            vm.envOr("LAUNCHPAD", address(0))
        );
        vm.stopBroadcast();

        console2.log("WethFeeHook:", address(hook));
        console2.log("  feeBps:   ", feeBps);
        console2.log("Next: LaunchFairV4.setFeeHook(", address(hook), ")");
        console2.log("Then: LaunchFairV4Distributor.setFeeHook(hook) to authorize mechanism notify");
    }
}
