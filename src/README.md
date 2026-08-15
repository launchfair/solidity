# Contracts layout

The current system is the **mode-token launchpad on Uniswap V4** (`src/v2/`, `src/v2/v4/`) plus the
**flagship flywheel** (`src/flywheel/`). Every launched market is a real Uniswap V4 pool.

> A retired `src/v1/` (a plain-token launchpad on Uniswap V3) still exists in the tree but is being
> decommissioned and is not part of the current system, so it is intentionally omitted below.

```
src/
├── v2/                     the launchpad
│   ├── LaunchFairTokenFactory.sol  permanent creator address: delegatecall proxy over TokenDeployerV2
│   ├── TokenDeployerV2.sol         stateless factory implementation (deploys LaunchTokenV2 instances)
│   ├── LaunchTokenV2.sol           the ERC20 (modes: Base / Reward / Increasing / Lottery)
│   └── v4/
│       ├── LaunchFairV4.sol            the launchpad (create + atomic createAndBuy); holds the launch record
│       ├── WethFeeHookImmutable.sol    CURRENT V4 fee hook: fee in WETH on BOTH legs; no owner, no setters
│       ├── WethFeeHook.sol             superseded owner-tunable hook (only pools created before the swap use it)
│       ├── LaunchFairV4FeeLocker.sol   locks the V4 LP forever; no withdrawal or decrease path
│       ├── LaunchFairV4Distributor.sol reward / lottery mechanism + WETH-to-asset buyback engine
│       ├── LaunchFairV4SwapRouter.sol  minimal native-ETH V4 swap router (buy / sell)
│       ├── LaunchFairVRFCoordinator.sol lottery randomness coordinator
│       ├── DrandBLS.sol                on-chain drand BLS12-381 verification (trustless lottery beacon)
│       ├── FeeSplitConfig.sol          per-tier fee-split table (treasury / dev / mechanism)
│       ├── LiquidityMath.sol           sqrtPrice / liquidity helpers
│       ├── CoreTGE.sol                 flagship/core token generation (seeded launch through the factory)
│       ├── StockPairRouter.sol         stock-paired tokens: buy/sell in ETH over a TOKEN/<stock> pool
│       ├── StockFeeHook.sol            stock-pool hook: takes the WETH fee in-pool and gates trading to the router
│       └── (Perps mode files: IPerpsVenue.sol / PerpPositionToken.sol / ReferenceStockPerpVenue.sol / RouterGateHook.sol)
│
├── flywheel/
│   ├── FlagshipBuyback.sol          buyback vault: fee-funded flagship buybacks; fixed-destination team cut
│   └── SeasonMerkleDistributor.sol  per-season Merkle reward claim (with a keeper-veto claim window)
│
└── interfaces/
    └── IUniswapV3.sol       used by the distributor's V3 reward/buyback venues and the stock-quote routes
```

Tests mirror this layout: `test/v2/` (the V4 engine) and `test/flywheel/`, with shared mocks in
`test/mocks/`. Deploy scripts live in `script/`: `DeployV4` (the launchpad stack),
`DeployTokenFactory` (the permanent factory), `DeployWethFeeHookImmutable` + `HookMiner` (the immutable
fee hook), `DeployStockPair` (stock-paired quotes), `DeploySeasonDistributor` (after the flagship
launches), and `SwapTokenImpl` (hot-swap the factory's token implementation).

## Permanent creator address

`LaunchFairTokenFactory` is a delegatecall proxy in front of the stateless `TokenDeployerV2`. Because
every token is deployed in the proxy's context, all launched tokens share ONE canonical, permanent
creator address that indexers and token trackers can key on, even across token-code upgrades. The
upgrade surface is bounded (deployer-or-treasury only, contract-is-checked on every call, an
allowlist of launchers, disabled renounce, and a one-way `freezeImplementation`). See the security
section in the top-level [`README.md`](../README.md) for the full rationale.

## Fee model

The fee is taken in **WETH on both legs** (no token sell pressure) by `WethFeeHookImmutable`, captured
on every trade regardless of router, at the token's chosen **tier (3, 5, or 10 percent)** written once
into the launch record. Every collected fee is split the same flat way for all tokens and tiers:
**dev 50 / mechanism 30 / treasury 10 / buyback 10**. Treasury, dev, and the buyback are paid as native
ETH; the mechanism slice stays in WETH and funds the token's own reward or lottery. A Base token has no
mechanism, so its 30% folds into the buyback (40% of every fee to the flywheel). The buyback slice goes
to the `FlagshipBuyback` vault, which converts it into the core token for the points/seasons flywheel,
so every launched token feeds the flywheel. See
[`docs/V4_WETH_FEE_HOOK.md`](../docs/V4_WETH_FEE_HOOK.md).

## Reward modes (`LaunchTokenV2`)

Every token picks one mode at launch (immutable). The distributor turns the mechanism fee slice into
holder value per mode:

- **Base**: plain fair launch, no mechanism payout.
- **Reward**: buys up to 5 dev-chosen external tokens and distributes them to holders.
- **Increasing**: auto-compounding: buys back THIS token and distributes it (every holder's balance grows).
- **Lottery**: holdings-weighted three-outcome draw (miss / regular win / jackpot); a random holder
  takes the pot. Randomness is trustless drand BLS (`DrandBLS` + `LaunchFairVRFCoordinator`).

> A fifth enum value, **Perps**, exists in the contracts but is **not currently offered**:
> `ReferenceStockPerpVenue` uses an operator-set oracle and is not production. A real venue would need a
> genuine push oracle plus liquidations and funding. See [`docs/PERPS_REWARD_MODE.md`](../docs/PERPS_REWARD_MODE.md).

## Stock-paired tokens (`createStockToken`)

An additive launch type whose liquidity pool is **`TOKEN/<stock>`** (for example `TOKEN/AAPL`, using
the first-party Robinhood tokenized stocks) instead of `TOKEN/WETH`, so holders get built-in equity
exposure. Users still **buy with native ETH and sell for ETH**: the `StockPairRouter` routes
`ETH -> WETH -> stock -> TOKEN` (and back) in one tx, hopping the `<stock>/WETH` leg on Uniswap V3 and
the `TOKEN/<stock>` leg on the V4 pool. The **fee is taken in WETH at the router**, then split
treasury / dev / mechanism / flagship exactly like the WETH-paired path, so dev-fee economics are
unchanged. The pool is gated by `StockFeeHook` (only the router may swap it), so the fee cannot be
bypassed. Quotes are an owner allowlist (`setAllowedQuote`, runtime, no redeploy to add one). Deploy
with `script/DeployStockPair.s.sol`.

## Security

The full security write-up (review process, the token-safety and scanner-posture fixes, the permanent
factory's bounded upgrade surface, the flywheel keeper hardening, and the known pre-production
requirements) lives in the top-level [`README.md`](../README.md#security-audits-and-fixes). Hook-level
notes are in [`docs/V4_WETH_FEE_HOOK.md`](../docs/V4_WETH_FEE_HOOK.md).
