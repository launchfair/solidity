// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StockPairRouter, IWETH, ILaunchpadV4} from "../src/v2/v4/StockPairRouter.sol";
import {StockFeeHookImmutable, ILaunchpadStockView, IStockRoutesView} from "../src/v2/v4/StockFeeHookImmutable.sol";
import {IV3SwapRouter, IUniswapV3Factory} from "../src/interfaces/IUniswapV3.sol";
import {HookMiner} from "./HookMiner.sol";

interface ILaunchpadAdmin {
    function setStockPairRouter(address r) external;
    function setStockGateHook(address hook) external;
    function setAllowedQuote(address stock, bool allowed, uint24 v3Fee) external;
    function setAllowedQuotePrice(address stock, uint256 quoteWeiPerToken) external;
    function distributor() external view returns (address);
}

interface IDistributorAdmin {
    function setFeeSource(address source, bool allowed) external;
}

interface IV3FactoryMin {
    function getPool(address, address, uint24) external view returns (address);
}

interface IV3PoolMin {
    function token0() external view returns (address);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// Deploys the stock-paired stack for an existing LaunchFairV4: the StockPairRouter + a mined
/// StockFeeHook bound to it, wires them onto the launchpad, sets both contracts' fee
/// destinations, and allow-lists the liquid Robinhood stock quotes (chain-scanned 2026-08-12).
///
/// FEE MODEL (since the open-pool change): the pool fee lives in the HOOK (charged on the stock
/// leg in-pool, so ANY router/terminal/aggregator can trade the pools and the fee can't be
/// bypassed); the router itself charges 0 and is just the ETH-in/ETH-out convenience path.
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
///   STOCK_FEE_BPS  router fee in bps of the WETH leg (default 0 — in-pool now) [optional]
///   HOOK_FEE_BPS   hook fee in bps of the stock leg (default 100 = 1%)        [optional]
contract DeployStockPair is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// USDG (Global Dollar, 6 dp) — the bridge for routed quotes. WETH/USDG 0.01% pool holds
    /// ~2.7k WETH / $4.2M, so the extra hop is effectively free.
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint24 constant USDG_BRIDGE_FEE = 100; // WETH/USDG leg
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    /// Target USD launch mcap for stock-paired tokens. The launchpad's global initial price is
    /// WETH-calibrated ("1.49 units of quote" ≈ $6k on WETH but ~$270 on NVDA), so each quote
    /// gets a live-priced `setAllowedQuotePrice` targeting this figure (owner-retunable later).
    uint256 constant TARGET_MCAP_USD = 2_500;
    uint256 constant SUPPLY_TOKENS = 1_000_000_000; // launchpad tokenTotalSupply in whole tokens

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
    // Batch 2 (chain-scanned 2026-08-14, USDG-side depth ≥ $2k) — all ROUTED via USDG.
    address constant SLV = 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f; // $145k @ 1%
    address constant RDDT = 0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C; // $61k @ 1%
    address constant TSM = 0x58FfE4a942d3885bAa22D7520691F611EF09e7AA; // $34k @ 1%
    address constant DELL = 0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd; // $29k @ 1%
    address constant SNDK = 0xB90A19fF0Af67f7779afF50A882A9CfF42446400; // $24k @ 1%
    address constant ASML = 0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA; // $15k @ 1%
    address constant QUBT = 0x59818904ab4cE163b3cE4FfB64f2D6Ca02c434B4; // $8.5k @ 1%
    address constant SGOV = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5; // $6.9k @ 0.3%
    address constant USAR = 0xd917B029C761D264c6A312BBbcDA868658eF86a6; // $6.2k @ 0.3%
    address constant RBLX = 0xF0C4BF4C582cb3836e98394b1d4e7B7281101bE8; // $3.5k @ 1%
    address constant NU = 0x408c14038a04f7bD235329E26d2bf569ee20e250; // $2.4k @ 1%

    /// Slippage the hook allows below its own chained-spot/TWAP quote when converting fees.
    uint16 constant CLAIM_SLIPPAGE_BPS = 300;

