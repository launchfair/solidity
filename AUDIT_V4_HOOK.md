# Security Audit — V4 WETH Fee Hook + recent stack changes

**Date:** 2026-08-03
**Scope:** the new `WethFeeHook` and every contract change made since the flagship-flywheel
audit (V4 launchpad hook wiring + Base-on-V4, V4 fee-locker flagship carve, lottery winner
cooldown, V1 `FeeLocker` settable fee shares).
**Status:** pre-deployment. Nothing in scope is live yet.
**Method:** four independent adversarial review passes (hook delta-accounting/liveness; hook
economic/drain; V4 launchpad/locker/lottery changes; V1 locker + cross-cutting), each reading
the source and the tests directly, several cross-checking against the vendored `lib/v4-core`
internals and running throwaway Foundry tests. Every finding below was then re-verified by hand
against the code — misreads from the review passes were dropped (noted at the end).

## Files in scope

| File | Change audited |
|---|---|
| `src/v2/v4/WethFeeHook.sol` | **new** — fee in WETH on both legs, ERC-6909 claims |
| `src/v2/v4/LaunchFairV4.sol` | `setFeeHook`, pool-fee-0-when-hook, Base-on-V4 gate |
| `src/v2/v4/LaunchFairV4FeeLocker.sol` | flat flagship carve from the dev slice |
| `src/v2/v4/LaunchFairV4Distributor.sol` | repeat-winner cooldown |
| `src/v1/FeeLocker.sol` | owner-tunable 25/25/50 split + `flagshipSink` |
| `src/flywheel/SeasonMerkleDistributor.sol` | regression re-check only |

---

## Verdict

**No Critical or High findings.** The novel and highest-risk piece — a single shared ERC-6909
WETH claim pool drawn against by a per-token `distribute()` — is **correct and non-drainable**,
and the hook's Uniswap-V4 delta accounting is **correct in all four swap cases** (buy/sell ×
both currency orderings), verified empirically. A hook gets exactly one shot to be wrong here
(a bad delta sign or magnitude bricks every swap on the pool, or leaks funds); it is not wrong.

The one item worth acting on before the fee is relied upon for revenue is **M-1 (exact-output
swaps pay zero fee)** — a complete, costless bypass, though not a fund-loss or brick. Everything
else is Low / defense-in-depth.

## Severity summary

| # | Severity | Finding | Location |
|---|---|---|---|
| M-1 | Medium | Exact-output swaps are 100% fee-exempt (complete bypass) | `WethFeeHook.sol:126,150` |
| M-2 | Medium | V1 `setFeeShares` is retroactive — owner can divert already-accrued creator fees | `v1/FeeLocker.sol:119,166` |
| L-1 | Low | `setFeeBps`/constructor unbounded — `feeBps ≥ 100%` bricks swaps | `WethFeeHook.sol:86,92` |
| L-2 | Low | Hook permission bits not validated at deploy — a mis-mined hook bricks sells at first swap | `WethFeeHook.sol:86`, `LaunchFairV4.sol:443` |
| L-3 | Low | Price-limited partial-fill exact-input over-charges the buy fee | `WethFeeHook.sol:129` |
| L-4 | Low | V4 locker `claim()` reverts on a fee-0 hook pool if `donate()`-griefed (latent `/p.key.fee`) | `LaunchFairV4FeeLocker.sol:182,191` |
| L-5 | Low | Lottery cooldown is address-keyed → wallet-rotation bypass; void-to-MISS degrades liveness | `Distributor.sol:594-623` |
| L-6 | Low | Hook mechanism `notify` can self-strand a malicious token's own fees | `WethFeeHook.sol:206` |
| L-7 | Low | V1 `claimMany` is all-or-nothing — one idle token reverts the batch | `v1/FeeLocker.sol:182` |
| L-8 | Low | `Ownable` (lockers) vs `Ownable2Step` (distributor) inconsistency | multiple |

---

## Findings

### M-1 — Exact-output swaps are 100% fee-exempt (complete, costless bypass)
**Medium.** `WethFeeHook.sol:126` and `:150` both gate the fee on `params.amountSpecified < 0`
(exact-input). On an exact-**output** swap the hook returns `ZERO_DELTA`/`int128(0)`, and because
the wired pool runs with LP fee = 0 (`LaunchFairV4.sol:332`), the trade pays **nothing**.

