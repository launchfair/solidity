# LaunchFair — token launchpad (Uniswap V3 + V4)

A token launchpad where every token launches **straight into a real Uniswap pool** as a single-sided
range order, with the LP locked forever. Because the market is a normal pool from block one, DEX
terminals (GMGN, DexScreener, GeckoTerminal, …) index it automatically — no paid data integrations.

There are two contract stacks. See [`src/README.md`](src/README.md) for the full file-by-file layout.

| Stack | Path | AMM | What it is |
|---|---|---|---|
| **V1** (legacy) | `src/v1/` | Uniswap **V3** | The plain fair-launch launchpad — single-sided V3 curve, WETH-on-buy / burn-on-sell fees. Being retired. |
| **V2** (current) | `src/v2/`, `src/v2/v4/` | Uniswap **V4** | The mode-token launchpad — a V4 hook fee engine + a distributor that pays holders per **reward mode**. |

> Naming: "V2" is our launchpad's second generation; it runs on **Uniswap V4** under the hood, hence
> the `v2/v4` nesting. Contract names (`LaunchTokenV2`, `LaunchFairV4`) carry the same distinction.

---

## The bonding curve (both stacks)

A single-sided range order *is* a bonding curve — mathematically identical to a pump.fun-style
virtual-reserve constant-product curve. All supply sits above the launch price, so price only moves
by buyers walking it up a deterministic ladder. A token **bonds/graduates once its
`graduationWethAmount` of WETH has been raised into the pool** (net of sells, measured as
`WETH.balanceOf(pool)`); the target is snapshotted per token at creation and never changes
retroactively. `curveProgress(token)` returns progress in bps (0–10 000) for the frontend progress
bar. The curve lives *inside* the pool (that's what makes it indexable), never "sells out" (price can
keep climbing past graduation), and there is no transfer lock.

## Anti-sniper launch guard

For a fixed window after launch (V1: `maxBuyBlocks`, default 360 L1 blocks ≈ 72 min on Robinhood
Chain; V4: `setAntiSnipe(bps, blocks)`, default 2% / 100 blocks) no wallet may hold more than **2% of
supply**. Enforced in the token's transfer hook, so it covers pool buys and wallet-to-wallet stacking
alike; sells always work (the pool / locker / position manager are exempt — protocol plumbing only).
The guard **auto-expires** and nobody can extend, tighten, or re-enable it.

## Trust model

Tokens have no owner, no mint, no blacklist, and are freely transferable from creation. LP NFTs are
minted directly into a **FeeLocker** that has *no function* to withdraw the NFT or decrease liquidity —
the pool can never be rugged or migrated. The only owner powers are payout/treasury addresses, the
site metadata stamped into future tokens, and capped fee knobs.

---

## V1 stack (`src/v1/`) — plain fair launch on Uniswap V3

- **`V3Launchpad.sol`** — `createToken(...)`: deploys the token (CREATE2, creator-scoped salt),
  creates + initializes the V3 pool at the configured launch price, mints the full supply as a
  single-sided range order with the `FeeLocker` as LP owner. `checkGraduation` is a permissionless
  poke that bonds a token once its pool has raised its snapshotted `graduationWethAmount`. Also carries
  the treasury-only community-takeover hook `transferCreatorByTreasury`.
- **`FeeLocker.sol`** — permanently holds every LP NFT. `claim(token)` (permissionless) collects pool
  fees: **buys pay 1% in WETH**, split (owner-tunable) **treasury / dev / flagship-buyback**; **sells
  pay 1% in the token → burned** (pure deflation; nobody can dump fee-tokens on holders). No
  liquidity-withdrawal path exists by construction.
- **`LaunchToken.sol`** — vanilla OZ ERC20 + Burnable, renounced, fixed supply; creator metadata
  (logo, website, Telegram, Discord, X) immutable at creation, exposed via getters + ERC-7572
  `contractURI()`.

Plus a flat **creation fee** (default 0.000005 ETH, owner-tunable, hard-capped) forwarded to treasury.

## V2 / V4 stack (`src/v2/`, `src/v2/v4/`) — mode tokens on Uniswap V4

`LaunchTokenV2` picks one **mode** at launch (immutable); `LaunchFairV4Distributor` turns the
mechanism fee slice into holder value per mode:

