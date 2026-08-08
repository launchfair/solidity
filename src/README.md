# Contracts layout

Two launchpad stacks live here. The platform is **consolidating onto the V4 stack** (`src/v2`);
the V1 stack (`src/v1`) is the legacy plain-token launchpad and is being retired. Points/seasons
and the flagship flywheel span both.

```
src/
├── v1/                     LEGACY — plain-token launchpad (bonding curve → Uniswap V3). Being retired.
│   ├── V3Launchpad.sol       factory + bonding curve; graduates to a Uniswap V3 pool
│   ├── FeeLocker.sol         locks the graduated LP; splits WETH fees 25 treasury / 25 dev / 50 flagship (settable)
│   └── LaunchToken.sol       the V1 ERC20 (on-chain SVG metadata)
│
├── v2/                     CURRENT — mode-token launchpad (Uniswap V4).
│   ├── LaunchTokenV2.sol     the V2 ERC20 (modes: Base / Reward / Increasing / Lottery / Perps)
│   ├── TokenDeployerV2.sol   deploys LaunchTokenV2 instances
│   └── v4/
│       ├── LaunchFairV4.sol            the V4 launchpad/factory (create + atomic createAndBuy); wires the fee hook
│       ├── LaunchFairV4FeeLocker.sol   locks the V4 LP; claims fees; carves the flagship slice from the dev share
│       ├── LaunchFairV4Distributor.sol reward / lottery / perps mechanism + WETH→asset buyback engine
│       ├── LaunchFairV4SwapRouter.sol  minimal V4 swap router
│       ├── WethFeeHook.sol             V4 hook: takes the fee in WETH on BOTH buys and sells (no token sell pressure)
│       ├── LaunchFairVRFCoordinator.sol lottery randomness (VRF)
│       ├── DrandBLS.sol                drand BLS12-381 verification (trustless lottery beacon)
│       ├── FeeSplitConfig.sol          fee-split config (treasury / dev / mechanism)
│       ├── LiquidityMath.sol           sqrtPrice / liquidity helpers
│       ├── IPerpsVenue.sol             Perps-mode venue interface (marginToken / open / positionTokenFor)
│       ├── PerpPositionToken.sol       fungible ERC20 share of a pooled leveraged position (redeem for WETH at NAV)
│       └── ReferenceStockPerpVenue.sol reference venue — WETH margin, operator oracle, mints PerpPositionToken (NOT production)
│
├── interfaces/
│   └── IUniswapV3.sol       SHARED — used by V1 pools AND the V4 distributor's V3 buyback venue
│
└── flywheel/
    └── SeasonMerkleDistributor.sol   SHARED — per-season Merkle reward claim for the flagship flywheel
```

Tests mirror this layout: `test/v1/`, `test/v2/` (the V4 engine), `test/flywheel/`, with shared mocks
in `test/mocks/`. Deploy scripts live in `script/` (`Deploy` = V1, `DeployV4` = V4,
`DeploySeasonDistributor`, `DeployWethFeeHook` + `HookMiner`).

## Naming note

"V2" (our launchpad's second generation) uses **Uniswap V4** under the hood — hence the `v2/v4`
nesting. The V1 launchpad uses **Uniswap V3**. Contract names (`LaunchTokenV2`, `LaunchFairV4`)
carry the same distinction.

## Fee model

- **V1** (`FeeLocker`): WETH-on-buy, token burn on sell. Split 25/25/50 (treasury/dev/flagship), owner-tunable.
- **V4 default** (`LaunchFairV4FeeLocker`): WETH-on-buy, token burn on sell; mechanism slice funds the
  token's own reward/lottery; a flat 0.1%-of-trade carve from the dev slice funds the flagship.
- **V4 + WethFeeHook** (going-forward): fee taken in **WETH on both legs** (no token sell pressure),
  captured on every trade regardless of router. Feeds the same treasury/dev/mechanism/flagship split.

## Reward modes (`LaunchTokenV2`)

Every V4 token picks one mode at launch (immutable). The distributor turns the mechanism fee slice
into holder value per mode:

- **Base** — plain fair launch, no mechanism payout.
- **Reward** — buys up to 5 dev-chosen external tokens and distributes them to holders.
- **Increasing** — auto-compounding: buys back THIS token and distributes it (every holder's balance grows).
- **Lottery** — holdings-weighted three-outcome draw (miss / regular win / jackpot); a random holder
  takes the pot. Randomness is trustless drand BLS (`DrandBLS` + `LaunchFairVRFCoordinator`).
- **Perps** — deposits the fee slice as margin into an `IPerpsVenue`, which mints a fungible
  `PerpPositionToken` (a share of a pooled leveraged stock-perp position) and distributes it hands-off
  like a reward token; holders hold / sell / redeem for WETH at NAV. `ReferenceStockPerpVenue` is a
  reference only (operator-set oracle) — a production venue needs a real oracle + liquidations.

## Audits

- `AUDIT.md` (V1), `AUDIT_V4_HOOK.md` (WETH fee hook), `AUDIT_PERPS_MODE.md` (perps mode) — internal reviews.
- `FLAGSHIP_FLYWHEEL_STATUS.md` — the fee → buyback → seasonal-Merkle flagship flywheel.
