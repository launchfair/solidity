# Flagship Flywheel — Status & Reference

_Last updated: 2026-08-03. Single source of truth for the platform-token flywheel work.
Everything below is **built, tested, and local** — **nothing is deployed, committed, or pushed** yet.
The V4 fee stack (WETH hook + all recent changes) is now **audited + hardened** (see
`AUDIT_V4_HOOK.md`), and `src/` was reorganized (`v1/` legacy · `v2/v4/` current · `flywheel/` ·
`interfaces/` — see `src/README.md`). **153 contract tests pass.**_

---

## 1. What we're building (the idea)

A **flagship token** that the whole platform revolves around (a PONS-style protocol token). The loop:

1. Every **plain token** launched through our factory charges a swap fee, split
   **25% treasury / 25% creator / 50% flagship-buyback**.
2. The **50% buyback** slice — pooled across all plain tokens — is used to **buy the flagship** off the market.
3. **Each week is a "season."** Wallets earn **points = trading volume** on our-factory tokens.
4. At season end, the flagship bought that week is **split pro-rata by points** and users **claim it on-chain**.
5. The flagship is **launched later** (via our own launchpad); everything runs idle/fallback until it exists.

### Confirmed decisions (yours)
| Decision | Choice |
|---|---|
| Fee split | **25% treasury / 25% creator / 50% buyback** (of the 1% fee = 0.25% / 0.25% / 0.5% of the trade). "Contributors" = the **treasury** wallet; "dev" = the per-token **creator**. **Owner-tunable any time** via `setFeeShares(treasuryBps, devBps, flagshipBps)` (must sum to 10000). |
| Which tokens fund the flagship | **V1/V3 plain tokens** (25/25/50 split) **AND V4 tokens** (a flat, editable **0.1%-of-trade** cut carved from the **creator/dev slice only** — treasury + the reward/lottery mechanism are untouched, so V4's own buyback stays fully funded). Both route to the same `flagshipSink`. |
| Distribution | **On-chain seasonal Merkle claim** (users pull from a contract with a proof), **admin-recoverable** ("nothing frozen" — owner can rescue/roll/override). Transparent + recoverable, **not trustless**. |
| Reward asset | The **flagship token** itself. |
| Points formula (v1) | **Raw trading volume.** Wash-trading accepted for v1; the formula is a single swappable expression. |
| Season length | **7-day epochs** (`blockTime / 604800`). |
| Flagship token | **Launched later via our launchpad.** All contracts/keeper take a settable address and idle until it's set. |

---

## 2. How it works, end to end

```
 Plain V1/V3 token trades
        │  1% swap fee
        ▼
 FeeLocker.claim()  ──►  25% treasury  ·  25% creator  ·  50% ──► flagshipSink (= keeper wallet)
        │                                                              │
 (sell-side token fees are burned)                                     │ accumulates WETH
                                                                       ▼
                                              Flagship Keeper (off-chain, our infra)
                                              • buys flagship with the WETH (MEV-bounded swap)
                                              • at each season's end:
                                                  - allocate the week's flagship by points
                                                  - build a Merkle tree of (wallet → amount)
                                                  - fundAndPublish(season, root) on the distributor
                                              ▼
                                   SeasonMerkleDistributor (on-chain)
                                   • holds each season's flagship
                                   • users claim(season, proof) → flagship to their wallet
                                              ▲
 Indexer computes per-wallet weekly volume → points → SeasonWallet table
 Frontend /points page: leaderboard + your points/rank + claimable + Claim button
```

The **keeper wallet** plays three roles: it's the FeeLocker `flagshipSink`, the buyback swapper, and the distributor `rootPublisher`.

**V4 tokens also feed the same `flagshipSink`** — a flat 0.1%-of-trade cut from their
`LaunchFairV4FeeLocker`, carved from the creator slice only (treasury + reward/lottery mechanism
untouched). So the keeper's buyback pools both V1 and V4 flagship contributions.

---

## 2b. The flagship token's OWN fee — settable globally (one knob, all tokens live/new/old)

The flagship is **not special-cased** in any contract — it's just a settable buyback-target address.
So **launched through our launchpad it charges the normal swap fee like any token** (NOT fee-exempt),
and as a plain/Base token its buyback slice routes to `flagshipSink` → the keeper buys the flagship →
**the flagship's own trading fees buy back the flagship**, which flows into the weekly season pot.

**Fee params are a single global knob on the `WethFeeHook`**, and a change applies to **every token on
the hook at once — live, new, or old** (the rate/split is read at swap time, so it takes effect
immediately on all existing pools, no per-token or per-launch bookkeeping):
- `setFeeBps(bps)` — the fee rate (bps of the WETH leg, ≤ `MAX_FEE_BPS`).
- `setSplit(t, d, m, f)` — the 4-way split (treasury/dev/mechanism/flagship, must sum to `BPS`).

The flagship uses this same global config; as a plain/Base token ~50% of its fee self-buys-back under
the default split (mechanism 40% folds to flagship + flagship 10% → `flagshipSink` → keeper → season
pot). Tested: `test_globalFeeBps_appliesToLivePools`. (We briefly added per-token overrides, then
**removed them in favor of this single global knob** — one setting for all tokens, your call.)

---

## 2c. V4 token reward types (what a token's OWN mechanism slice funds)

The fee split has a **mechanism slice** that funds the token's own reward for **its holders** — separate
from the platform flywheel (treasury + the flagship carve still feed the flagship above). Every V4 token
picks a **mode** at launch (`LaunchTokenV2.Mode`). A plain/**Base** token has no mechanism, so on the
hook its mechanism slice folds into the **flagship** instead.

| Mode | What holders get | How it's funded / paid |
|---|---|---|
| **Base** (0) | — (plain fair launch) | mechanism slice → the **flagship** (on V1 plain tokens, that's the 50% flagship slice) |
| **Reward** (1) | an **external reward token**, dividend-style — up to a **5-asset basket** | keeper `process()` buys each asset by the dev's fee weights on its own V3/V4 venue → dividend tracker → holders **claim pro-rata by holdings** |
| **Increasing** (2) | **more of THIS token** — auto-compounding, your on-chain balance grows | mechanism WETH buys back the token → distributed to holders as balance growth (`balanceOf` reflects it) |
| **Lottery** (3) | a **holdings-weighted jackpot** — odds = your balance ÷ total held | pot accrues from fees; drand-seeded draws pay a random holder. Three outcomes (**miss** rolls the pot over · **regular** win · **jackpot**) + a separate rollover jackpot pool + repeat-winner **cooldown that re-draws** past a cooling holder. Powerball ($BALL) style |
| **Perps** (4) | a **fungible leveraged-position token** — real margined stock exposure (dev-picked market/side/leverage basket, 1–5 legs) that holders hold, sell, or **redeem for WETH at NAV** | fees deposited as margin via a venue → the venue mints the position token → distributed hands-off like any reward asset. Margin is **fees, never holder principal** (a liquidation wipes that leg's fees, not a balance). **BUILT + audited + hardened** (`AUDIT_PERPS_MODE.md`) — the reward-mode integration + reference venue are done; only a production venue (real equity oracle/liquidations) + its audit remain before ship. `docs/PERPS_REWARD_MODE.md` |

All modes reuse one path — `fee → notify() → pendingWeth[token] → keeper process()` — then per mode it
buys the reward asset (Reward), buys back the token (Increasing), or funds the pot (Lottery).
**Reward / Increasing / Lottery are live** (in the V4 stack being redeployed with the carve + cooldown +
hook; the hook can now fund a hooked mode token's mechanism via `notify`, N-1). **Perps is now built**
(tokenized leveraged-position model, tested end-to-end against a reference venue) — it needs a
production venue + its own audit before it ships. Enable it by deploying the venue and calling
`setPerpsVenue` on both `LaunchFairV4` and `LaunchFairV4Distributor`.

How the two sides coexist per trade: **treasury + the flagship carve → platform flywheel**; **mechanism
slice → the token's own mode** (or → flagship for Base). One fee, both the platform and the token's
holders get funded.

---

## 2d. Perps mode in detail — leveraged stock positions as a reward (BUILT)

The newest reward type. Instead of rewarding holders with a bought-back ERC20 or a cash dividend, a
**Perps** token turns its fees into **leveraged long/short positions on RWA stock markets** (AAPL,
NVDA, TSLA…) and hands each holder **the actual position, tokenized**.

**What the holder gets.** A **fungible leveraged-position token** (`PerpPositionToken`, one ERC20 per
`market × side × leverage`, e.g. "LF Perp AAPL Long 3x"). It's a real margined position that lands in
their wallet — they can **hold it, sell it, or redeem it for WETH at NAV** (which moves with the
leveraged stock price). Not a promise of yield, not a cash drip — the position itself.

**How it flows** (same hands-off `process` path as a reward token, just a different "acquire" step):
```
fee → FeeLocker/hook → notify() → pendingWeth[token]                    (UNCHANGED)
    → keeper process() → deposit the fee as MARGIN into the dev's basket
                         (venue.open per leg, by weight) → mints position tokens
    → fund the SAME dividend tracker → holders CLAIM the position token   (UNCHANGED)
    → holder redeems it on the venue for WETH at NAV, whenever they want
```

**The dev picks the basket at launch, frozen** (like reward assets): 1–5 legs, each
`(market, long/short, leverage, weight)`, weights sum to 10000, leverage ≤ **5×** (mode-enforced). The
keeper only ever times deposits — it **never chooses direction or leverage** (read straight off the
position token), so the trust surface stays tiny. Closed stock market → that leg's WETH is **held**
until it reopens.

**Principal-safe by construction.** The margin is **fees (house money), never a holder's token
balance**. Worst case a leg gets liquidated — its *fees* for that round are wiped and its
position-token holders are zeroed (the leverage risk they accepted), but **no one's launch-token
balance is ever touched**. Upside: leverage amplifies the reward; downside: a round pays 0.

**Status — built, audited + hardened; needs a production venue.** Audit done (`AUDIT_PERPS_MODE.md`,
3 adversarial passes): no Critical, math proven sound, and the two serious bugs (a liquidated leg
bricking rewards; a winning pool draining another pool's collateral) are fixed + tested, along with an
MEV oracle-latency vector and the LOWs. What's left before ship is a **production venue** (a real
oracle is the load-bearing dependency) + its own audit. The mode is code-complete across
`LaunchTokenV2` (`Mode.Perps`), `LaunchFairV4` (the `PerpLeg[]` basket + `perpsVenue`), and the
Distributor (`process` Perps branch), proven end-to-end against a **reference venue**
(`src/v2/v4/{IPerpsVenue,PerpPositionToken,ReferenceStockPerpVenue}.sol`; capstone test: launch → fee
→ process → holder claims the leveraged token → +10% underlying → redeems for +30% WETH). The
reward-mode integration + the reference venue are **audited + hardened** (`AUDIT_PERPS_MODE.md` — no
Critical; the two serious bugs and an MEV vector are fixed + tested). What remains before it can ship:
a **production venue** (a real equity oracle like Pyth/Chainlink, liquidations, funding — the reference
venue uses an operator-set oracle and is NOT production) **plus that venue's own audit**, the keeper's
process/redeem loop, and a frontend basket picker. Enable it by deploying the venue, `listMarket(...)`-ing
the RWA markets + funding house liquidity, then `venue.setOpener(distributor, true)` and
`LaunchFairV4.setPerpsVenue(venue)` (the distributor's venue is pinned per-token at launch — no separate
distributor setter). Full spec: `docs/PERPS_REWARD_MODE.md`.

---

## 3. What's built, by phase

Three repos: **`~/robinhood`** (contracts), **`~/launchfair-api`** (API + indexer + keeper),
**`~/frontend-hood`** (frontend, on branch `hood-ui-overhaulv2`).

### Phase 1 — Season points backend ✅
- `SeasonWallet` table + migration `prisma/migrations/20260731000000_add_season_wallet`.
- `recomputeSeasons()` / `seasonsLoop()` in `server/robinhood-indexer.ts` (~60s loop, off request path;
  per-wallet weekly volume on `external=false` tokens, with a wallet-exclusion clause).
- APIs: `GET /api/rh/season/current` (leaderboard + totals), `GET /api/rh/season/[wallet]`
  (your points/rank + settled-season claim data).
- Verified read-only on prod: full recompute ~360ms.

### Phase 2 — Fee routing (V1 FeeLocker) ✅
- `src/FeeLocker.sol` rewritten: WETH split **25/25/50**, **owner-tunable via `setFeeShares`**
  (the three bps must sum to 10000 — retune mid-flight) + settable **`flagshipSink`** (folds into
  treasury until set, so V1 works before the flagship exists). `claim()` return + `FeesClaimed`
  event gained `wethToFlagship`.
- **V4 `LaunchFairV4FeeLocker`**: added a flat, editable **flagship cut** (default `flagshipTradeBps`
  = 10 = 0.1% of the trade) carved from the **dev slice only** → the same settable `flagshipSink`;
  treasury + mechanism never reduced. Off until `flagshipSink` is set. Also: **lottery winner
  cooldown** (`LaunchFairV4Distributor`) — a repeat winner within `winCooldownSecs` (default 1h,
  owner-settable) is skipped and the draw **re-draws to the next eligible holder** (voids to a MISS
  only if every holder is cooling). Both changes ⇒ **the V4 stack now needs a redeploy** (previously
  untouched); now **audited** (§4). Tests updated; `forge test` green.

### Phase 3 — Buyback keeper ✅
- `server/robinhood-flagship-keeper.ts`: buys flagship with accumulated WETH (pool-level price bound,
  fee-adjusted min-out), and at season close **atomically funds + publishes** the Merkle root, persisting
  proofs first. Idle until `KEEPER_PKEY` + `FLAGSHIP` + `DISTRIBUTOR` env are set.
- `SeasonPot` table (per-season buyback accounting) + migration `20260731010000`.
- `package.json` script `rh-flagship-keeper`.

### Phase 4 — Seasonal Merkle distributor ✅
- `src/SeasonMerkleDistributor.sol` (new): per-season roots, single `rootPublisher`, set-once roots
  capped at the published total, per-claim cap, admin recovery (rescue-to-immutable-treasury,
  rollUnclaimed, adminSetRoot), `Ownable2Step`.
- `server/lib/season-merkle.ts`: dependency-free tree builder (leaf hashing verified **byte-identical**
  to the contract).
- `SeasonMerkle` table (per-wallet proofs) + proof serving via the `/api/rh/season/[wallet]` route.
- 15 contract tests.

### Phase 5 — Deploy scripts ✅ (deploy itself pending)
- `script/Deploy.s.sol` redeploys `V3Launchpad` (the **WETH-drain security fix**, already in source) +
  the new `FeeLocker` (25/25/50 + optional `FLAGSHIP_SINK` env).
- `script/DeploySeasonDistributor.s.sol` deploys the distributor — **run after the flagship launches**
  (flagship is an immutable constructor arg).

### Phase 6 — Frontend season UI ✅ (on `hood-ui-overhaulv2`, uncommitted)
- `src/app/points/page.tsx`: season summary, your rank/points/volume, claimable rewards with an
  on-chain **Claim** button, and the current-season leaderboard — in the v2 design.
- `src/lib/evm/season.ts` (`claimSeason` + `readSeasonClaimed`), season fetchers in `rhApi.ts`,
  `SEASON_DISTRIBUTOR_ADDRESS` in `chain.ts`. The existing "Points" sidebar entry already routes here.
- Claim stays disabled until `NEXT_PUBLIC_ROBINHOOD_SEASON_DISTRIBUTOR` is set.

---

## 4. Security audit

Three independent review rounds (two full audits + one delta verification), plus author passes.

- **Round 1:** 3 High, 6 Medium, 4 Low → **all fixed.**
- **Round 2** (re-audit of fixes): all resolved, no fund-loss/theft/double-fund; only Low items → **fixed.**
- **Round 3** (independent verify of the round-2 hardening): **all correct, no new Critical/High/Medium — "safe to ship."**

Headline fixes: atomic `fundAndPublish` (no double-fund), `adminSetRoot` requires `claimed==0`,
pool-level `sqrtPriceLimitX96` MEV bound + fee-adjusted min-out, proofs persisted before publish
(idempotent/crash-safe), immutable treasury + rescue-to-treasury-only, `seasonTotal` claim cap,
measured-delta funding (fee-on-transfer safe), zero-root/zero-amount guards, `Ownable2Step`,
wallet exclusions, exact approvals.

**Accepted-by-design residuals (not defects):**
1. **Owner can rescue all undistributed funds** — your "nothing frozen" requirement. → **Deploy the
   distributor `owner` as a multisig.** (The one real deploy-posture recommendation.)
2. **MEV griefing residual** — manipulation can only make a buyback *revert* (self-heals, ≤0.5 WETH/swap);
   bounded, non-extractable.
3. **Leaderboard exclusions** — set `ROBINHOOD_SEASON_EXCLUDE` to keeper/sink + treasury + distributor.
4. Pre-existing INFO: keeper `total` assumes a standard (non-fee-on-transfer) flagship — true by
   construction; would revert safely otherwise.

**Test status:** 153 contract tests pass; API + frontend typecheck clean.

**Perps reward mode — AUDITED (2026-08-03), see `AUDIT_PERPS_MODE.md`.** 3 independent adversarial
passes + author verification over the venue (`IPerpsVenue`/`PerpPositionToken`/`ReferenceStockPerpVenue`)
and the integration (`Mode.Perps`, `LaunchFairV4` basket + registration, Distributor `process`). No
Critical; the NAV/PnL/share math is proven sound and first-depositor inflation is not exploitable.
Fixed + tested: **H-1** a liquidated/zero-share leg no longer bricks `process()` (try/catch → hold),
**H-2** the venue segregates a `houseBalance` so a winning pool can't drain another pool's collateral
(reverts `InsufficientHouse`), **H-3** `open` gated to authorized depositors (kills MEV oracle-latency
farming), **M-1** the venue is pinned per-token at launch + `marginToken==weth` asserted, plus the LOWs.
Remaining is the **production venue** (a real oracle is the load-bearing dependency) + its own audit.

**V4 fee stack — AUDITED (2026-08-03), see `AUDIT_V4_HOOK.md`.** A full human-grade pass (4 independent
adversarial reviews + author verification against `lib/v4-core`) over the new `WethFeeHook` + every
post-flywheel V4/V1 change (hook wiring, Base-on-V4, the flagship carve, the lottery cooldown, the V1
`setFeeShares`). **No Critical/High.** The shared ERC-6909 WETH-claim pool is proven non-drainable and
delta accounting is correct in all four swap cases. Remediation applied + tested: exact-output fee legs
implemented, hook fee cap + `validateHookPermissions`, fee-0 locker short-circuit, `notify` fail-safe,
`Ownable2Step`, `MIN_DEV_BPS` creator floor, the lottery cooldown **re-draw**, and **N-1** (the hook is
now an authorized `notify`er on the distributor). Full findings + status in `AUDIT_V4_HOOK.md`.

---

## 5. What is NOT done (pending your go-ahead)

- **No deploys.** No prod DB migrations, no contract deploys, no service restarts.
- **No commits/pushes.** All changes are local working-tree edits in the three repos.
- **V4 redeploy now also needed** (was previously untouched): the V4 flagship carve + lottery
  cooldown changed `LaunchFairV4FeeLocker` + `LaunchFairV4Distributor`, so the V4 stack must be
  redeployed and those changes re-audited.
- **Flagship token not launched** (your call, later, via our launchpad).
- **Perps mode not shippable yet** (§2d): the reward-mode integration + reference venue are now
  **audited + hardened** (`AUDIT_PERPS_MODE.md`), but a Perps token launch still needs a **production
  perp venue** (real equity oracle / liquidations / funding) + that venue's own audit.
- **Overhaul branch:** `hood-ui-overhaulv2` now has `master`'s SSR/perf work (pulled via the
  colleague's `dc0dd7a`, plus the committed candle-spike fix `4eeaab9`). Its Season 1 / Use2Earn page
  is **mock-driven** — it still needs wiring to the real season API + the on-chain claim before ship.

---

## 6. Deploy runbook (ordered, for when you're ready)

1. **Backend (safe, additive):** apply the 3 season migrations to the prod RH DB (surgical `CREATE TABLE
   IF NOT EXISTS` via psql), rebuild the API, restart `rh-indexer` (season loop), start `rh-flagship-keeper`
   (idle). → season leaderboard goes live.
2. **V1 security redeploy:** run `Deploy.s.sol` (new `V3Launchpad` + `FeeLocker`), `setFlagshipSink` =
   keeper wallet, migrate the new addresses into the indexer + frontend, update the `FeesClaimed` ABI for
   the new `wethToFlagship` field. (This is the WETH-drain fix — needed regardless of the flywheel.)
3. **V4 redeploy** (flagship carve + lottery cooldown): redeploy the V4 stack
   (`LaunchFairV4` / `LaunchFairV4FeeLocker` / `LaunchFairV4Distributor`), `setFlagshipSink` =
   keeper wallet on the V4 locker (and `setFlagshipTradeBps` / `setWinCooldown` if changing the
   0.1% / 1h defaults), migrate the new V4 addresses into the indexer + frontend, and update the
   indexer's **V4 `FeesClaimed` ABI** for the new `wethToFlagship` field. **Re-audit first.**
4. **When the flagship launches:** deploy `SeasonMerkleDistributor` **with a multisig owner**, set the
   keeper env (`ROBINHOOD_FLAGSHIP_TOKEN`, `ROBINHOOD_SEASON_DISTRIBUTOR`) and the frontend env
   (`NEXT_PUBLIC_ROBINHOOD_SEASON_DISTRIBUTOR`) → buybacks + weekly claims begin.
5. **Overhaul branch:** merge `master`'s SSR/perf into `hood-ui-overhaulv2` before it ships.

### Key env vars at deploy — **only the NEW ones to add**

_Already present / no action: `ROBINHOOD_RPC_URL`, the deployer key, and the treasury
(`TREASURY` / `ROBINHOOD_TREASURY` default to the existing `0x82C8…`). Keeper tuning knobs
(`ROBINHOOD_FLAGSHIP_SLIPPAGE_BPS`, `_MAX_WETH_PER_SWAP_WEI`, `_BUYBACK_MS`, `_MIN_WETH_WEI`,
`_POOL_FEE`) all have sane defaults — set only if you want to change them._

**Keeper** (`rh-flagship-keeper`) — stays idle until these are set:
| Var | When | Purpose |
|---|---|---|
| `ROBINHOOD_KEEPER_PKEY` | to enable the keeper | keeper/sink/publisher key — **never commit/log** |
| `ROBINHOOD_FLAGSHIP_TOKEN` | after the flagship launches | flagship address; buyback idle until set |
| `ROBINHOOD_SEASON_DISTRIBUTOR` | after the distributor deploys | distributor address; publishing idle until set |
| `ROBINHOOD_SEASON_EXCLUDE` | recommended | comma-list of keeper/sink + distributor (treasury already excluded). Keeps them off the **leaderboard** (indexer reads it); payouts already exclude them. |

**Distributor deploy script** (`DeploySeasonDistributor.s.sol`, run after the flagship launches):
| Var | Purpose |
|---|---|
| `FLAGSHIP` | flagship ERC20 (immutable ctor arg) |
| `ROOT_PUBLISHER` | the keeper wallet (= `flagshipSink`) |

_(Optional on the V1 redeploy: `FLAGSHIP_SINK` on `Deploy.s.sol` points the 50% slice at the
keeper wallet at deploy time — otherwise set it later via `setFlagshipSink`.)_

**Frontend**:
| Var | Purpose |
|---|---|
| `NEXT_PUBLIC_ROBINHOOD_SEASON_DISTRIBUTOR` | distributor address; enables the Claim button |

> Reminder: after deploying the distributor, **transfer its ownership to a multisig** (Ownable2Step).

---

## 7. Reference addresses (existing infra)
- WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- Uniswap V3 SwapRouter02 `0xCaf681a66D020601342297493863E78C959E5cb2`
- Treasury `0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3`
- V3 launchpad (current, **needs redeploy**) `0x2224B9B6b7224B14cEffa2C4C4076E3321aF87a7`
- V4 launchpad (current, **needs redeploy** — flagship carve + lottery cooldown) `0x1Eb48f62c37c2455c7a0Ad4662C7cd774e19e858`

---

## 7b. Related in-progress work (changes how the flagship gets funded)

Two efforts, both **design/prototype stage, unaudited, undeployed**, that reshape the funding side:

- **V4 WETH fee hook + factory consolidation** (`docs/V4_WETH_FEE_HOOK.md`, `src/v2/v4/WethFeeHook.sol`).
  A Uniswap V4 hook charges the fee **in WETH on both buys and sells** (no token sell pressure, every
  router), replacing the LP-fee/burn model. It runs the same treasury/dev/mechanism/flagship split,
  and for **plain tokens** it folds the mechanism slice into the **flagship**. Handles all four swap
  cases incl. **exact-output**. Direction (confirmed): **consolidate onto V4** — launch plain/Base
  tokens on V4 too (`LaunchFairV4` now accepts Base when the hook is set) and **retire `V3Launchpad`**,
  one factory + one router. **Built, audited, hardened** (§4, `AUDIT_V4_HOOK.md`) + address-mining
  tooling (`script/HookMiner.sol`, `DeployWethFeeHook.s.sol`). Remaining: a dedicated on-chain fork
  test, frontend routing, V3 retirement + migration. **When this lands it becomes the flagship's
  funding path** (V1 `FeeLocker` 25/25/50 + the V4 0.1% carve are the interim model until then).
- **Stock-perps reward mode** — now **BUILT** (see §2d): a V4 reward type that hands holders a
  tokenized leveraged stock position. Independent of flagship funding, but part of the same V4 stack;
  ships once it has a production venue + audit. Spec: `docs/PERPS_REWARD_MODE.md`.

## 8. TL;DR
The entire flywheel is **coded and tested** across contracts, indexer, keeper, and frontend — the
core was **audited (3 rounds, all findings resolved)**; the later add-ons (V1 fee setter, V4 flagship
carve, V4 lottery cooldown) are tested but **pending re-audit**. **Nothing is live or committed.**
Remaining work is operational: commit → deploy the backend → redeploy V1 (security fix) → **redeploy
V4** (carve + cooldown, after re-audit) → launch the flagship → deploy the distributor (multisig owner)
→ merge the frontend perf work. Flip the switch when you're ready.