*Scenario:* any router/aggregator/MEV bot that supports exact-output (most do) routes every buy
("give me exactly N tokens") and sell ("give me exactly M WETH") as exact-output and pays zero
fee. This directly defeats the hook's stated goal — "fee on every swap regardless of router."
Verified to be a **clean skip, not a revert/brick** (exact-output swaps succeed with `accrued==0`).
The platform's own exact-input frontend still pays, so this is a revenue leak, not theft — hence
Medium, but it is a *complete* bypass and should not be in any revenue projection until closed.

*Fix:* implement the exact-output legs. On exact-output, when the **output** (unspecified) is WETH,
charge via a positive `deltaUnspecified` in `beforeSwap` + `mint`; when the **input** currency is
WETH, skim from input in `afterSwap`. If deferred, gate exact-output off (revert) so "fee on every
swap" isn't silently false — but implementing the fee is preferable (reverting breaks aggregators
that probe with exact-output). Add exact-output tests either way (see coverage gaps).

### M-2 — V1 `setFeeShares` applies retroactively to already-accrued fees
**Medium (trust lever).** `v1/FeeLocker.sol:119` lets the owner retune the 25/25/50 split; `claim()`
(`:166`) splits the **current** collected balance by the **current** shares — there is no
per-position snapshot of what accrued under the old shares, and `claim` is permissionless so the
owner can front-run it.

*Scenario:* a token trades for weeks; ~X WETH of buy-fees have accrued that "belong" to the creator
at the advertised 25% dev share. Before anyone claims, the owner calls `setFeeShares(7500, 0, 2500)`
(valid — sums to 10000); the next `claim` pays the creator **0** and routes their entire accrued
slice elsewhere, then resets. The "25% to creators" is therefore a *revocable* promise gated on
trusting the owner. This is internally consistent with the project's admin-trusted model (the code
comment discloses "applies to every claim after this call"), so it is **acceptable/known** if the
owner is fully trusted — but for a contract that markets a creator revenue share it should be
constrained or disclosed prominently.

*Fix (decreasing strength):* (a) snapshot/settle fees per position at each rate change (forward-only —
most correct); (b) enforce a floor `require(devBps >= MIN_DEV_BPS)` so the creator slice can never be
zeroed; (c) put `setFeeShares` behind a timelock. At minimum, document as a trusted-owner power.

### L-1 — Unbounded `feeBps` bricks swaps if set ≥ 100%
**Low (owner footgun).** `setFeeBps(uint16)` (`:92`) and the constructor (`:86`) accept any value. With
`feeBps ≥ BPS` (10000), the buy fee ≥ input → `amountToSwap = amountSpecified + fee ≥ 0` trips
v4-core's `HookDeltaExceedsSwapAmount` → **every buy reverts**; sells charge more WETH than the swap
produced. Owner-only, but unrecoverable while mis-set. *Fix:* `require(bps <= MAX_FEE_BPS)` (e.g. 1000 = 10%).

### L-2 — Hook permission bits not validated at deploy
**Low (deployment discipline).** Neither the hook constructor nor `LaunchFairV4.setFeeHook` validates
that the hook address encodes exactly `beforeSwap|afterSwap|beforeSwapReturnDelta|afterSwapReturnDelta`.
`PoolManager.initialize` rejects a *returns-delta flag without its base flag* but **not** the reverse:
a hook mined with `AFTER_SWAP` set but `AFTER_SWAP_RETURNS_DELTA` unset passes initialization, then on
the first sell `afterSwap` mints a `−fee` WETH delta whose `+fee` return is discarded →
`CurrencyNotSettled` → **every sell reverts**, caught only at first swap. *Fix:* call
`Hooks.validateHookPermissions(this, Permissions({...}))` in the constructor (fails fast at CREATE2
deploy); optionally re-check the low 14 bits in `setFeeHook`.

### L-3 — Partial-fill exact-input over-charges the buy fee
**Low (user overpay edge case; no protocol loss/brick).** The buy fee is computed on the full specified
input and minted in `beforeSwap` (`:129`) *before* the swap runs. If the swap only partially fills
(hits `sqrtPriceLimitX96`), the pool consumes less than `input − fee` yet the caller still pays the fee
on the full requested input, so the effective rate exceeds `feeBps`. Cannot brick (v4-core guarantees
`fee < input`) and cannot lose protocol funds; only penalizes traders who set tight price limits with
exact-input (rare — most routers pass full-fill limits). *Fix:* acceptable to document; to be exact,
move buy-fee assessment to `afterSwap` on the actual consumed input (at the cost of the first-buy
`mint`-in-`beforeSwap` design). Documenting is reasonable.

