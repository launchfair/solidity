# LaunchFair — The Full Picture

*What we're building, how the money flows, and where everything stands.*
*Last updated: 2026-08-13 · Test stack live on Robinhood Chain*

---

## 1. The one-paragraph version

LaunchFair is a token launchpad on Robinhood Chain where **every token launched pays a small fee on
every trade, and a slice of every one of those fees flows into one shared pot**. That pot funds the
platform's own **Core token** — first by bankrolling its launch (a "seeded TGE" that starts it at a
real market cap instead of zero), then by **buying it back forever** after launch. Users earn
**points** for trading volume, social quests, and group participation, and each weekly **season**
they claim a share of the bought-back Core token through an on-chain Merkle claim. The result is a
flywheel: more launches → more trading → more fees → more Core buybacks + bigger season rewards →
more reasons to trade here. Everything — every fee, split, destination, and season — is controlled
from an on-chain admin dashboard, so nothing can ever get stuck on a misconfiguration.

---

## 2. The playing field: Robinhood Chain

- **Arbitrum-Nitro EVM L2, chain ID 4663, gas token is ETH.** Everything is standard EVM tooling;
  Uniswap V3 (and V4 for our mode tokens) is deployed on it.
- Robinhood also issues **tokenized stocks** on this chain (NVDA, AAPL, COIN, SPY…) with real V3
  liquidity — which is what makes our stock-paired token type possible. Deep stock liquidity is
  mostly quoted in **USDG** (a 6-decimal dollar stable); a fat WETH/USDG 0.01% pool (~$4M+) bridges
  the two worlds.
- The chain recently gained **BLS12-381 precompiles (EIP-2537)**, which unblocks trustless drand
  randomness for the lottery mode later — today the lottery uses prevrandao-style entropy with the
  hardening from our audit.

---

## 3. What you can launch — the four token families

### a) Curve tokens (V1/V3 — the legacy stack)
The classic pump-style flow: buy on a bonding curve, and when the curve fills, liquidity migrates
into a real Uniswap V3 pool. The LP position is held by a **FeeLocker** that collects the pool's
trading fees and splits them between treasury, the token's creator, and the flagship pot. This stack
still runs, but new development is on V4; its locker is due one final redeploy (see §12).

### b) Mode tokens (V4 — the current engine)
Tokens launch straight into a **Uniswap V4 single-sided pool** — no curve phase. What makes them
special is the **mode**: a share of the trading fee is recycled into a holder mechanism, picked at
launch:

- **Base** — plain token. The mechanism share simply folds into the flagship pot instead.
- **Reward** — the mechanism share market-buys a *reward token* (any V3-tradeable asset — including
  a tokenized stock like NVDA) and streams it to holders. "Hold my memecoin, get paid in NVDA."
- **Redistribute** ("Increasing") — the mechanism share buys the token itself back and
  redistributes it to holders, so balances tick up over time.
- **Lottery** — the mechanism share accumulates as a pot and a random holder wins it. Hardened
  after our audit: round-grinding fixed, winner cooldown with re-draw to the next eligible holder.
- **Perps** — *built and audited but sunset in the UI* ("coming soon"). Fees would open a real
  leveraged position and holders receive a fungible position token redeemable at NAV. It's parked
  because the reference venue needs a production-grade equity oracle before it's safe to offer.

Fees on mode tokens are taken **in WETH on both legs** by our custom hook (no sell pressure on the
token itself), at a tier the creator picks: **3%, 5%, or 10%**.

### c) Stock-paired tokens
The headline novelty: a token whose **pool is quoted in a tokenized stock** instead of WETH. Launch
"DOGE-but-it-trades-against-NVDA." The user experience stays pure ETH — you pay ETH, you receive
ETH — because the gated **StockPairRouter** does the conversion legs atomically:

- **Buy:** ETH → WETH → (USDG if needed) → stock → token, one transaction.
- **Sell:** token → stock → (USDG) → WETH → ETH, one transaction.