    function run() external {
        // Foundry auto-loads the repo .env: fall back to the tester key so no shell-level
        // secret plumbing is needed to run this script.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        address owner = vm.addr(pk);
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address weth = vm.envAddress("WETH");
        address v3Router = vm.envAddress("V3_ROUTER");
        // Needed for the hook's self-quoted claim floor (see setClaimConfig below).
        address v3Factory = vm.envOr("V3_FACTORY", address(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA));
        address launchpad = vm.envAddress("LAUNCHPAD");
        address treasury = vm.envAddress("TREASURY");
        address flagshipSink = vm.envOr("FLAGSHIP_SINK", address(0));
        uint16 feeBps = uint16(vm.envOr("STOCK_FEE_BPS", uint256(0))); // fee moved into the pool
        uint16 hookFeeBps = uint16(vm.envOr("HOOK_FEE_BPS", uint256(100)));

        vm.startBroadcast(pk);

        StockPairRouter router = new StockPairRouter(
            owner, pm, IWETH(weth), IV3SwapRouter(v3Router), ILaunchpadV4(launchpad), feeBps
        );
        router.setDestinations(treasury, flagshipSink);

        // The fee hook replaces the old RouterGateHook: pools are OPEN (any router can swap) and
        // the fee is charged in-pool on the stock leg. Its address must encode the four swap flags.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        ILaunchpadAdmin pad = ILaunchpadAdmin(launchpad);
        // All config is baked into the IMMUTABLE hook at construction (no owner, no setters): the
        // distributor (for mode tokens' mechanism), the claim floor's V3 factory + slippage, the
        // fee/split/destinations. flagshipSink = the buyback vault so stock tokens feed the flywheel.
        address dist = pad.distributor();
        bytes memory args = abi.encode(
            pm,
            weth,
            IV3SwapRouter(v3Router),
            ILaunchpadStockView(launchpad),
            IStockRoutesView(address(router)),
            hookFeeBps,
            treasury,
            dist,
            flagshipSink,
            IUniswapV3Factory(v3Factory),
            CLAIM_SLIPPAGE_BPS
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(StockFeeHookImmutable).creationCode, args);
        StockFeeHookImmutable hook = new StockFeeHookImmutable{salt: salt}(
            pm,
            weth,
            IV3SwapRouter(v3Router),
            ILaunchpadStockView(launchpad),
            IStockRoutesView(address(router)),
            hookFeeBps,
            treasury,
            dist,
            flagshipSink,
            IUniswapV3Factory(v3Factory),
            CLAIM_SLIPPAGE_BPS
        );
        require(address(hook) == hookAddr, "mined-address mismatch");

        pad.setStockPairRouter(address(router));
        pad.setStockGateHook(address(hook)); // hook.router() satisfies the consistency check
        // The hook must be an authorized fee source or its notify() reverts, which would leave
        // every mode stock token's mechanism unfunded. (The claim config + destinations + the
        // distributor are already baked into the immutable hook above.)
        if (dist != address(0)) IDistributorAdmin(dist).setFeeSource(address(hook), true);

        // DIRECT quotes: the stock's own <stock>/WETH pool carries the trade.
        pad.setAllowedQuote(COIN, true, 3000);
        _priceDirect(pad, weth, COIN, 3000);
        pad.setAllowedQuote(SPY, true, 500);
        _priceDirect(pad, weth, SPY, 500);
        pad.setAllowedQuote(MSTR, true, 10000);
        _priceDirect(pad, weth, MSTR, 10000);
        pad.setAllowedQuote(META, true, 3000);
        _priceDirect(pad, weth, META, 3000);

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
        // Batch 2 (2026-08-14 scan).
        _routed(pad, router, weth, SLV, 10000);
        _routed(pad, router, weth, RDDT, 10000);
        _routed(pad, router, weth, TSM, 10000);
        _routed(pad, router, weth, DELL, 10000);
        _routed(pad, router, weth, SNDK, 10000);
        _routed(pad, router, weth, ASML, 10000);
        _routed(pad, router, weth, QUBT, 10000);
        _routed(pad, router, weth, SGOV, 3000);
        _routed(pad, router, weth, USAR, 3000);
        _routed(pad, router, weth, RBLX, 10000);
        _routed(pad, router, weth, NU, 10000);

        // USDG itself as a quote — the "dollar-paired" option. 6 DECIMALS: the launch-price knob
        // must be its exact tiny wei figure (≈3 wei/token for ~$2.5-3k), which the launchpad's
        // signed tick shift now supports (down-shift). Route is the single WETH<->USDG 0.01% hop.
        pad.setAllowedQuote(USDG, true, USDG_BRIDGE_FEE);
        router.setQuoteRoute(
            USDG,
            abi.encodePacked(weth, USDG_BRIDGE_FEE, USDG),
            abi.encodePacked(USDG, USDG_BRIDGE_FEE, weth)
        );
        _priceQuoteDec(pad, USDG, 1e6, 6); // 1 whole USDG = 1e6 of itself

        vm.stopBroadcast();

        console2.log("StockPairRouter:", address(router));
        console2.log("StockFeeHook:   ", address(hook));
        console2.log("  router feeBps:", feeBps);
        console2.log("  hook feeBps:  ", hookFeeBps);
        console2.log("Quotes: 4 direct (COIN/SPY/MSTR/META) + 27 routed via USDG + USDG itself = 32");
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
        _priceQuote(pad, stock, _usdgWeiPerStock(stock, usdgFee));
    }

