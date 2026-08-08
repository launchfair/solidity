# Security Audit — Perps Reward Mode (leveraged stock positions as rewards)

**Date:** 2026-08-03
**Scope:** the new Perps reward mode — the venue (`IPerpsVenue`, `PerpPositionToken`,
`ReferenceStockPerpVenue`) and the integration (`LaunchTokenV2.Mode.Perps`, `LaunchFairV4`'s
`PerpLeg` basket + registration, `LaunchFairV4Distributor`'s `process()`/`_openPerp`).
**Status:** pre-deployment; nothing live. See `docs/PERPS_REWARD_MODE.md` for the design.
**Method:** three independent adversarial review passes (venue math/accounting; venue
economic/adversarial with PoCs; integration/mode-ripple), each reading the source + running
Foundry, then every finding re-verified by hand against the code. Fixes were then applied and
re-tested (**153 tests pass**).

## Verdict

**No Critical.** The core NAV/PnL/share math is **provably sound** (leverage, entry-weighting,
share pricing, redeem proportionality, liquidation boundary — all verified numerically), and the
classic **first-depositor share-inflation attack is confirmed NOT exploitable** (there is no
donation path; collateral and supply grow together). The real issues were **two HIGHs** (one in the
integration, one in the venue) plus an oracle-latency economic vector and several LOWs — **all now
fixed and regression-tested.** The remaining risk is the **reference venue's operator oracle**,
which a production venue must replace (a real push oracle + liquidation/funding keepers) — that is
the design boundary, not a code defect, and it's clearly gated ("needs a production venue + audit
before ship").

## Severity summary

| # | Severity | Finding | Status |
|---|---|---|---|
| H-1 | High | A liquidated / zero-share perp leg reverts `process()` and **bricks the token's rewards** (no try/catch) | **Fixed** |
| H-2 | High | Venue commingles all WETH with no per-pool solvency — a winning pool's redeem can **drain another pool's collateral** | **Fixed** |
| H-3 | High* | Oracle-latency "free option": permissionless `open` around a stepped operator price = risk-free leveraged skim from the house | **Mitigated** (prod: real oracle) |
| M-1 | Medium | `perpsVenue` unpinned — launchpad/distributor divergence or a later swap bricks `process` with no migration path | **Fixed** |
| M-2 | Medium | Cross-token coupling: tokens sharing a `(market,side,lev)` share one pool + fate | **Documented** (blast radius cut by H-1/H-2) |
| L-1..8 | Low | `shares==0` keeps margin · redeem rounding subsidizes house · no house withdrawal · dust div-by-zero · no reentrancy guard · `lastPayoutBlock` on no-op · empty-pool panic · `marginToken==weth` unchecked | **Fixed** |

\* H-3 was rated Medium by one reviewer (Arbitrum single-sequencer blocks the same-block sandwich) and High by another (stale-price entry survives regardless); we treat it as High and mitigated it.

---

## Findings + remediation

### H-1 — A liquidated / zero-share leg permanently bricks the token's rewards → **Fixed**
`process()` deployed every leg in one all-or-nothing loop with no try/catch. The market-hours guard
is *market*-level, but a specific *pool* can be liquidated (value → 0) while its market is still open
(`price > 0`), so `venue.open` reverts `PoolLiquidated` → the whole `process()` reverts. With frozen
baskets, a 2-leg token where one leg liquidates has its rewards stuck for both legs, indefinitely.
(`out == 0` from a rounding-to-zero share mint did the same via the `Slippage` revert.)
**Fix:** `_openPerp` wraps `venue.open` in try/catch (returns 0 on any revert, clears the approval);
`process()` treats a leg with `out == 0` or `out < minOut` like a closed market — **holds** its WETH
(`held += portion`) and re-credits `pendingWeth` for a later cycle instead of reverting. Test:
`test_perps_liquidatedLegDoesNotBrickTheToken` (a 2-leg token with one liquidated leg processes
fine, holding the bad leg, deploying the good one).

### H-2 — Commingled WETH, no per-pool solvency: cross-pool collateral drain → **Fixed**
`redeem` paid `out = pv·shares/supply` from the contract's *entire* WETH balance (every pool's
collateral + house, one pot) while decrementing only that pool's books. A profitable pool could pay
itself out of another token's margin, leaving the second token insolvent (PoC: two 10-WETH pools,
house 0, one marks +30% and redeems 19 → the other can't redeem its 10).
**Fix:** the venue now tracks a **segregated `houseBalance`** (funded via `fundLiquidity`, withdrawn
only via owner `withdrawHouse` bounded by `houseBalance`). `redeem` pays the redeemer's collateral
slice from the pool and any PnL **only from `houseBalance`** — a profitable redeem that would exceed
the house **reverts `InsufficientHouse`** rather than dipping into other pools' collateral. Invariant:
`WETH balance == Σ pool.collateral + houseBalance`, solvent by construction. Test:
`test_redeem_cannotDrainOtherPoolsCollateral`.