**20 stocks are live as quote options** (COIN, SPY, MSTR, META directly against WETH; NVDA, TSLA,
AAPL, MSFT, GOOGL, AMZN, PLTR, AMD, NFLX, GME, QQQ, COST, INTC, MU, USO, SPCX via multi-hop USDG
routes). The routes are **enforced by the contract** (owner-set, path-validated), not by the
frontend, so nobody can be routed through a bad pool.

The **1% fee is charged inside the pool** by the `StockFeeHook` (on the stock leg, all four swap
cases) — which means the pools are **open**: any terminal, aggregator, or router can buy and sell
stock-paired tokens (no "TradeRestriction" flags on scanners), and the fee still can't be bypassed
because it's taken at the pool layer, not the router. Our router remains the ETH-in/ETH-out
convenience path and itself charges nothing. Fees accrue in the stock and a keeper call converts
them to WETH along the router's own routes, then splits to treasury / creator / flagship in ETH.

### d) The Core token (one-of-one)
Not launched through the launchpad at all — it gets its own bespoke contract and lifecycle. Full
story in §5.

---

## 4. Where every fee goes — the money map

Every family pays fees in **ETH/WETH** (never in the token — no reflection-style sell pressure),
and every split below is a **live dashboard knob**, not a constant:

| Family | Fee | Default split | Settable via |
|---|---|---|---|
| Curve (V1/V3) | pool trading fee | 25% treasury / 25% creator / 50% flagship | `setFeeShares` — **pending the V1 locker redeploy** |
| Mode (V4) 3% tier | 3% of trade, in WETH | 16.67% treasury / 16.67% dev / 66.67% mechanism | per-tier `setSideBps` (Fees tab) |
| Mode (V4) 5% tier | 5% | 15% / 15% / 70% | same |
| Mode (V4) 10% tier | 10% | 10% / 10% / 80% | same |
| Mode (V4), all tiers | flat **0.1% of trade** carved from the dev slice | → flagship pot | `setFlagshipTradeBps` |
| Stock-paired | 1% of trade, charged **in-pool** by the StockFeeHook (stock leg) | 25% treasury / 25% creator-dev / 40% mechanism / 10% flagship | `setFeeBps` / `setSplit` / `setDestinations` on the hook |
| Core token pool | 1% Uniswap pool fee | dev cut (default 10%, settable 0–100%) / rest auto-compounds into the locked LP | `setDevFeeConfig` |
| Verified external tokens | 0.5% swap fee in WETH | → treasury | env/constant |

Two structural points worth understanding:

1. **The "mechanism" share is what powers each token's gimmick** (rewards, redistribution,
   lottery pot). For Base tokens with no gimmick, it folds into the flagship pot — plain tokens are
   the flywheel's best fuel.
2. **The flagship slice from every family converges on one address** (the flagship sink). Right
   now that sink is the CoreTGE war chest; after the Core token launches it gets repointed to the
   buyback keeper. Repointing is a dashboard action on both the V4 locker and the stock router.

---

## 5. The Core token and the flywheel (the centerpiece)

### Why "seeded TGE" instead of launching day one

The original plan was to launch the Core token immediately and let buybacks accumulate value into
it. We changed course (settled with Ryan): **don't launch at zero.** Instead, let the Genesis
period run first — every trade on the platform drips ETH into a war chest — and only launch the
Core token once that chest is fat. The entire chest becomes the launch liquidity, so the token
**starts at a real market cap** with deep, locked liquidity instead of a thin pool that early
snipers can farm. If organic accumulation is too slow, we can also **seed the chest manually**
(`seed()` — just send ETH).

### The contract: CoreTGE

One contract runs the whole lifecycle — `CoreTGE.sol`, live at
`0x8A91b039b1777F05b70665f8362589505505d6dc` (v5).