### L-4 — V4 locker `claim()` reverts on a fee-0 hook pool if donated to
**Low (attacker-funded griefing; not reachable with real fees).** A hook-launched token's pool has LP
fee 0, so its locked position accrues **zero** LP fees and `claim()` is an inert no-op — the flagship
carve at `LaunchFairV4FeeLocker.sol:191` (`… / p.key.fee`) is never reached because the `wethFees > 0`
block is skipped. The **only** way to make `wethFees > 0` on a fee-0 position is for someone to
`poolManager.donate()` to the pool; `claim()` then calls `splitOf(0, …)` which reverts `UnsupportedFee`
(`FeeSplitConfig.sol:64`) one line *before* the division — so the donated WETH is stuck and `claim`
for that token reverts forever. No legitimate fee is ever at risk (hook tokens' fees flow through the
hook, not the locker). *Fix (defense-in-depth):* short-circuit the locker for fee-0 positions — sweep
any stray WETH to treasury instead of splitting — which also removes the latent `/p.key.fee` divide
entirely:
```solidity
if (!isSupportedFee(p.key.fee)) { if (wethFees > 0) weth.safeTransfer(treasury, wethFees); }
else { …existing split + carve… }
```

### L-5 — Lottery repeat-winner cooldown is address-keyed and bypassable
**Low (design limitation of a new feature).** The cooldown is keyed by `(token, winner-address)`
(`Distributor.sol:149,594`) and the winner is chosen by **balance weight at the commit snapshot**. A
winner keeps their exact win-probability by moving their whole balance to a fresh wallet before the
next `commitDraw` — the fresh wallet has `lastWinAt == 0`, never on cooldown — so the "blacklisted for
an hour" guarantee is a soft deterrent, cheaply bypassed (one transfer per interval). Separately, when
a whale that owns most of the supply *is* re-selected while cooling, the draw **voids to MISS and rolls
the pot over** (`:595-604`), so during each cooldown window the lottery mostly denies payouts to
everyone until the whale is eligible again — arguably worse for minority holders than no cooldown.
(The pot is never lost, and the whale cannot *force* draws — only `drawOperator` commits.) *Fix:*
either (a) accept and document it as a wallet-scoped soft feature, do not rely on it for fairness; or
(b) instead of voiding, re-derive the winner by advancing the winning ticket past the cooling holder's
range into the remaining set — another holder actually wins, removing the minority-holder denial while
preserving the anti-grinding guarantee (winner derivation stays deterministic from the same beacon).

### L-6 — Hook mechanism `notify` can self-strand a malicious token's own fees
**Low (self-grief only).** In `_split`, a token whose `mode()` returns non-zero routes its mechanism
slice through `distributor.notify(token, …)` (`:206-208`). A crafted token that forces that path and
makes `notify` revert would make its own `distribute(token)` revert — confined to *that* token (whose
fees the attacker paid), no cross-token or platform brick. *Fix (optional):* wrap `notify` in
try/catch and fall back to flagship on failure, mirroring `_hasMechanism`'s fail-safe.

### L-7 — V1 `claimMany` is all-or-nothing
**Low (keeper UX/DoS).** `claim()` reverts `NothingToClaim` for a zero-fee token; `claimMany` loops raw
`claim` calls (`v1/FeeLocker.sol:182`), so a single idle token in the batch reverts the whole tx. *Fix:*
wrap each iteration in try/continue, or skip tokens whose collect returns 0.

### L-8 — `Ownable` vs `Ownable2Step` inconsistency
**Low.** Both fee lockers use single-step `Ownable`; `SeasonMerkleDistributor` uses `Ownable2Step`. The
locker owner is highly privileged (redirects treasury WETH, sets sinks/shares); a fat-fingered
`transferOwnership` is unrecoverable single-step. *Fix:* switch the lockers to `Ownable2Step`.

---

## Verified correct (checked and cleared)

- **Hook delta accounting — correct in all four cases** (buy/sell × both `(token,weth)` orderings),
  verified by reasoning against `Hooks.beforeSwap`/`afterSwap` and empirically (no `CurrencyNotSettled`,
  exact accrual, real WETH pulled in `distribute`). The `amountSpecified<0 == zeroForOne` branch routes
  the specified/unspecified halves to the correct currency for both orderings.