### H-3 — Oracle-latency "free option" via permissionless `open` → **Mitigated (production: real oracle)**
With a lagging operator price and frictionless permissionless `open`/`redeem`, an informed actor
could `open` at a stale-favorable price, wait for the operator's `setMarkPrice`, and `redeem` the
full leveraged delta risk-free from the house — repeatable each tick.
**Fix (reference):** `open` is now **gated to authorized depositors** (`isOpener`, the fee
distributor) — arbitrary MEV can no longer farm it; `redeem` stays open for holders. Test:
`test_open_onlyAuthorizedOpener`. **Production requirement (unchanged):** replace the operator oracle
with a genuine push oracle (Chainlink/Pyth) + staleness/deviation guards and add funding — gating
`open` closes the *farming* vector but the *stepped-oracle* class is only fully closed by a real
oracle. Documented in the venue NatSpec + `docs/PERPS_REWARD_MODE.md`.

### M-1 — `perpsVenue` unpinned; launchpad/distributor divergence bricks payout → **Fixed**
`LaunchFairV4.perpsVenue` (resolves the position token at launch) and the distributor's venue (mints
at payout) were two separate, re-settable addresses; a divergence or a later global swap made
`process` mint a token the launch never registered → `fundRewards` reverts, no migration path.
**Fix:** the venue is now **pinned per token** — `registerPerps(token, venue)` stores
`perpsVenueOf[token]` (the launchpad passes its own `perpsVenue`), and `process` uses that pinned
venue, so launch-time and payout-time can't diverge and a later global change never affects an
existing token. `LaunchFairV4.setPerpsVenue` also asserts `venue.marginToken() == weth` (closes the
`marginToken` mismatch, old L-8).

### M-2 — Cross-token coupling → **Documented (blast radius reduced)**
Two launch tokens that pick the same `(market, side, leverage)` share one pool and the *same*
position ERC20. Day-to-day this is NAV-neutral (no dilution — verified), and it's arguably a feature
(one fungible, liquid leveraged token). The exploitable amplifiers (H-1 cross-brick, H-2 cross-drain)
are now fixed, so the residual is shared-fate on liquidation, which is inherent to a fungible
position token. Documented; a production venue may key pools per launch-token if isolation is wanted.

