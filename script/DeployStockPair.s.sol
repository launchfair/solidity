// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {StockPairRouter, IWETH, ILaunchpadV4} from "../src/v2/v4/StockPairRouter.sol";
import {RouterGateHook} from "../src/v2/v4/RouterGateHook.sol";
import {IV3SwapRouter} from "../src/interfaces/IUniswapV3.sol";
import {HookMiner} from "./HookMiner.sol";

interface ILaunchpadAdmin {
    function setStockPairRouter(address r) external;
    function setStockGateHook(address hook) external;
    function setAllowedQuote(address stock, bool allowed, uint24 v3Fee) external;
}

/// Deploys the stock-paired stack for an existing LaunchFairV4: the StockPairRouter + a mined
/// RouterGateHook bound to it, wires them onto the launchpad, sets the router's fee destinations,
/// and allow-lists the liquid Robinhood stock quotes (chain-scanned 2026-08-12):
///  - DIRECT quotes trade through their own <stock>/WETH V3 pool (fee tier recorded on the pad);
///  - ROUTED quotes have no (or thin) WETH pool — their depth is in <stock>/USDG — so the router
///    gets a multi-hop route WETH →(0.01%)→ USDG →(fee)→ stock via `setQuoteRoute`.
/// Add more later with `LaunchFairV4.setAllowedQuote` (+ `router.setQuoteRoute` if USDG-quoted).
///
/// Env:
///   PRIVATE_KEY    deployer key (becomes the router owner)                    [required]
///   POOL_MANAGER   the Uniswap V4 PoolManager                                 [required]
///   WETH           the WETH ERC20                                             [required]
///   V3_ROUTER      Uniswap V3 SwapRouter02 (for the <stock>/WETH hop)         [required]
///   LAUNCHPAD      the LaunchFairV4 to extend                                 [required]
///   TREASURY       platform treasury (fee split + fallback)                   [required]
///   FLAGSHIP_SINK  flagship buyback sink                                      [optional]
///   STOCK_FEE_BPS  router fee in bps of the WETH leg (default 100 = 1%)       [optional]
contract DeployStockPair is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// USDG (Global Dollar, 6 dp) — the bridge for routed quotes. WETH/USDG 0.01% pool holds
    /// ~2.7k WETH / $4.2M, so the extra hop is effectively free.
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint24 constant USDG_BRIDGE_FEE = 100; // WETH/USDG leg

    // ── first-party Robinhood tokenized stocks (depths verified on-chain 2026-08-12) ──
    // DIRECT: deep <stock>/WETH pool (fee = that pool's tier).
    address constant COIN = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b; // 14.8 WETH @ 0.3%
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C; // 13.9 WETH @ 0.05%
    address constant MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09; // 12.4 WETH @ 1%
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35; // 2.8 WETH @ 0.3%
    // ROUTED via USDG: deepest liquidity is <stock>/USDG (fee = the USDG-leg tier).
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // $513k @ 0.05%
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa; // $525k @ 0.3%
    address constant USO = 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344; // $415k @ 0.3%
    address constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E; // $162k @ 1%
    address constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68; // $83k @ 0.3%
    address constant COST = 0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2; // $67k @ 0.3%
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d; // $52k @ 0.3%
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9; // $47k @ 0.3%
    address constant INTC = 0xc72b96e0E48ecd4DC75E1e45396e26300BC39681; // $46k @ 0.3%
    address constant MU = 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD; // $35k @ 0.3%
    address constant NFLX = 0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8; // $25k @ 1%
    address constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3; // $14k @ 0.3%
    address constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74; // $14k @ 0.3%
    address constant PLTR = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A; // $12k @ 0.3%
    address constant AMD = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC; // $9.3k @ 1%
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54; // $8.9k @ 0.3%

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address weth = vm.envAddress("WETH");
        address v3Router = vm.envAddress("V3_ROUTER");
        address launchpad = vm.envAddress("LAUNCHPAD");
        address treasury = vm.envAddress("TREASURY");
        address flagshipSink = vm.envOr("FLAGSHIP_SINK", address(0));
        uint16 feeBps = uint16(vm.envOr("STOCK_FEE_BPS", uint256(100)));

        vm.startBroadcast(pk);

        StockPairRouter router = new StockPairRouter(
            owner, pm, IWETH(weth), IV3SwapRouter(v3Router), ILaunchpadV4(launchpad), feeBps
        );
        router.setDestinations(treasury, flagshipSink);

        // The gate hook's address must encode BEFORE_SWAP only; CREATE2-mine a matching salt.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(pm, address(router));
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(RouterGateHook).creationCode, args);
        RouterGateHook gate = new RouterGateHook{salt: salt}(pm, address(router));
        require(address(gate) == hookAddr, "mined-address mismatch");

        ILaunchpadAdmin pad = ILaunchpadAdmin(launchpad);
        pad.setStockPairRouter(address(router));
        pad.setStockGateHook(address(gate));

        // DIRECT quotes: the stock's own <stock>/WETH pool carries the trade.
        pad.setAllowedQuote(COIN, true, 3000);
        pad.setAllowedQuote(SPY, true, 500);
        pad.setAllowedQuote(MSTR, true, 10000);
        pad.setAllowedQuote(META, true, 3000);

        // ROUTED quotes: multi-hop WETH → USDG → stock (deepest liquidity is USDG-side).
        _routed(pad, router, weth, NVDA, 500);
        _routed(pad, router, weth, SPCX, 3000);
        _routed(pad, router, weth, USO, 3000);
        _routed(pad, router, weth, GME, 10000);
        _routed(pad, router, weth, QQQ, 3000);
        _routed(pad, router, weth, COST, 3000);
        _routed(pad, router, weth, TSLA, 3000);
        _routed(pad, router, weth, AAPL, 3000);
        _routed(pad, router, weth, INTC, 3000);
        _routed(pad, router, weth, MU, 3000);
        _routed(pad, router, weth, NFLX, 10000);
        _routed(pad, router, weth, GOOGL, 3000);
        _routed(pad, router, weth, MSFT, 3000);
        _routed(pad, router, weth, PLTR, 3000);
        _routed(pad, router, weth, AMD, 10000);
        _routed(pad, router, weth, AMZN, 3000);

        vm.stopBroadcast();

        console2.log("StockPairRouter:", address(router));
        console2.log("RouterGateHook: ", address(gate));
        console2.log("  feeBps:       ", feeBps);
        console2.log("Quotes: 4 direct (COIN/SPY/MSTR/META) + 16 routed via USDG (NVDA/SPCX/USO/GME/");
        console2.log("        QQQ/COST/TSLA/AAPL/INTC/MU/NFLX/GOOGL/MSFT/PLTR/AMD/AMZN)");
    }

    /// Allow the quote and install its WETH<->USDG<->stock route on the router. The recorded
    /// `v3Fee` is the USDG-leg tier (documentation + loud-failure fallback if the route is
    /// ever cleared without a WETH pool existing).
    function _routed(ILaunchpadAdmin pad, StockPairRouter router, address weth, address stock, uint24 usdgFee)
        internal
    {
        pad.setAllowedQuote(stock, true, usdgFee);
        router.setQuoteRoute(
            stock,
            abi.encodePacked(weth, USDG_BRIDGE_FEE, USDG, usdgFee, stock),
            abi.encodePacked(stock, usdgFee, USDG, USDG_BRIDGE_FEE, weth)
        );
    }
}
