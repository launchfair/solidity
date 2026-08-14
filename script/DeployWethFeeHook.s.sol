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
        // REQUIRED, not optional: an unset LAUNCHPAD sends every creator's dev share to treasury,
        // and an unset DISTRIBUTOR means no mode token can fund its mechanism. Both used to default
        // to address(0) and fail silently. TREASURY is the only fallback destination, by design.
        address treasury = vm.envAddress("TREASURY");
        address distributor = vm.envAddress("DISTRIBUTOR");
        address launchpad = vm.envAddress("LAUNCHPAD");
        address flagshipSink = vm.envOr("FLAGSHIP_SINK", address(0)); // 0 folds flagship to treasury pre-TGE

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(owner, pm, weth, feeBps);
        (address hookAddr, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(WethFeeHook).creationCode, args);

        vm.startBroadcast(pk);
        WethFeeHook hook = new WethFeeHook{salt: salt}(owner, pm, weth, feeBps);
        require(address(hook) == hookAddr, "mined-address mismatch");
        hook.setDestinations(treasury, distributor, flagshipSink, launchpad);

        // The two wirings that used to be printed as console hints and never executed — both fail
        // SILENTLY: without setFeeHook, Base-mode launches revert InvalidMode and mode tokens
        // launch under the old LP-fee model; without setFeeSource the hook's notify() reverts and
        // every Reward/Lottery mechanism folds quietly into the flagship. Mirrors DeployStockPair.
        ILaunchpadFeeHook(launchpad).setFeeHook(address(hook));
        IDistributorFeeSource(distributor).setFeeSource(address(hook), true);
        vm.stopBroadcast();

        console2.log("WethFeeHook:", address(hook));
        console2.log("  feeBps:   ", feeBps);
        console2.log("  wired: launchpad.setFeeHook + distributor.setFeeSource(hook,true)");
    }
}

interface ILaunchpadFeeHook {
    function setFeeHook(address hook) external;
}

interface IDistributorFeeSource {
    function setFeeSource(address source, bool allowed) external;
}