- **Shared 6909 claim pool — non-drainable.** Invariant `hook WETH-6909 balance == Σ accrued[token] ==
  redeemable WETH` holds by construction: every `mint(fee)` is paired with `accrued += fee`; `distribute`
  zeroes `accrued[token]` before burning exactly that much. A WETH claim can only be minted while the
  hook is credited **in WETH** (return-delta currency always equals the minted currency), and v4-core's
  `CurrencyNotSettled` forces the swapper to actually deposit that WETH — so no unbacked claims, no
  cross-token drain, no pool-spoofing via a fake WETH.
- **Reentrancy — safe.** `distribute` zeroes state before `unlock`; a re-entrant `distribute` returns 0
  or trips `AlreadyUnlocked`; `unlockCallback` is `poolManager`-only; `mode()` is a `view` STATICCALL
  wrapped in try/catch.
- **int128 truncation — not reachable.** `int128(int256(fee))` is only hit after `poolManager.mint(fee)`,
  which routes through `SafeCast.toInt128` and reverts for `fee ≥ 2^127`; real WETH amounts are ≪ that.
- **Rounding — drain-safe.** Both legs guard `fee > 0`; the split's mechanism slice is the exact
  remainder, so slices sum to the whole with no stranded dust; every slice falls back to `treasury`.
- **Flagship carve math — correct.** `wethFees·bps·100/poolFee` is the algebraically correct flat
  bps-of-trade conversion; overflow-safe (`≤ ~2.2e45 ≪ 2^256`); capped at the dev slice; treasury and
  mechanism provably untouched; rounds in the protocol's favor.
- **`setFeeHook` — sound.** Owner-only; the hook is captured into each token's immutable `PoolKey` at
  launch, so changing it never affects already-launched pools; pre-hook tokens keep their LP fee + locker,
  post-hook tokens keep fee 0 + hook — each internally consistent.
- **Base-on-V4 gate — sound.** `if (mode == Base && feeHook == 0) revert` sits on the only launch path,
  so a Base token can never launch without a hook; its mechanism slice folds to the flagship. (The `else`
  branch's self-buyback venue registration for a Base token is inert dead state — `process()` rejects
  Base and the locker never notifies for a hook token — not a stranding path.)
- **Lottery — correct.** Roll-based MISS returns early before payout (`:533-549`); the finalize roll
  equals the miss-check roll, so jackpot-vs-regular only sees non-miss rolls; the cooldown is written
  **only on a real win** (`:623`), never on a MISS/void; the `wonAt != 0` first-winner guard and the
  `[wonAt, wonAt+cooldown)` boundary are both correct.
- **V1 split — correct.** `setFeeShares` enforces sum==BPS (uint256-cast, no overflow), onlyOwner, event;
  treasury/dev floored + flagship the exact remainder (no dust stranded); `flagshipSink` fold correct in
  both directions; `nonReentrant` + `SafeERC20`; overflow-bounded by the uint128 collect cap.
- **SeasonMerkleDistributor — no regression.** Rescue still hard-wired to the immutable treasury; roots
  set-once (`adminSetRoot` only before any claim); per-season claimed bitmap; `onlyRootPublisher` on
  publish; per-season payout capped at deposited.

## Review-pass misreads, dropped after hand-verification
- "Cooldown is set even on a MISS" — **false.** `lastWinAt` (`:623`) is written only after the
  void/miss early-returns, on REGULAR/JACKPOT outcomes only.
- "Division-by-zero in the flagship carve strands protocol fees" — **not reachable.** The `wethFees > 0`
  guard + `splitOf`'s `UnsupportedFee` revert mean the divide is never executed with `p.key.fee == 0`
  for real fees; only donate-griefed dust is affected (see L-4).

---

## Test-coverage gaps to close before deploy
- **Exact-output swaps** (buy and sell) — assert zero fee / no revert today; assert the fee once M-1 is
  implemented.
- **WETH-as-currency0 ordering** — existing hook tests deterministically exercise only one ordering.
- **Partial-fill exact-input** (tight `sqrtPriceLimitX96`) — pins L-3 behavior.

## Suggested pre-deploy fix set
Cheap, unambiguous, low-risk (recommend applying now): **L-1** (fee cap), **L-2**
(`validateHookPermissions`), **L-4** (fee-0 locker short-circuit), **L-6** (`notify` try/catch),
**L-8** (`Ownable2Step`), **L-7** (`claimMany` skip-empty).
Needs a product decision: **M-1** (implement exact-output fee vs document/gate) and **L-5** (cooldown:
document-as-soft vs re-draw). **M-2** (creator-share floor/timelock vs document).

