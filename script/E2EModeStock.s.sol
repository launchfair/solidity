// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";
import {StockPairRouter} from "../src/v2/v4/StockPairRouter.sol";
import {StockFeeHook} from "../src/v2/v4/StockFeeHook.sol";

interface IDistPending {
    function pendingWeth(address token) external view returns (uint256);
}

/// E2E for the mode-on-stock-pairs stack (#6): launches the new combinations live, buys through
/// the open router, distributes the hook fees, and proves the Reward mechanism got funded.
///   1. "Nebula Reward" NBRW — Reward(NVDA) token PAIRED WITH RDDT   (mode + stock, the new thing)
///   2. "Dollar Dog"    DDOG — Base token PAIRED WITH USDG            (6-dp down-shifted launch)
///   3. "Lucky Stock"   LSTK — Lottery token PAIRED WITH NVDA         (mode + stock)
/// Env: LAUNCHPAD, STOCK_ROUTER, STOCK_FEE_HOOK [required]; PRIVATE_KEY/TESTER_DEPLOYER_PKEY.
contract E2EModeStock is Script {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant RDDT = 0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function _params(string memory name, string memory symbol, LaunchTokenV2.Mode mode)
        internal
        view
        returns (LaunchFairV4.CreateParams memory p)
    {
        p.name = name;
        p.symbol = symbol;
        p.metadata.logoURI = string.concat("https://api.dicebear.com/9.x/shapes/png?size=256&seed=", symbol);
        p.metadata.website = "https://hood.launchfair.app/";
        p.metadata.twitter = "@launchfair";
        p.salt = keccak256(abi.encodePacked("e2e-modestock", symbol, block.timestamp));
        p.mode = mode;
        p.fee = 100_000; // recorded but unused on stock pairs (fee 0 in-pool + hook)
        p.rewards = new LaunchFairV4.RewardVenue[](0);
        p.perps = new LaunchFairV4.PerpLeg[](0);
    }

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        LaunchFairV4 pad = LaunchFairV4(payable(vm.envAddress("LAUNCHPAD")));
        StockPairRouter router = StockPairRouter(payable(vm.envAddress("STOCK_ROUTER")));
        StockFeeHook hook = StockFeeHook(payable(vm.envAddress("STOCK_FEE_HOOK")));
        uint256 feeWei = pad.creationFeeWei();

        vm.startBroadcast(pk);

        // 1. Reward-mode, RDDT-paired: rewards holders in NVDA, trades against Reddit stock.
        LaunchFairV4.CreateParams memory rp = _params("Nebula Reward", "NBRW", LaunchTokenV2.Mode.Reward);
        rp.rewards = new LaunchFairV4.RewardVenue[](1);
        rp.rewards[0] = LaunchFairV4.RewardVenue({
            token: NVDA,
            weightBps: 10_000,
            isV3: true,
            v3Fee: 500,
            v4Key: rp.prizePoolKey // zeroed
        });
        address nbrw = pad.createStockToken{value: feeWei}(rp, RDDT);

        // 2. Base, USDG-paired — the 6-decimals down-shift live.
        address ddog = pad.createStockToken{value: feeWei}(_params("Dollar Dog", "DDOG", LaunchTokenV2.Mode.Base), USDG);

        // 3. Lottery, NVDA-paired (WETH pot).
        address lstk =
            pad.createStockToken{value: feeWei}(_params("Lucky Stock", "LSTK", LaunchTokenV2.Mode.Lottery), NVDA);

        // Buys through the open router (ETH in -> quote -> token), which also accrues hook fees.
        router.buy{value: 0.0004 ether}(nbrw, 0, vm.addr(pk), block.timestamp + 600);
        router.buy{value: 0.0003 ether}(ddog, 0, vm.addr(pk), block.timestamp + 600);
        router.buy{value: 0.0002 ether}(lstk, 0, vm.addr(pk), block.timestamp + 600);

        // Distribute the reward token's accrued stock fees: 25/25/10 in ETH + the 40% mechanism
        // slice in WETH to the DISTRIBUTOR (the new path this stack exists for).
        uint256 out = hook.distribute(nbrw, 0);

        vm.stopBroadcast();

        console2.log("NBRW (Reward/NVDA, RDDT-paired):", nbrw);
        console2.log("DDOG (Base, USDG-paired):       ", ddog);
        console2.log("LSTK (Lottery, NVDA-paired):    ", lstk);
        console2.log("hook distribute wethOut:        ", out);
        console2.log("distributor pendingWeth(NBRW):  ", IDistPending(pad.distributor()).pendingWeth(nbrw));
        console2.log("NBRW mode:", uint8(LaunchTokenV2(nbrw).mode()));
        console2.log("tester NBRW:", LaunchTokenV2(nbrw).balanceOf(vm.addr(pk)));
        console2.log("tester DDOG:", LaunchTokenV2(ddog).balanceOf(vm.addr(pk)));
    }
}
