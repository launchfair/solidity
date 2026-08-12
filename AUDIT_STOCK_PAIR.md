# Audit — Stock-paired launch tokens (`StockPairRouter` + `RouterGateHook` + `LaunchFairV4` stock path)

**Scope.** The additive stock-paired token type: buy/sell a launch token with native ETH where the
liquidity pool is `TOKEN/<stock>` (Robinhood tokenized stocks) instead of `TOKEN/WETH`.
- `src/v2/v4/StockPairRouter.sol` — the 2-hop router (ETH→WETH→stock→TOKEN and back) + the WETH fee engine.
- `src/v2/v4/RouterGateHook.sol` — the V4 hook that gates the stock pool to the router.
- `src/v2/v4/LaunchFairV4.sol` — `createStockToken` / `createStockAndBuy`, the quote allowlist, and the
  `stockPairRouter` / `stockGateHook` wiring (the WETH-paired path is unchanged).
- `src/v2/v4/LaunchFairV4FeeLocker.sol` — reviewed for interaction with stock (fee-0, non-WETH) pools.

**Method.** One author pass plus **three independent adversarial reviewers**, each tasked to *refute*
a specific safety claim: (1) fund safety & fee accounting, (2) access control & fee-bypass, (3) V4
flash-accounting & the cross-protocol (V3+V4) hop composition. Reviewers 1 and 3 found **no
Critical/High/Medium**. Reviewer 2 confirmed the fee-bypass core is sound and surfaced one Medium DoS
foot-gun, one Low locker-accounting issue, and one trust-boundary item. All code findings are fixed;
the trust item is documented and accepted.

## Findings

| # | Severity | Area | Status |
|---|----------|------|--------|
| M-1 | Medium | Re-setting `stockPairRouter` would orphan (permanently un-trade) all existing stock pools — the gate hook is immutably bound to the router and baked into every pool key. | **Fixed** |
| L-1 | Low | `FeeLocker.claim` on a fee-0 stock pool mislabels the stock leg as WETH (a `donate` griefs it); it fails safe today (reverts, no WETH held) but is unclean. | **Fixed** |
| L-2 | Low | `StockPairRouter.distribute` lacked `nonReentrant` (verified non-exploitable today; hardening). | **Fixed** |
| T-1 | Info/Trust | The owner can retune `setSplit`/`setDestinations`, so the dev's fee share is not cryptographically protected. | **Accepted (documented)** |
| I-1..I-3 | Info | MEV on the V3 leg (mitigated by end-to-end `minOut`); buy partial-fill refunds stock not ETH; no owner sweep for stray funds. | **Accepted** |

### Confirmed SAFE (reviewers tried to break these and could not)
- **Fee bypass is impossible.** `RouterGateHook.beforeSwap` reverts unless `sender == router`; `sender`
  is the EVM-set `msg.sender` of the `poolManager.swap` caller and is **unspoofable** (verified against
  v4-core `Hooks.sol`/`PoolManager.sol`). Direct swaps, aggregators, nested unlocks, and `donate` all
  fail to move value out. Every swap path goes through the router, which always skims the WETH fee.
- **Locked supply cannot be pulled.** The launch position is owned by the FeeLocker with no decrease
  path; anyone can add/remove *their own* liquidity but cannot touch the locked supply, and price can't
  move without a gated swap (so the gate is *more* sandwich-resistant than a normal pool).
- **Flash-accounting is correct.** `unlockCallback` is a faithful copy of the audited
  `LaunchFairV4SwapRouter`; `zeroForOne`, the input/output delta signs, `owed`/`got`, and the
  partial-fill refunds are correct in all four directions and under range exhaustion (verified against
  v4-core `Pool.sol:451-462`). No stuck delta; a slippage/partial revert unwinds the whole tx.
- **Accrued-fee invariant holds.** `router WETH balance == Σ accrued[token]` on every path; a trade only
  ever spends the WETH it itself brought in, and `distribute` transfers **exactly** `accrued[token]`
  (`toTreasury + toDev + toFlagship == amount`), so trading token Y can never touch token X's fees.
- **Hook mining is fail-fast.** The gate hook declares exactly `beforeSwap`; `validateHookPermissions`
  reverts a wrong-flag deploy, so no other callback can be silently enabled.