---

## Remediation — applied 2026-08-03 (all tests green: 139 passed, 0 failed)

| # | Status | What changed |
|---|---|---|
| M-1 | **Fixed (implemented)** | `WethFeeHook` now charges on all four cases. `beforeSwap` charges when WETH is the *specified* currency (exact-in buy / exact-out sell); `afterSwap` charges when WETH is the *unspecified* currency (exact-in sell / exact-out buy). Exactly one leg fires per swap. New tests: `test_exactOutputBuy_*`, `test_exactOutputSell_*` (swapper still gets exactly the requested WETH; no token taken). |
| M-2 | **Mitigated** | `v1/FeeLocker`: `MIN_DEV_BPS = 1000` floor in `setFeeShares` — the creator slice can never be tuned to zero. Retroactivity itself is still owner-trusted (timelock deferred; documented). |
| L-1 | **Fixed** | `MAX_FEE_BPS = 1000` enforced in the hook constructor and `setFeeBps`. Test: `test_setFeeBps_capEnforced`. |
| L-2 | **Fixed** | Hook constructor calls `Hooks.validateHookPermissions(...)` — a wrong-address deploy now reverts at CREATE2. |
| L-3 | **Documented** | Partial-fill exact-input over-charge accepted (no protocol loss; rare tight-limit case). |
| L-4 | **Fixed** | `LaunchFairV4FeeLocker.claim` short-circuits fee-0 (hook) positions — sweeps any stray WETH to treasury instead of `splitOf`/dividing. The latent `/p.key.fee` is now unreachable. |
| L-5 | **Fixed (re-draw)** | The lottery cooldown now re-draws past a cooling holder to the next eligible holder (wrapping to the first eligible; voids only if *every* holder is cooling) — deterministic, anti-grind preserved. Test: `test_lottery_winnerCooldownRedrawsToNextHolder` (multi-holder) + the sole-holder void case still holds. The address-keyed wallet-rotation bypass is now documented in the code as a soft deterrent. |
| L-6 | **Fixed** | Hook `_split` wraps `distributor.notify` in try/catch (notify-first, then fund), falling back to the flagship so a reverting notify can never strand a token's fees. |
| L-7 | **Fixed** | `v1/FeeLocker.claimMany` now skips empty/unknown tokens (shared internal `_claim(token, revertOnEmpty)`), so one idle token can't DoS a batch. |
| L-8 | **Fixed** | `v1/FeeLocker`, `LaunchFairV4FeeLocker`, and `WethFeeHook` switched to `Ownable2Step`. |

### N-1 — NEW, found during remediation: the hook was not an authorized `notify`er on the distributor
**Was:** `LaunchFairV4Distributor.notify` was `onlyLocker`; the hook is not the locker, so for a
**mode token (Reward/Lottery) launched via the hook** the hook's mechanism-slice `notify` reverted
(the existing tests never hit it — Base token / unset distributor).

**Fixed (decision: hook serves all tokens).** Added a settable `feeHook` on the distributor
(`setFeeHook`, owner-only, re-settable) and widened `notify` to accept `locker` **or** `feeHook`, so a
hook-served mode token funds its own mechanism. The L-6 try/catch remains as a safety net (if the hook
is ever de-authorized, its mechanism slice falls back to the flagship rather than stranding). Deploy
wiring: after mining/deploying the hook, call `LaunchFairV4Distributor.setFeeHook(hook)` (added to the
deploy-script reminder). Test: `test_notify_authorizesFeeHook` (non-locker/non-hook caller reverts;
authorized hook credits the pot).

### Fee is a single global knob (per-token overrides considered, then removed)
The hook's fee **rate and split are global** (`setFeeBps` / `setSplit`, `onlyOwner`, `bps ≤ MAX_FEE_BPS`,
split sums to `BPS`) and are read at swap time, so a change applies to **every token on the hook at once —
live, new, or old**. A per-token override layer was briefly added and then **removed** (owner's call:
one setting for all), so no new post-audit state remains — the audited global path is what ships. The
flagship uses this same global config and self-buys-back as a plain token (mechanism folds to flagship).
Test: `test_globalFeeBps_appliesToLivePools`.
