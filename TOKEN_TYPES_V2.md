# Token types — design blueprint (Base / Reward / Increasing / Burn)

Status: **design, not yet implemented.** This is the build spec for the multi-type
token feature. It supersedes any ad-hoc discussion. Because these contracts
custody user funds and are not externally audited, we build in tested stages and
do **not** deploy to mainnet until Stage 1 has a green Foundry suite (and ideally
a review).

## Goals (from the request)

- Introduce token *modes* on top of the existing launchpad:
  - **Base** — today's LaunchToken. No change in behaviour.
  - **Reward** — holders receive a **dev-chosen external token**; fees buy it and
    distribute it pro-rata.
  - **Increasing** — fees buy back **this token** and distribute it pro-rata, so
    holders' claimable balance grows with their position.
  - **Burn** — fees buy back **this token** and burn it (deflationary).
- **Treasury always profits** (keeps its 50% WETH fee share).
- **Dev is optional** — modes work with no creator.
- API exposes, per token: the mode, and its metric (airdropped / burned / n/a).
- Stamp `hood.launchfair.app` into every token so DEX terminals attribute it.

## Hard constraints (why it can't be literal reflection)

The launchpad is **Uniswap V3**. V3 does **not** tolerate:
1. **Fee-on-transfer** — the V3 router has no fee-on-transfer path; taxed swaps
   revert / corrupt pool accounting. → We add **no transfer tax**.
2. **Rebasing balances** — auto-growing `balanceOf` changes the pool's balance
   without a transfer and breaks price invariants. → Distribution is **claimable**,
   not an auto-growing wallet balance.
3. **Swap inside a transfer hook** — buying on the pool during a transfer that is
   itself part of a swap re-enters the pool; V3's reentrancy lock reverts it. →
   Buybacks are **not per-trade**; a keeper batches them.

Net: funded by **WETH LP fees** (already collected), distributed via a **dividend
tracker** (updates shares on transfer — no amount change, V3-safe), with buybacks
performed by an off-chain **keeper** we operate.

## Fee routing (decisions locked)

WETH LP fees are collected in `FeeLocker` today and split 50/50 treasury/creator.

- **Treasury: always 50%.** Unchanged. Treasury profits on every mode.
- **Creator half (50%):**
  - **Base:** → dev; if no dev → **treasury**.
  - **Reward / Increasing / Burn:** → the **mode mechanism** (funds the buyback +
    distribution / burn). This is the whole point of the mode; the dev forgoes
    their fee to grow holders. Works with no dev.

## Architecture

```
 Uniswap V3 pool ──swap fees(WETH)──▶ FeeLocker ──claim(token)──┐
                                                                │ treasury 50%  ──▶ treasury
                                                                │ creator  50%  ──▶ per mode:
                                                                │    Base      → dev / treasury
                                                                │    Reward    → RewardVault(token)  (WETH)
                                                                │    Increasing→ RewardVault(token)  (WETH)
                                                                │    Burn      → BurnVault(token)     (WETH)
 Keeper (off-chain, ours) ──reads vaults──▶ swaps WETH on V3 ──▶ funds DividendTracker / burns
 Holders ──claim()──▶ receive reward token / bought-back token
```

### Contracts

- **`LaunchToken` (v2)** — add:
  - `TokenMode mode` (`Base|Reward|Increasing|Burn`) + `address rewardToken` (Reward only), immutable.
  - Integrate a **DividendTracker** (magnified-dividend-per-share accounting):
    `_update()` calls `tracker.setBalance(from/to)` on every transfer (no amount
    change). **Excluded from dividends:** pool, position manager, fee locker,
    launchpad, and the token itself — so only real holders accrue.
  - `withdrawableDividendOf(addr)` / `claim()` views + claim.
  - `totalDistributed`, and for Burn `totalBurned`, as public counters.
  - Stays a plain ERC20 to the pool (balances only change on real transfers).
- **`RewardVault` / distribution funding** — the creator-half WETH for a
  Reward/Increasing token is sent here; the keeper pulls it, swaps, and calls
  `distribute(token, amount)` on the tracker. For Burn, keeper swaps and burns.
- **`FeeLocker`** — `claim()` routes the creator-half per the token's mode
  (reads `LaunchToken.mode()`), instead of always paying the creator.
- **`V3Launchpad`** — `create*` accepts `mode` + `rewardToken`; validates
  (Reward requires a `rewardToken` with a WETH pool; others require none).

### Keeper (new, off-chain — runs alongside the API/indexer)

Permissionless-triggerable, but we run it:
1. Watch vault WETH balances (or run on an interval / on `FeesClaimed`).
2. Above a min threshold: swap WETH → reward token (Reward) or → this token
   (Increasing/Burn) on the V3 router with slippage guard.
3. Reward/Increasing: `tracker.distribute(bought)` → holders' claimable grows.
   Burn: `token.burn(bought)` → `totalBurned += bought`.
4. Everything a keeper does is also callable by anyone (no trust needed); the
   keeper just guarantees liveness + good pricing (batching avoids dust swaps).

## Per-mode summary

| Mode | Fee (creator half) buys | Distributed as | Metric API tracks |
|------|-------------------------|----------------|-------------------|
| Base | — | — (dev/treasury) | — |
| Reward | dev's `rewardToken` | claimable reward token | total airdropped |
| Increasing | this token | claimable this token (pro-rata) | total distributed |
| Burn | this token | burned | total burned |

## API changes (`launchfair-api`)

- Index `mode` + `rewardToken` from the `TokenLaunched` event (add fields).
- Track per-mode metric from tracker/burn events:
  - Reward → sum of distributed reward-token (airdropped).
  - Burn → `totalBurned`.
  - Increasing → total distributed (kept "as is").
- Expose on `/api/rh/token-launches` and `/api/rh/token/[address]`:
  `mode`, `rewardToken`, `airdropped`, `burned`, `distributed`, and per-user
  `claimable` (from `withdrawableDividendOf`).

## Frontend changes (`frontend-hood`)

- **Create page:** mode selector (Base default) + reward-token input (Reward).
- **Token page:** mode badge; for Reward show airdropped + your claimable + Claim;
  Burn show total burned; Increasing show distributed + your claimable + Claim.

## Domain / scraping

Fold into the same redeploy: keep stamping `platformWebsite = hood.launchfair.app`
(already done) and surface it in `contractURI()` `external_link` (already done);
additionally expose a top-level `website()`/`url()` the common terminals read, so
tokens are attributed to the site on-chain without off-chain submission.

## Build stages

1. **Contracts + Foundry tests** — modes, dividend tracker, fee routing, keeper
   entrypoints. Test both token/WETH orderings; test pool/router exclusion; test
   treasury always paid. *No deploy until green.*
2. **Keeper** — standalone service (like `noxa-listener`), swaps + distributes.
3. **API** — index modes + metrics, expose fields + claimable.
4. **Frontend** — create-mode UI + token-page rewards/claim.
5. **Deploy + verify** new launchpad; migrate defaults; (ideally) external review.