### M-1 — router/hook re-set orphans existing stock pools (Fixed)
`stockGateHook` and `stockPairRouter` were plain re-settable setters, but `RouterGateHook.router` is
immutable and the hook is baked into each pool's `PoolKey` at launch. Re-pointing `stockPairRouter`
(e.g. to fix a router bug) would leave every existing stock pool gated to the *old* router → the new
router's swaps revert `NotRouter` → all existing stock tokens become permanently untradeable (no fund
theft, but a hard availability failure).
**Fix:** both setters are now **set-once**, and `setStockGateHook` requires
`RouterGateHook(hook).router() == stockPairRouter` (router set first). A mismatched or repeat wiring
reverts. The router is thus effectively immutable per deployment — migrate by redeploying the launchpad
(the project's immutable-stack model). Tests: `test_stockSetters_areSetOnce`,
`test_setStockGateHook_rejectsMismatchedRouter`.

### L-1 — locker `claim` on a stock pool (Fixed)
`FeeLocker.claim` treats the pool's non-token side as WETH. For a `TOKEN/<stock>` pool that side is the
stock; an attacker could `donate` stock into the pool and call `claim`, whose fee-0 branch would run
`weth.safeTransfer(treasury, wethFees)` for a stock-denominated amount. In practice it fails safe (the
locker holds no standing WETH → the transfer reverts, unwinding the `take`, stranding only the
attacker's own donation), but it is unclean and a latent foot-gun if the locker ever held WETH.
**Fix:** `claim` now reverts `NotWethPaired` when neither pool currency is WETH — stock pools take
their fee at the router, never here. WETH-paired hook pools (fee 0, WETH leg) still pass. Test:
`test_locker_claim_rejectsStockPool`.

### L-2 — `distribute` reentrancy hardening (Fixed)
`distribute` was CEI-correct (zeroes `accrued[token]` before the WETH fan-out; WETH is not a callback
token) and reachable reentrancy (the sell's `to.call`) could only hit it harmlessly. Added
`nonReentrant` as defense-in-depth against future changes (e.g. a callback-capable fee recipient).

### T-1 — owner controls fee routing (Accepted, documented)
The `StockPairRouter` owner can set `setSplit`/`setDestinations`, so it can zero `devBps` or point
`treasury` at itself and, on the next permissionless `distribute`, take the accrued WETH. This is the
**same trust model as `WethFeeHook` and `LaunchFairV4FeeLocker`** — fee routing is owner-controlled
across all of LaunchFair. The dev slice is paid to `creatorOf(token)` (the launchpad's record, not an
owner argument), but `devBps` is a global owner knob. "Dev-fee economics unchanged" therefore holds
**given an honest owner**; the owner should be a multisig. No code change, for consistency with the
sibling contracts.

### Info
- **I-1 (MEV):** the V3 `<stock>/WETH` hop runs `amountOutMinimum: 0`; both hops are sandwich-able, but
  the caller's end-to-end `minOut` makes a sandwiched trade revert rather than settle at a loss.
  Robinhood Chain's FCFS sequencer (no public mempool) further limits this.
- **I-2:** a buy that walks the entire token curve (practically impossible) refunds leftover **stock**
  (not ETH) to `to`. No loss; a plain ERC20 transfer to the beneficiary.
- **I-3:** the router has no owner sweep, so funds sent directly to it are unrecoverable — but this is
  not leverageable (no function pays out on raw balance, only `accrued`), so it can't break the invariant.

## Trust assumptions (must hold)
1. **Quote allowlist** (`setAllowedQuote`) must only ever list standard 18-decimal ERC-20 stock tokens.
   A callback-capable (ERC-777/1363) or fee-on-transfer quote would break the reentrancy/settlement
   analysis (a fee-on-transfer quote makes trades revert — grief, not theft). Robinhood tokenized
   stocks are standard 18-dp ERC-20s.
2. **Owner = multisig** (T-1).
3. Launch tokens are Base-mode `LaunchTokenV2` (enforced), which has no transfer callback.

## Test coverage
`test/v2/StockPairRouter.t.sol` — **14 tests**: buy/sell round-trip, WETH fee accrual both legs,
`distribute` split exactness, slippage/expired/unknown-token reverts, gate blocks a direct swap,
`createStockToken`/`createStockAndBuy` end-to-end, quote-not-allowed / non-Base rejects, and the three
audit-fix guards (M-1 set-once + consistency, L-1 locker rejection). Full suite: **167 pass, 0 fail**.

## Post-audit change (2026-08-12): ETH payout + treasury-settable tax

Per product direction ("everyone should get ETH; deployer or treasury can set the tax"), the fee
distribution now pays **native ETH** to dev/treasury/flagship (unwrapping the WETH first), and the
global tax knobs are settable by **owner OR treasury**. Applied to `StockPairRouter.distribute`,
`WethFeeHook._split`, and `LaunchFairV4FeeLocker.claim`. The **mechanism slice stays WETH** everywhere
(it feeds the on-chain buyback engine, which swaps WETH→reward).

Security of the ETH-payout (reentrancy is the main concern — `.call{value}` to dev/treasury/flagship):
- `StockPairRouter.distribute` and `FeeLocker.claim` are `nonReentrant`, and each zeroes its accrued
  state before paying — a reentrant call reverts on the guard.
- `WethFeeHook._split` runs **inside** the PoolManager `unlock` (the ETH send happens mid-unlock), so a
  reentrant `distribute` would attempt a nested `poolManager.unlock`, which the PoolManager rejects —
  the reentry can't complete. `accrued` is also zeroed before the unlock.
- DoS: a fee recipient that reverts on ETH receive makes that token's distribute/claim revert
  (retryable — state unwinds); dev = `creatorOf` (usually an EOA), treasury/flagship are
  platform-controlled. Accepted. The `flagshipSink`, once set, must accept ETH (have a `receive`).
Full suite: 168 pass.

## Conclusion
No Critical/High/Medium fund-safety or correctness issues survived review. The router faithfully
preserves the invariants of the two audited templates it is built from, the fee cannot be bypassed, and
the accrued-WETH accounting is tight. One Medium availability foot-gun (M-1) and two Low/defensive items
are fixed; the remaining item is an accepted, documented owner-trust boundary consistent with the rest
of the protocol. A production deployment should still run an on-chain fork pass over a live
`<stock>/WETH` V3 pool and use a multisig owner.
