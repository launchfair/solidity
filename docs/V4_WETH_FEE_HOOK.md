# V4 WETH Fee Hook — Design Spec (two-way WETH, no sell pressure)

> **Current status (2026-08-15): the production hook is `src/v2/v4/WethFeeHookImmutable.sol`.** The fee
> mechanics in this spec are unchanged (fee in WETH on both legs, ERC-6909 claims, the per-tier
> `FeeSplitConfig` split, all four swap cases), but the fee rate, split, and destinations are now
> **constructor immutables with no owner and no setters**, so a token scanner sees no admin surface on
> the hook. It is deployed to a mined address via `script/DeployWethFeeHookImmutable.s.sol` +
> `HookMiner.sol` and pointed in for future launches with `LaunchFairV4.setFeeHook`; a pool's hook is
> fixed at creation, so this only affects new launches. `WethFeeHook.sol` (the owner-tunable variant
> described in the older note just below) is superseded and remains only for pools created before the
> switch. The pre-build "open decisions" in §7 were resolved as: one shared address-mined hook, a
> per-tier 3/5/10 percent fee fixed in the launch record (not owner-editable), pool LP fee 0,
> permissionless `distribute`, and no residual burn. The blueprint below is the original design spec
> and is kept for context; where it says the fee is "owner-editable," read "fixed at launch,
> immutable." The security write-up now lives in the top-level
> [`README.md`](../README.md#security-audits-and-fixes).

_Status update (2026-08-03): **Built, audited, hardened.** `src/v2/v4/WethFeeHook.sol` takes the fee
in WETH on both legs as **ERC-6909 claims** (`poolManager.mint`, redeemed in `distribute` via
unlock→burn→take) — critically this works on our **single-sided launch pools**, where a physical
`take()` in `beforeSwap` fails on the first buy (no WETH reserves yet). It runs the full 4-way split,
is mode-aware (a plain/Base token's mechanism slice folds to the flagship), and is wired into
`LaunchFairV4` via `setFeeHook`. **Now handles all four swap cases** (buy/sell × exact-in/exact-out —
§2's "fiddly part" is implemented + tested), has **address-mining tooling** (`script/HookMiner.sol` +
`DeployWethFeeHook.s.sol`), and was **audited** (findings: shared-claim pool proven
non-drainable, delta accounting correct, hardening applied — fee cap, permission validation, notify
fail-safe, `Ownable2Step`). (Those follow-ups — distributor authorization, frontend routing, retiring
the V3 curve stack — were all resolved later, and the hook was subsequently reissued as the immutable
variant per the current-status banner above.) The blueprint below stands._

Blueprint for adding a Uniswap V4 hook that
charges the fee in **WETH on both buys and sells**, taken from the WETH leg of the swap — so a
sell produces **no token sell pressure** and the fee is captured **regardless of which
router/aggregator** executes the trade._

---

## 1. Why a hook (and not the current model)

Uniswap pool LP fees always accrue in the swap's **input** asset → WETH on a buy, **token** on
a sell (which we burn). To get WETH on a sell **without selling the token**, you must take the
fee from the **WETH the seller is receiving** (the output leg), not by swapping fee-tokens.

- A **router fee** (`unwrapWETH9WithFee`, which we already use for verified tokens) does this —
  but only when the trade goes through *our* router. gmgn / aggregators / direct pool swaps
  bypass it.
- A **V4 hook** takes the WETH fee inside the PoolManager on **every** swap on the pool, any
  router. That's the only way to get "two-way WETH, no sell pressure, catches everyone."

**The tradeoff to accept up front:** a WETH-both-ways hook means there is **no token-side fee →
no deflationary burn.** The current sell-side burn goes away; all fee revenue becomes WETH.
(You *can* keep a small burn by also keeping a token LP fee, but that reintroduces some sell-side
token fee — see §7.)

---

## 2. How the hook takes WETH on both sides

The hook skims `feeBps` **in WETH** from whichever leg of the swap is WETH:

| Trade | WETH is the… | Hook takes the fee in… |
|---|---|---|
| **Buy** (WETH → token) | input | `beforeSwap` (BeforeSwapDelta on the specified/input currency) |
| **Sell** (token → WETH) | output | `afterSwap` (AfterSwap return-delta on the unspecified/output currency) |

Mechanically (v4-core):
- **Permissions** (encoded in the hook address — see §4): `BEFORE_SWAP`, `AFTER_SWAP`,
  `BEFORE_SWAP_RETURNS_DELTA`, `AFTER_SWAP_RETURNS_DELTA`.
- **`beforeSwap`** returns a `BeforeSwapDelta`. When the swap's WETH leg is the **specified**
  currency (WETH-input on an exact-input buy), the hook returns a delta that pulls `feeBps` of
  that WETH to the hook before the pool swaps the rest.
- **`afterSwap`** returns an `int128` delta on the **unspecified** currency. When the WETH leg is
  the **output** (a sell), the hook returns `feeBps` of the WETH output, which the PoolManager
  routes to the hook instead of the trader.
- Per swap, the hook decides which path applies from `params.zeroForOne` + which currency
  (`currency0`/`currency1`) is WETH. Either way the fee is **WETH**, and the trader simply gets
  slightly less WETH out / puts slightly less WETH into the pool — **no token is ever sold.**

**Exact-input vs exact-output (the fiddly part):** "specified" vs "unspecified" flips between
exact-in and exact-out swaps. The hook must handle both: for exactInput the specified currency is
the input; for exactOutput it's the output. Getting the fee on the correct leg in all four
(buy/sell × exactIn/exactOut) cases is the main correctness surface — spell each case out and
test it.

---

## 3. Fee routing — reuse the existing split, replace only the source

The hook **accrues** WETH fees per token (as PoolManager claim balances / an internal tally). It
does **not** distribute inside the swap (external transfers mid-swap = reentrancy/gas risk).
A keeper (or a permissionless `distribute(token)`) then pulls the accrued WETH and runs the
**same split we already have** — so the hook replaces the fee *source*, not the fee *routing*:

```
hook accrues WETH per swap  ──►  distribute(token) (keeper)
                                   → treasury  (FeeSplitConfig)
                                   → dev / creator
                                   → mechanism → distributor.notify (reward/lottery)
                                   → flagship  → flagshipSink (the 0.1%-style carve)
```

So `FeeSplitConfig`, `distributor.notify`, and the `flagshipSink` carve all stay — the hook just
feeds them WETH-on-both-sides instead of the locker feeding them WETH-on-buy + burning the token.
The `LaunchFairV4FeeLocker` still **locks the LP position** (liquidity locked forever); the hook
owns the **fees**.

**Pool fee → 0 (or dynamic):** set the pool's LP fee to 0 (or a dynamic-fee pool the hook
controls) so the hook is the *only* fee. Since we own the locked LP, the LP fee was accruing to us
anyway — moving it into the hook just makes it WETH on both sides.

---

## 4. Deploy constraint — hook address mining

A V4 hook's **permissions are encoded in the low bits of its address**, so the hook must be
CREATE2-deployed to an address whose bits match the enabled flags (`Hooks.validateHookPermissions`
reverts otherwise). Use a HookMiner to find a salt → address with the `BEFORE_SWAP | AFTER_SWAP |
BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA` bits set, then deploy with that salt. The
**new V4 launchpad** wires every new token's pool to this hook (`PoolKey.hooks = hook`) at
creation. (Existing V4 pools launched with `hooks: address(0)` can't gain a hook — this applies to
**tokens launched after** the redeploy.)

---

## 5. What changes, concretely
- **New:** a `WethFeeHook` contract (beforeSwap/afterSwap, per-token accrual, `distribute`),
  address-mined + deployed.
- **`LaunchFairV4`**: set `PoolKey.hooks = hook` and the pool LP fee to 0/dynamic at create; the
  fee tier the creator "picks" becomes the **hook's `feeBps`** (still creator-selected, still
  owner-editable — same as today's tiers, just enforced by the hook).
- **`LaunchFairV4FeeLocker`**: unchanged for liquidity locking; the fee-claim path moves to the
  hook's `distribute` (which reuses `FeeSplitConfig` + `distributor.notify` + `flagshipSink`).
- **Indexer/frontend**: index the hook's fee events instead of (or alongside) the locker's
  `FeesClaimed`; price/candles are unaffected (still from PoolManager `Swap`).

---

## 6. Risks / considerations (audited; see the status banner above)
- **Hook security is high-stakes:** a buggy hook can **brick the pool** (every swap reverts) or be
  drained. beforeSwap/afterSwap run inside the PoolManager `unlock` context — reentrancy,
  delta-accounting mistakes, and rounding all matter. This is a bigger, more dangerous surface
  than the current locker.
- **Every exactIn/exactOut × buy/sell case** must take the fee on the correct leg and settle
  deltas exactly, or swaps revert / fees leak.
- **No burn** anymore (unless §7). Confirm you're OK trading the deflationary burn for WETH revenue.
- **Fee-on-transfer / weird tokens**: our LaunchTokenV2 is standard, fine — but the hook must
  assume WETH is standard.
- **MEV/rounding**: `feeBps` skims are small; ensure no path lets a swap round the fee to 0 to
  dodge it, and that large swaps can't game the leg selection.

---

## 7. Open decisions (pin before build)
1. **Keep any burn?** Pure hook (WETH both sides, no burn) — recommended for "no sell pressure" —
   vs a small residual token LP fee that still burns (hybrid, partial sell-side token fee).
2. **Fee level & editability:** the hook's `feeBps` (buy and sell — same or different?), owner-
   settable like the current split. Default = today's tiers (3/5/10%).
3. **Pool fee = 0 vs dynamic-fee pool** (dynamic lets the hook change the fee per-swap, e.g. a
   different buy vs sell fee).
4. **Distribution cadence:** per-swap accrual + keeper `distribute` (recommended) vs distribute
   inside the swap (riskier).
5. **Same hook for all tokens** (one shared, address-mined hook) vs per-token — one shared hook is
   simpler and cheaper.

---

## 8. Sequencing
1. Build + address-mine + test the `WethFeeHook` (all four swap cases).
2. Wire it into a redeployed V4 launchpad (pools created with the hook, LP fee 0/dynamic).
3. Route the hook's WETH through the existing split (treasury/dev/mechanism/flagship).
4. **Audit the hook** (its own pass — highest-risk piece of the V4 stack).
5. Applies to tokens launched **after** the redeploy; existing V4 tokens keep the current model.

---

## TL;DR
A V4 hook is the only way to charge **WETH on both buys and sells with zero token sell pressure,
on every trade regardless of router** — it skims the WETH leg (`beforeSwap` for WETH-in buys,
`afterSwap` for WETH-out sells), accrues per token, and feeds the **existing** treasury/dev/
mechanism/flagship split. Cost: it drops the deflationary burn, needs hook-address mining, careful
exact-in/out handling, and its own audit. It rides the V4 redeploy we already owe.
