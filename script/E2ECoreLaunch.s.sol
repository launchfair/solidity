// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoreTGE} from "../src/v2/v4/CoreTGE.sol";
import {StockFeeHook} from "../src/v2/v4/StockFeeHook.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";
import {IV3SwapRouter} from "../src/interfaces/IUniswapV3.sol";

/// E2E core launch: distribute the stock-hook fees into the war chest, add a small manual
/// seed, run the one-shot factory launch with full metadata (image/website/X), then have
/// mimic wallet #0 buy the core off the locked V3 pool like a regular user.
/// Env: PRIVATE_KEY/TESTER_DEPLOYER_PKEY, TGE, HOOK, V3_ROUTER, STOCKS (comma list).
contract E2ECoreLaunch is Script {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    uint256 constant ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        CoreTGE tge = CoreTGE(payable(vm.envAddress("TGE")));
        StockFeeHook hook = StockFeeHook(payable(vm.envAddress("HOOK")));
        IV3SwapRouter v3r = IV3SwapRouter(vm.envAddress("V3_ROUTER"));
        address stockA = vm.envAddress("STOCK_A");
        address stockB = vm.envAddress("STOCK_B");

        vm.startBroadcast(pk);

        // 1. Real fee revenue → the war chest (50% of each conversion hits the flagship sink).
        if (hook.accrued(stockA) > 0) hook.distribute(stockA, 0);
        if (hook.accrued(stockB) > 0) hook.distribute(stockB, 0);

        // 2. Manual seed on top (the "seed it ourselves" path).
        tge.seed{value: 0.002 ether}();
        uint256 pot = address(tge).balance;

        // 3. One-shot launch through the platform factory, with real display metadata.
        LaunchTokenV2.Metadata memory meta = LaunchTokenV2.Metadata({
            logoURI: "https://api.dicebear.com/9.x/shapes/png?size=256&seed=FCORE",
            website: "https://hood.launchfair.app/",
            telegram: "",
            discord: "",
            twitter: "@launchfair"
        });
        address core = tge.launch("Fair Core", "FCORE", 1_000_000_000 ether, meta);
        vm.stopBroadcast();

        // 4. Sanity buy off the locked V3 pool (1% tier), ETH in — tester-funded dust clip.
        vm.startBroadcast(pk);
        uint256 got = v3r.exactInputSingle{value: 0.00005 ether}(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: core,
                fee: 10_000,
                recipient: vm.addr(pk),
                amountIn: 0.00005 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopBroadcast();

        console2.log("war chest at launch (wei):", pot);
        console2.log("FCORE core token:         ", core);
        console2.log("  lpTokenId (locked):     ", tge.lpTokenId());
        console2.log("  teamRemaining:          ", tge.teamRemaining());
        console2.log("  mimic0 bought core:     ", got);
    }
}
