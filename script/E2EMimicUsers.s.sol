// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {StockPairRouter} from "../src/v2/v4/StockPairRouter.sol";

interface IV4SwapRouterE2E {
    function buy(PoolKey calldata key, uint256 minOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out);
    function sell(PoolKey calldata key, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        returns (uint256 out);
}

/// E2E mimic users: N deterministic throwaway wallets (derived from a fixed tag — dust
/// balances only, reproducible across runs) get funded from the tester wallet and then
/// genuinely USE the platform: buy/sell stock-paired tokens through the router and mode
/// tokens through the V4 swap router. Their trades hit the PoolManager/indexer like any
/// real user's, accruing volume → season points; odd-indexed wallets sell part back so
/// both trade directions and the fee paths get exercised.
/// Env: PRIVATE_KEY (funder), LAUNCHPAD, V4_ROUTER, STOCK_ROUTER,
///      TOKENS (comma list: mode tokens), STOCKS (comma list: stock-paired tokens).
contract E2EMimicUsers is Script {
    uint256 constant N = 6;
    // Tester-funded only (NEVER the deployer wallet) — keep the whole run cheap: each
    // wallet gets dust, trades 0.001-ETH clips, and gas on this L2 is near-zero.
    uint256 constant FUND = 0.0012 ether;
    uint256 constant ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _mimicKey(uint256 i) internal pure returns (uint256) {
        uint256 k = uint256(keccak256(abi.encodePacked("lf-e2e-mimic", i))) % ORDER;
        return k == 0 ? 1 : k;
    }

    function _split(string memory s) internal pure returns (address[] memory out) {
        bytes memory b = bytes(s);
        uint256 n = 1;
        for (uint256 i; i < b.length; i++) if (b[i] == ",") n++;
        out = new address[](n);
        uint256 start;
        uint256 idx;
        for (uint256 i; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory part = new bytes(i - start);
                for (uint256 j; j < part.length; j++) part[j] = b[start + j];
                out[idx++] = vm.parseAddress(string(part));
                start = i + 1;
            }
        }
    }

    function run() external {
        uint256 funderPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (funderPk == 0) funderPk = vm.envUint("TESTER_DEPLOYER_PKEY");
        LaunchFairV4 pad = LaunchFairV4(vm.envAddress("LAUNCHPAD"));
        IV4SwapRouterE2E v4r = IV4SwapRouterE2E(vm.envAddress("V4_ROUTER"));
        StockPairRouter sr = StockPairRouter(payable(vm.envAddress("STOCK_ROUTER")));
        address[] memory tokens = _split(vm.envString("TOKENS"));
        address[] memory stocks = _split(vm.envString("STOCKS"));

        // 1. Fund the mimic wallets (top up only when low, so re-runs don't drain the funder).
        vm.startBroadcast(funderPk);
        for (uint256 i; i < N; i++) {
            address a = vm.addr(_mimicKey(i));
            if (a.balance < FUND / 2) payable(a).transfer(FUND);
        }
        vm.stopBroadcast();

        // 2. Each wallet trades: one stock-paired + one mode token (round-robin), and the
        //    odd wallets sell a third back so sells/fees/candles get real two-way flow.
        for (uint256 i; i < N; i++) {
            uint256 pk = _mimicKey(i);
            address me = vm.addr(pk);
            address stockTok = stocks[i % stocks.length];
            address modeTok = tokens[i % tokens.length];
            PoolKey memory key = pad.getLaunch(modeTok).key;

            vm.startBroadcast(pk);
            uint256 sGot = sr.buy{value: 0.0004 ether}(stockTok, 0, me, block.timestamp + 3600);
            uint256 mGot = v4r.buy{value: 0.0004 ether}(key, 0, me, block.timestamp + 3600);
            if (i % 2 == 1) {
                IERC20(stockTok).approve(address(sr), sGot / 3);
                sr.sell(stockTok, sGot / 3, 0, me, block.timestamp + 3600);
                IERC20(modeTok).approve(address(v4r), mGot / 3);
                v4r.sell(key, mGot / 3, 0, me, block.timestamp + 3600);
            }
            vm.stopBroadcast();
            console2.log("mimic", i, me);
        }
    }
}