    /// Direct quotes price via their <stock>/WETH pool × the WETH/USDG spot.
    function _priceDirect(ILaunchpadAdmin pad, address weth, address stock, uint24 wethFee) internal {
        uint256 wethPerStock = _spot1e18(weth, stock, wethFee); // WETH-wei per whole stock
        uint256 usdgPerWeth = _spot1e18(USDG, weth, USDG_BRIDGE_FEE); // USDG-wei per whole WETH
        _priceQuote(pad, stock, Math.mulDiv(wethPerStock, usdgPerWeth, 1e18));
    }

    /// Set the quote's launch price so launch mcap ≈ TARGET_MCAP_USD:
    /// price(quote-wei per whole token) = TARGET × 1e6(USDG dp) × 10^quoteDec / (usdgWeiPerStock × SUPPLY).
    function _priceQuote(ILaunchpadAdmin pad, address stock, uint256 usdgWeiPerStock) internal {
        _priceQuoteDec(pad, stock, usdgWeiPerStock, 18);
    }

    /// Decimals-aware variant (USDG is 6-dp: its whole-token price is single-digit WEI, where
    /// flooring would round a $2.5k target to $2k — Ceil keeps the target the floor).
    function _priceQuoteDec(ILaunchpadAdmin pad, address stock, uint256 usdgWeiPerStock, uint8 quoteDec) internal {
        if (usdgWeiPerStock == 0) return; // no live pool → leave the default (owner can set later)
        uint256 p =
            Math.mulDiv(TARGET_MCAP_USD * 1e6, 10 ** quoteDec, usdgWeiPerStock * SUPPLY_TOKENS, Math.Rounding.Ceil);
        pad.setAllowedQuotePrice(stock, p);
        console2.log("  quote price set:", stock, p);
    }

    function _usdgWeiPerStock(address stock, uint24 usdgFee) internal view returns (uint256) {
        return _spot1e18(USDG, stock, usdgFee);
    }

    /// `out`-wei received for 1e18 wei of `base` at the pool's spot (0 if the pool is missing).
    function _spot1e18(address out, address base, uint24 fee) internal view returns (uint256) {
        address pool = IV3FactoryMin(V3_FACTORY).getPool(out, base, fee);
        if (pool == address(0)) return 0;
        (uint160 s,,,,,,) = IV3PoolMin(pool).slot0();
        address t0 = IV3PoolMin(pool).token0();
        uint256 ratioQ96 = Math.mulDiv(uint256(s), uint256(s), 1 << 96); // token1-wei per token0-wei
        if (ratioQ96 == 0) return 0;
        return base == t0
            ? Math.mulDiv(ratioQ96, 1e18, 1 << 96) // out is token1
            : Math.mulDiv(1 << 96, 1e18, ratioQ96); // out is token0
    }
}
