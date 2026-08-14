// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

interface IV4SwapRouterE2E {
    function buy(PoolKey calldata key, uint256 minOut, address to, uint256 deadline) external payable returns (uint256);
}

interface IWethHookE2E {
    function accrued(address token) external view returns (uint256);
    function feeBpsFor(address token) external view returns (uint16);
    function distribute(address token) external returns (uint256);
    function owed(address to) external view returns (uint256);
}

/// Proves the audited per-tier WETH fee: a Base token launched at the 10% tier is charged 10% of
/// the WETH leg (not the old flat 1%), and distribute() runs the FeeSplitConfig split. Env:
/// LAUNCHPAD, WETH_HOOK, V4_SWAP_ROUTER, WETH [required]; PRIVATE_KEY/TESTER_DEPLOYER_PKEY.
contract E2EPerTierFee is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        address me = vm.addr(pk);
        LaunchFairV4 pad = LaunchFairV4(payable(vm.envAddress("LAUNCHPAD")));
        IWethHookE2E hook = IWethHookE2E(vm.envAddress("WETH_HOOK"));
        IV4SwapRouterE2E router = IV4SwapRouterE2E(vm.envAddress("V4_SWAP_ROUTER"));

        LaunchFairV4.CreateParams memory p;
        p.name = "Tier Ten";
        p.symbol = "TIER10";
        p.metadata.website = "https://hood.launchfair.app/";
        p.salt = keccak256(abi.encodePacked("tier10", block.number));
        p.mode = LaunchTokenV2.Mode.Base;
        p.fee = 100_000; // the 10% tier

        vm.startBroadcast(pk);
        address token = pad.createToken{value: pad.creationFeeWei()}(p);
        // Buy through the WETH pool with 0.001 ETH so the hook charges its fee on the WETH leg.
        PoolKey memory key = pad.getLaunch(token).key;
        router.buy{value: 0.001 ether}(key, 0, me, block.timestamp + 600);
        vm.stopBroadcast();

        uint16 bps = hook.feeBpsFor(token);
        uint256 acc = hook.accrued(token);
        console2.log("token:            ", token);
        console2.log("feeBpsFor(token): ", bps, "(1000 = the 10% tier; 100 would be the old flat 1%)");
        console2.log("accrued WETH fee: ", acc);

        require(bps == 1000, "per-tier rate NOT applied: hook is charging the flat global fee");
        // ~10% of the 0.001 ETH buy leg (minus pool mechanics) — must be far above a 1% charge.
        require(acc > 0.00005 ether, "accrued fee too low to be the 10% tier");

        vm.startBroadcast(pk);
        uint256 out = hook.distribute(token);
        vm.stopBroadcast();
        console2.log("distribute() out: ", out);
        require(out > 0, "distribute paid nothing");
        require(hook.accrued(token) == 0, "accrual not cleared after distribute");

        console2.log("");
        console2.log("OK: 10% tier charged in-pool (feeBps 1000) and distributed via FeeSplitConfig.");
    }
}