### LOW — all fixed
- **L-1 `shares==0` kept margin:** `open` now reverts `ZeroShares` on a sub-NAV-per-share deposit (test `test_open_rejectsSubNavDust`).
- **L-2 redeem rounding subsidized the house:** removed size is now `ceilDiv`'d (pool never over-retains; rounding favors the house).
- **L-3 no house withdrawal:** added owner `withdrawHouse` bounded by `houseBalance` (test `test_withdrawHouse_boundedByHouse`).
- **L-4 dust div-by-zero:** `addSize` floors to 1 so a pool's `size` can't be 0 (no divide-by-zero on the next add).
- **L-5 no reentrancy guard:** `open`/`redeem`/`fundLiquidity`/`withdrawHouse` are `nonReentrant`; `open` computes state before the transfer (CEI). (Safe already because `marginToken` is WETH; defense-in-depth.)
- **L-6 `lastPayoutBlock` on no-op:** `process` restores the previous payout block when nothing was deployed (all legs held), so a market-closed run can't burn the dev's timer.
- **L-7 empty-pool redeem panic:** `redeem` guards `supply == 0` (`ZeroShares`) instead of a bare divide-by-zero panic.
- **L-8 `marginToken == weth` unchecked:** asserted in `LaunchFairV4.setPerpsVenue`.

---

## Verified correct (checked and cleared)

- **NAV / PnL / share math.** `size = margin·lev·1e18/(BPS·price)`, `uPnl = size·(price−entry)/1e18`
  signed by side, `poolValue = collateral + uPnl` floored 0. A 3× long on +10% → +30% NAV; a 2× short
  on −10% → +20% (re-derived + tested). Entry-price is the correct size-weighted average. Share mint
  (`margin·supply/pv`) prices at pre-deposit NAV — **no value transfer to/from existing holders**.
  Redeem pays exactly the proportional NAV and leaves the pool consistent. Liquidation boundary
  (`uPnl ≤ −collateral`) is exact.
- **First-depositor / ERC-4626 inflation — NOT exploitable.** No permissionless donation path;
  `fundLiquidity` never touches pool collateral; collateral and supply move together, so NAV/share
  can't be inflated to grief later depositors.
- **Mode-enum ripple — clean.** Every `mode ==` branch across `LaunchTokenV2`/`Distributor`/`FeeLocker`
  correctly includes Perps (reward-asset setup, dividend share-sync) or excludes it (Increasing
  compounding/`balanceOf`, Lottery paths, the `Base||Lottery` process gate).
- **`_create` Perps validation:** weight-sum == 10000, per-leg `0 < leverage ≤ MAX_LEVERAGE_BPS` (5×),
  dup-leg rejection on resolved token addresses, `perpsVenue != 0`. No bypass.
- **Access control:** `PerpPositionToken.mint/burn` are `onlyVenue` and `burn` only ever burns the
  redeemer's own shares; venue operator setters are `onlyOwner`; `open` is opener-gated; `process` is
  processor-gated; `registerPerps` is registrar-gated.

## Reference-venue limitations (production venue's job, documented — not code defects)
- **Operator oracle is fully trusted** (can set marks arbitrarily → drain the house it funds / wipe
  pools). Production MUST use a real push oracle (Chainlink/Pyth) with staleness + deviation guards,
  and remove unilateral mark-setting. This is the single biggest thing a production venue replaces.
- No funding rate, isolated-margin leverage drift (no daily rebalancing), and a liquidated pool is
  terminal (re-seed reverts) rather than re-opened. All acceptable for a reference; a production venue
  addresses them.
- `positionTokenFor` deploy-spam (attacker pays gas, listed markets only) and the integer leverage
  label collision are cosmetic/low.

## Test coverage added
`test_perps_liquidatedLegDoesNotBrickTheToken` (H-1), `test_redeem_cannotDrainOtherPoolsCollateral`
(H-2), `test_open_onlyAuthorizedOpener` (H-3), `test_open_rejectsSubNavDust` (L-1),
`test_withdrawHouse_boundedByHouse` (L-3/L-7) — plus the pre-existing venue math + end-to-end mode
tests. **153 pass, 0 fail.**

## Bottom line
The Perps mode's design and math are sound, and the two serious bugs (cross-brick, cross-drain) plus
the economic and correctness issues are fixed and tested. **Before mainnet it still needs a
production venue** (a real oracle is the load-bearing dependency) **and a fresh audit of that venue** —
but the *reward-mode integration* is now hardened and safe to run against the (hardened) reference
venue on staging.