**Phase 1 — Accumulate.** Both flagship sinks (V4 fee locker + stock router) point at the TGE, so
it passively collects ETH from every trade on the platform. `withdrawEth` exists as an owner escape
hatch (that's how we migrated the pot from v2 to v3 without losing a wei).

**Phase 2 — Launch (one shot, irreversible).** The owner calls `launch(name, symbol, supply)` from
the dashboard. In a single transaction it:

1. Deploys the token **through the platform's own token factory** (`TokenDeployerV2` — the same
   contract that creates every launchpad token, so explorers and aggregators like Codex see the
   same on-chain creator and verified bytecode and index it as one of ours). It launches in Base
   mode with the launch limits off, which makes it behave as a **plain fixed-supply ERC-20**: no
   reflection, no tax hook, exchange-friendly, 100% supply visible at birth, owner reads renounced.
2. Splits the supply into buckets. The split is a **live dashboard knob right up until launch**
   (`setAllocation`, must sum to 100%, LP > 0) — whatever is set at the moment of launch freezes
   forever. **The Genesis split is 90% LP / 10% Team** (claims and community buckets zeroed):
   - **90% LP** — the launch liquidity. Nearly the whole supply is genuinely in the pool: real
     float, deep liquidity, nothing overhanging the market from reserve buckets.
   - **10% Team** — the only held allocation.
   - Claims/community buckets exist in the contract but are set to 0: **season rewards are
     buyback-funded** — the keeper buys core off the pool with fee ETH and funds each weekly
     Merkle pot with the bought tokens, so rewards scale with real revenue instead of a
     pre-minted reserve.
3. Deposits the LP bucket **together with the entire ETH war chest** into a **full-range Uniswap
   V3 position at the 1% fee tier** — ETH on one side, the LP tokens on the other. That's what
   "paired" means: the LP slice is the token half of the liquidity pair. Starting price = pot ÷
   LP tokens, which makes the LP share the **FDV multiplier**: fully-diluted mcap = pot ÷
   LP-share. At 90% LP the launch FDV ≈ 1.11× the pot — a modest headline number, but an honest
   one, since the float is real rather than optical.
4. **Locks that LP NFT in the contract forever.** There is *no function to withdraw the position* —
   not even for the owner. The liquidity cannot be pulled. This is the anti-rug guarantee, verifiable
   on-chain by anyone.

**Phase 3 — Life after launch.**

- **Season funding (Season 1 onward — separate economics from the Genesis launch split):**
  seasons are funded by the **buyback keeper** (fee ETH → buy core on the pool → bought tokens
  into the Merkle pot). Each season's batch is divided by **live, admin-editable knobs** in the
  Seasons tab: the **team cut** (`seasonDevBps`, default 10%, hard-capped at 20%, carved first
  and idempotently by the keeper) and the distribute / burn / trail-forward split of the rest.
  Change them between seasons at will — the one-time Genesis 90/10 supply split has nothing to
  do with these. The on-chain `fundClaims(amount)` tranche path (with its own 20%-capped skim)
  still exists but is dormant while the Claims bucket is 0.
- **Team / Community:** `claimTeam` / `claimCommunity` pay out to any address, strictly bounded by
  the remaining bucket balance. Purely admin functions, driven from the dashboard.
- **Pool fees:** the locked position earns the 1% pool fee on every Core trade forever.
  `collectPoolFees()` collects it, sends `poolDevFeeBps` (default **10%**, settable **0–100%** —
  "10% of the 1%" or "the whole 1%", your call at any time) to the dev wallet, and **compounds the
  entire remainder back into the locked position** via `increaseLiquidity`. The pool only ever
  deepens; fee income never sits idle.
- **The buyback loop:** after launch, the flagship sinks get repointed from the TGE to the keeper,
  which sweeps the ETH and **market-buys the Core token on its own locked pool**. Constant,
  protocol-funded buy pressure — and the bought tokens feed the weekly season pot. Even if the pool
  dev cut is set to 100%, the flywheel keeps buying; compounding is a bonus, not a dependency.

### The flywheel, end to end

```
every token's trades ──fees──▶ flagship sink ──▶ keeper buys CORE on the locked pool
                                                       │                    │
                                                 buy pressure         season pot
                                                       │                    │
users trade more ◀── weekly Merkle claims ◀── points share ◀────────────────┘
```