| Mode | # | Payout |
|---|---|---|
| **Base** | 0 | Plain fair launch, no mechanism payout. |
| **Reward** | 1 | Buys up to 5 dev-chosen external tokens and distributes them to holders. |
| **Increasing** | 2 | Auto-compounding — buys back THIS token and distributes it (balances grow). |
| **Lottery** | 3 | Holdings-weighted three-outcome draw (miss / regular win / jackpot); a random holder takes the pot. |
| **Perps** | 4 | Deposits the fee as margin into an `IPerpsVenue` → mints a fungible `PerpPositionToken` (a share of a pooled leveraged stock-perp position), distributed hands-off like a reward token; holders hold / sell / **redeem for WETH at NAV**. |

Supporting contracts:

- **`LaunchFairV4.sol`** — the launchpad/factory: `createToken` + atomic **`createAndBuy`**
  (front-run-proof dev buy in the launch tx); wires the fee hook and the swap router.
- **`WethFeeHook.sol`** — the V4 hook that takes the fee in **WETH on BOTH buys and sells** (no token
  sell pressure) as ERC-6909 claims, on every trade regardless of router, then runs the 4-way split.
- **`LaunchFairV4FeeLocker.sol`** — locks the V4 LP, claims fees, carves the flagship slice from the
  dev share.
- **`LaunchFairV4Distributor.sol`** — the reward / lottery / perps mechanism + WETH→asset buyback
  engine (V3 & V4 venues).
- **`LaunchFairVRFCoordinator.sol` + `DrandBLS.sol`** — trustless lottery randomness: on-chain
  BLS12-381 verification of the public drand beacon (a draw snapshots holdings at its commit block, so
  the winner is frozen before the beacon is public).
- **Lottery** is three-outcome with two pools (pot + jackpot): **miss** rolls the pot over, **regular**
  pays a random holder a share and skims the rest to the jackpot, **jackpot** pays pot + whole jackpot
  pool. Odds are dev-tunable and set-once.
- **Perps** — `IPerpsVenue` / `PerpPositionToken` / `ReferenceStockPerpVenue`. The reference venue is
  **not production** (operator-set oracle) — a real venue must swap in a genuine push oracle
  (Chainlink/Pyth) + liquidations/funding. See [`AUDIT_PERPS_MODE.md`](AUDIT_PERPS_MODE.md).

## Flagship flywheel (`src/flywheel/`)

Fees across both stacks feed a **flagship** platform token: a slice funds **buybacks** of the flagship,
and each weekly **season** the bought flagship is split pro-rata by trading points and users **claim
on-chain** from **`SeasonMerkleDistributor.sol`** (per-season Merkle roots; transparent +
admin-recoverable). See [`FLAGSHIP_FLYWHEEL_STATUS.md`](FLAGSHIP_FLYWHEEL_STATUS.md).

---

## Build & test

```bash
forge build
forge test          # 153 tests pass (0 failed); fork tests are gated behind RUN_FORK_TESTS

# Fork tests against the LIVE Robinhood Chain (real pool init, swaps, guard, claim, graduation):
RUN_FORK_TESTS=true forge test --match-contract RobinhoodChainFork -vv
```

Toolchain: solc **0.8.26**, `via_ir = true`, optimizer runs 200. Tests mirror `src/`: `test/v1/`,
`test/v2/` (the V4 engine), `test/flywheel/`, shared mocks in `test/mocks/`.

Deploy scripts (`script/`): `Deploy.s.sol` (V1), `DeployV4.s.sol` (V4),
`DeploySeasonDistributor.s.sol` (after the flagship launches), `DeployWethFeeHook.s.sol` + `HookMiner.sol`.

## Robinhood Chain (chain id 4663)

Stable infra, verified on-chain against `https://rpc.mainnet.chain.robinhood.com`:

| Contract | Address |
|---|---|
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| UniswapV3Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| Uniswap V4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

> **Two block numbers on this chain:** the EVM `block.number` opcode returns the **Ethereum L1 block**
> (~12 s), while `eth_blockNumber` returns the **L2 block** (~100 ms). The anti-snipe guard is in
> L1-block terms — read the current L1 block via `Multicall3.getBlockNumber()`, not `eth_blockNumber`.

Live launchpad/distributor/locker addresses rotate across redeploys — the frontend/indexer configs are
the source of truth for the current deployment.

## Security

Internal reviews: [`AUDIT.md`](AUDIT.md) (V1), [`AUDIT_V4_HOOK.md`](AUDIT_V4_HOOK.md) (the WETH fee
hook), [`AUDIT_PERPS_MODE.md`](AUDIT_PERPS_MODE.md) (the perps reward mode). Before mainnet: an
independent external review, a real oracle + liquidations for any production Perps venue, and a
multisig for every owner/treasury key.
