// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";
import {StockPairRouter} from "../src/v2/v4/StockPairRouter.sol";

/// End-to-end smoke test of a stock-paired token on a live chain: launch (paired with an allow-listed
/// stock), buy with native ETH, sell half back for ETH, and distribute the router's WETH fees.
/// Env: PRIVATE_KEY, LAUNCHPAD, ROUTER, QUOTE (the stock), BUY_WEI (default 0.001 ETH).
contract SmokeStockPair is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        LaunchFairV4 pad = LaunchFairV4(vm.envAddress("LAUNCHPAD"));
        StockPairRouter router = StockPairRouter(payable(vm.envAddress("ROUTER")));
        address quote = vm.envAddress("QUOTE");
        uint256 buyWei = vm.envOr("BUY_WEI", uint256(0.001 ether));

        LaunchTokenV2.Metadata memory meta;
        meta.logoURI = "ipfs://smoke";
        LaunchFairV4.CreateParams memory p;
        p.name = "Smoke Stock";
        p.symbol = "SMKSTK";
        p.metadata = meta;
        p.salt = keccak256(abi.encodePacked("smoke", block.timestamp));
        p.mode = LaunchTokenV2.Mode.Base;
        p.fee = 30_000;
        p.rewards = new LaunchFairV4.RewardVenue[](0);
        p.perps = new LaunchFairV4.PerpLeg[](0);

        vm.startBroadcast(pk);

        address token = pad.createStockToken{value: 0.000005 ether}(p, quote);
        console2.log("1) launched token:  ", token);

        uint256 out = router.buy{value: buyWei}(token, 0, me, block.timestamp + 300);
        console2.log("2) bought (tokens): ", out);

        uint256 sellAmt = out / 2;
        IERC20(token).approve(address(router), sellAmt);
        uint256 ethOut = router.sell(token, sellAmt, 0, me, block.timestamp + 300);
        console2.log("3) sold half (wei): ", ethOut);

        uint256 dist = router.distribute(token);
        console2.log("4) distributed fee: ", dist);

        vm.stopBroadcast();

        console2.log("token bal (held):   ", IERC20(token).balanceOf(me));
        console2.log("accrued after dist: ", router.accrued(token));
    }
}