---

## 6. Seasons, points, and rewards

- **Points = trading volume.** 1 WETH of volume = **1,000,000 points** (scaled so small traders
  see real numbers, not zeros). All non-external trades on both stacks count.
- **Pre-Genesis accumulates.** Until the admin presses *Start Genesis*, every weekly epoch's points
  pile up into one running total — nothing resets, nothing distributes. The moment Genesis starts,
  that accumulated history seeds Season 1.
- **Boosts and extras:** group membership gives **+5%**; admins can grant point adjustments to a
  wallet or a whole group (with a note, audit-trailed); **X quests** award extra points
  automatically (see §7).
- **Live projection:** the points page shows each user their points, their share percentage, and a
  **projected token payout** against the admin-set season pot — no more guessing what a point is
  worth.
- **Settlement:** each season closes into a **Merkle root** published on-chain to the
  `SeasonMerkleDistributor`; users claim their Core tokens themselves (non-custodial), with an
  admin-recoverable design (rescue to treasury only, unclaimed rolls forward, bad root overridable
  before any claim).
- **Honest UI:** the season banner only says "live" when Genesis has actually started; before that
  it truthfully shows the accumulation state.

---

## 7. The social layer

- **Groups:** real DB-backed groups (≤50 members), **server-enforced members-only chat**, and a full
  **invite lifecycle** (create / list / accept / decline / revoke). Membership is proven by wallet
  signature; the +5% points boost applies automatically.
- **X (Twitter) linking:** users connect their X account via OAuth 2 (the partner's cookie-sealed
  flow, wallet-signature-bound so an attacker can't link *their* X to *your* wallet). Tokens are
  stored server-side with `offline.access` refresh.
- **X quests:** admin-defined quests ("post about $CORE", "mention @launchfair") pattern-match
  against linked users' recent posts via a scanner that reads with each **user's own token** (the
  only auth X allows for tweet reads at our tier). Matches mint quest completions → point
  adjustments, idempotently. Users who linked before token storage shipped need to relink once.

---

## 8. The trading experience

- **Instant wallet:** a locally-generated hot wallet (key in the browser, exportable/importable for
  recovery) that signs without extension popups — trades feel instant. Audited: the trust model is
  "small hot balance you top up", key never leaves the device, funds isolated from your main
  wallet. Every admin/create flow has an explicit **signer toggle** (injected vs instant) — no
  silent fallback to the instant wallet anymore.
- **Speed work that made 1-second trades real:** receipt polling dropped from viem's 4 s default to
  **400 ms** everywhere; RPC calls go through our own proxy (~50 ms vs ~290 ms public); the
  live-candle WebSocket pushes trades in ~1 s from block inclusion.
- **Quotes are contract-truth:** stock-pair buy/sell quotes come from `simulateContract` against
  the actual router path — what you see is what the chain will do, including the multi-hop USDG
  legs.

---

## 9. The admin dashboard (`/admin`)

Wallet-gated (allowlisted admin wallets, EVM signature auth). The design rule after one too many
close calls: **anything that can be misconfigured must be re-configurable from here.**

- **Fees tab:** stock router fee + 4-way split + destinations (treasury & sink); V4 per-tier
  side-shares (3/5/10% tiers); flagship trade carve; V4 locker flagship sink. Live view of the ETH
  accumulated at the sink. Curve-token setters appear after the V1 locker redeploy (noted in-UI).
- **Core Token tab:** war chest balance, manual seed, the one-shot **launch** form with live
  starting-price/market-cap projection, bucket balances, claims tranche funding (skim shown
  inline), team/community payouts, **Collect & compound** button, and the dev-fee config form
  (recipient, season bps, pool bps).
- **Seasons tab:** Start Genesis, season length, end/hold/extend, distribute/burn split, claim
  window, season pot size (drives user projections).
- **Groups / Points tabs:** group admin, per-wallet and per-group point grants, quest management.

---

## 10. The machinery behind it

- **API + indexer** (`launchfair-api`): indexes V3 trades from the launchpad and **V4 trades from
  the PoolManager swap stream** (catches everything, router-agnostic). Stock-paired launches carry a
  `quoteKind`, and a **price oracle chain** converts stock-quoted prices to WETH terms (router path
  → chained V3 `slot0` reads, decimals-aware, USDG 6dp) so charts and market caps are always in the
  same unit. Token lists are served from **precomputed TokenStats** (a recompute loop), and the
  heavy pages are SSR'd — the home page doesn't hammer the chain.
- **WebSocket fanout:** a master push server ingests indexer events (shared-secret authenticated —
  fail-closed, so an unset secret rejects everything rather than accepting anything) and fans out
  to worker sockets the frontend subscribes to for live candles/trades.
- **Frontend** (`frontend-hood`, branch `hood-ui-overhaulv2`): Next.js; all number formatting
  locale-pinned (a Hungarian-locale hydration bug taught us that lesson); stock logos self-hosted.

---

## 11. Security work already done

- **Internal audit (AUDIT.md):** fixed a Critical lottery round-grinding vector plus a batch of
  lower-severity issues. The V1 stack's WETH-drain fix is written and awaits the redeploy.
- **V4 WETH fee hook:** 4 independent audit passes; no Critical/High; the shared ERC-6909 claim
  pool proven non-drainable; hardened with fee caps, `Ownable2Step`, permission validation.
- **Perps mode:** 3 adversarial passes; H-1/H-2/H-3 + M-1 fixed; stays sunset pending a production
  oracle venue.
- **Season distributor:** two audit rounds (3H/6M/4L → all fixed → only Lows → fixed). Atomic
  fund-and-publish, claim caps, rescue-to-treasury-only.
- **Instant wallet:** threat-modeled (XSS exfiltration, key at rest, phishing); trust model
  documented; recovery via key export/import verified end-to-end.
- **CoreTGE invariants:** launch is once-only; LP is unwithdrawable; buckets are hard-bounded;
  `withdrawToken` can only touch *surplus* above the bucket obligations; the season skim is
  hard-capped at 20% in bytecode.
- **StockFeeHook:** a direct fork of the audited WethFeeHook fee machinery (same four-case
  delta accounting, same claim mechanics) with the quote side cached per pool so an allow-list
  change can never switch fees off; distribution is keeper-gated with a min-out so the
  stock→WETH conversion can't be sandwiched. 194 contract tests green across the suite.

---

## 12. Current state — what's live (test stack)

| Contract | Address |
|---|---|
| CoreTGE (war chest + factory launcher, LAUNCHED) | `0x4b797B3258f2412494254714c421A80cB49684d0` |
| **FCORE core token** (factory-deployed, locked LP `682103`, launch-price FLOOR active) | `0xc9843e2ff8Cf6Cc74ef0EAA96EA9E2016772fDdf` |
| **FlagshipBuyback vault** (contract-held buybacks, all sinks point here) | `0xedc336402D985B3FD7116E443d7C2c280CbCEa94` |
| SeasonMerkleDistributor (rootPublisher = the vault) | `0x60F3c300C208c5bF26F6e722f6d5Aa4D37fC35B2` |
| LaunchFair V4 launchpad (guarded stack: 1%/60s launch window, per-quote launch prices) | `0xbb872Eb5Fc3F10B45df627caBc6B7d8aD000185B` |
| TokenDeployerV2 (token factory gen-2: time-based launch guard) | `0x3CeCC9A0329FDE96d9563a96b4bA131A115b1Dd7` |
| V4 FeeLocker | `0xa67c2deDC1A84b5a190825d1c028E1F9c11e4861` |
| V4 Distributor (modes engine) | `0x47F18ac5F59F89ff304C5728Fc20d2729189dCe7` |
| VRF Coordinator (drand) | `0x6166d96AC6abDD5c57a5a7D746c2932202232F55` |
| V4 SwapRouter (stateless, reused) | `0x0e6c53664388B68F6b41851D224248F391CC8947` |
| StockPairRouter (20 quotes, LIVE-priced ~$2.5k launches, fee 0) | `0x6D39EA3819575DbeDAf926B3860B66A00E8DC578` |
| StockFeeHook (in-pool 1% stock fee, open pools) | `0x40EDAa62C8593B32957FcbC21DDb600E876680CC` |
| V1/V3 FeeLocker (legacy, pre-fix) | `0x749f23a5616a473f4d43dafcce8a7214c986849b` |

**Vault-mode flywheel (2026-08-13 night), verified live:** the flagship sink is now the
**FlagshipBuyback CONTRACT** — fee ETH accumulates in the vault, `buyback()` (deployer-only,
argumentless, self-quoted slippage floor) buys core the vault itself holds, the season team cut
is carved by `withdrawToken`, and `publishSeason` funds the Merkle distributor straight from the
vault: bought core never touches an EOA, and the cron key custodies nothing. Stock-paired
launches now start at **~$2.5k mcap** via live-priced per-quote launch prices
(`setAllowedQuotePrice`, owner-retunable). Full cycle proven on-chain: contract buybacks →
vault-carved 10% team cut → vault-published season → user Merkle claim.

**Earlier ground-up E2E (same day), on the previous stack:** clean DB + fresh stack;
five imaged demo tokens (Reward/Redistribute/Lottery/2×stock-paired); six funded mimic wallets
traded both directions; **real sniper bots (160 wallets, ~937 buys in 4 minutes) traded GCHIP
through its open pool from external routers**, paying 0.34 NVDA of in-pool fees; those fees were
converted and (with a manual seed) formed a **0.0224 ETH war chest** that launched FCORE through
the factory (90% LP locked, 10% team); sinks repointed to the keeper; a season settled through the
keeper with the **10% team cut carved**; a mimic wallet **claimed 540k FCORE on-chain** via the
API-served Merkle proof; the tester wallet holds 7.67M CROCK for external-terminal testing.
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| USDG (stock-route bridge) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Uniswap V3 SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Position Manager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| Treasury | `0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3` |

Verified working end-to-end locally: every launch type from the UI (curve, all V4 modes, stock-
paired direct + USDG-routed), trading with live quotes on all of them, indexing + charts + holders +
volume, 1-second live candles, groups/invites/chat, X linking + quests, season points with
projections, and the TGE war chest **actually accumulating ETH from real trades** (the stock
router's distribute() delivering to the sink was confirmed on-chain, and the pot survived the
v4→v5 migration intact). The open-pool stock model was smoke-tested live on 2026-08-13: launch →
ETH buy/sell → in-pool fee accrual (in COIN) → convert + 4-way ETH split, with the war chest
receiving exactly its 50%.

---

## 13. What's left before the real launch

1. **Genesis settlement keeper** — sum the accumulated pre-Genesis epochs into the Season-1 pot and
   publish the first Merkle root. Must land before *Start Genesis* is pressed in production. With
   the 90/10 split it must also **carve the team's 10% season cut from each bought-back batch**
   before funding the pot (the on-chain `fundClaims` skim is dormant at Claims = 0).
2. **SeasonMerkleDistributor deploy** — can only happen *after* the Core token exists (the token
   address is an immutable constructor argument), then `setClaimsDistributor` on the TGE.
3. **V1 FeeLocker redeploy** — ships the WETH-drain fix + `setFeeShares`, which also lights up the
   curve-token fee controls in the dashboard.
4. **Post-TGE sink repoint** — flip both flagship sinks from the TGE to the buyback keeper
   (dashboard action, §5).
5. **Production rollout checklist** — updated indexer + envs on the servers (the new stack
   addresses, `ROBINHOOD_CORE_TGE` so the core token indexes at launch, and the WS push secret —
   remember it fails *closed*), frontend RPC pointed at the API proxy, X callback URLs registered
   in the X developer portal, shared API secret on both servers, X quest scanner running on a
   schedule, and previously-linked X users relinking once.
6. **Later / optional:** Perps mode production venue + oracle (then un-sunset the UI), trustless
   drand lottery via the new BLS precompiles.
