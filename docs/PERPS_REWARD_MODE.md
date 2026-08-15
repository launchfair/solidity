# Stock-Perps Reward Mode — Design Spec

> **Current status (2026-08-15): Perps is NOT offered.** The mode exists in the contracts, but
> `ReferenceStockPerpVenue` uses an operator-set oracle and is not production. Shipping it needs a real
> push oracle (Chainlink / Pyth) plus liquidations and funding. This is a design spec for that future
> work, not a live feature. The launch UI does not offer Perps.

_Status update (2026-08-03): **DESIGN PIVOTED + Stage 1 BUILT.** Per the owner's call, holders no
longer receive a WETH **dividend** of realized PnL — they receive the **actual leveraged position as
a fungible token**. The dev picks market + side + leverage at launch; fees are deposited as margin
and the venue mints a per-`(market, side, leverage)` **`PerpPositionToken` (ERC20)** which is
distributed **hands-off through the existing reward-token tracker** — exactly like a reward token.
Each holder ends up with a real margined-position token in their wallet to hold, sell, or redeem for
WETH at NAV. Principal-safe: the launch-token balance is never margin; the position token carries the
leverage risk (which is the point). **Built + tested (Stage 1):** `src/v2/v4/IPerpsVenue.sol`
(re-specced to the tokenized model, §3), `src/v2/v4/PerpPositionToken.sol`, and
`src/v2/v4/ReferenceStockPerpVenue.sol` (a **reference** venue — operator oracle + hours, pooled
leveraged position, NAV mint/redeem; 6 tests). **Remaining (Stage 2):** `LaunchTokenV2.Mode.Perps`,
the Distributor `process` branch (mint the position token via the venue instead of a Uniswap buy →
fund the reward tracker), `LaunchFairV4` registration, keeper, a production venue, and an audit. The
dividend-model text below (§2, §5) is the OLD framing — kept for context; the tokenized model
supersedes "skim PnL → dividend" with "mint position token → distribute like a reward asset."_

_**Stage 2 update (2026-08-03): BUILT + tested end-to-end.** `LaunchTokenV2.Mode.Perps` added (behaves
like Reward for the dividend tracker; reward assets = the venue's position tokens).
`LaunchFairV4`: a `PerpLeg[]` in `CreateParams` (market/side/leverage/weight, 1-5 legs, weights sum to
10000, leverage <= `MAX_LEVERAGE_BPS` = 5x), a settable `perpsVenue`, resolves each leg to its position
token at launch. `LaunchFairV4Distributor`: settable `perpsVenue` + `registerPerps`, and a `process()`
Perps branch that deposits each fee batch as margin via `perpsVenue.open` (config read off the position
token - the keeper never picks direction/leverage), funds the tracker, and **holds** a leg's WETH when
its market is closed. Capstone test `test_endToEnd_perps_holderGetsLeveragedPositionToken_andRedeems`:
launch -> fee -> process -> a holder claims the leveraged-position token -> AAPL +10% -> holder redeems
for +30% WETH. **148 tests pass.** Deploy wiring: deploy the venue, `listMarket(...)` the RWA markets +
fund house liquidity, then `LaunchFairV4.setPerpsVenue(venue)` **and**
`LaunchFairV4Distributor.setPerpsVenue(venue)` (same address). STILL TODO: a production venue (real
equity oracle / liquidations / funding), the keeper's process/redeem loop, frontend basket picker, and
a production-venue audit._

_**Audit (2026-08-03): done + fixes applied.** 3 independent adversarial
passes + author verification. No Critical; the math is proven sound and first-depositor inflation is
NOT exploitable. Fixed: **H-1** a liquidated/zero-share leg no longer bricks `process()` (try/catch →
hold the leg); **H-2** the venue now segregates a `houseBalance` so a winning pool can't drain another
pool's collateral (solvent by construction, reverts `InsufficientHouse`); **H-3** `open` gated to
authorized depositors (kills MEV oracle-latency farming); **M-1** the venue is pinned per-token at
launch (no launchpad/distributor divergence) + `marginToken==weth` asserted; plus LOWs (ZeroShares
dust guard, ceilDiv redeem, withdrawHouse, reentrancy guards, no-op timer). Remaining is the
**production venue** (a real oracle is the load-bearing dependency) + its own audit; the reward-mode
integration is hardened. **153 tests pass.**_

---

## 1. What it is

A new V4 mode-token reward: instead of rewarding holders with a bought-back ERC20, the
token's fee mechanism opens **leveraged long/short positions on RWA stock-perp markets**
(AAPL, NVDA, TSLA, …) and distributes the **realized PnL** to holders. The dev picks a
**weighted basket** of positions at launch; holders receive the basket's leveraged equity
performance as a yield stream.

**Principal-safety invariant (the whole reason this is sane):** the position margin is
*fees* (house money), never holder principal. A liquidation costs a **reward round**, never
a holder's token balance. Upside = leverage amplifies rewards; downside = a round pays 0.

---

## 2. How it maps onto the existing V4 stack

Today's Reward flow (`LaunchFairV4Distributor.sol`):
```
fee → FeeLocker → notify() → pendingWeth[token]
    → keeper process() → _buyAsset (Uniswap swap) → fund the dividend tracker
    → holders claim the reward ERC20 pro-rata by holdings
```

Stock-Perps mode keeps the ends, swaps the middle:
```
fee → FeeLocker → notify() → pendingWeth[token]              (UNCHANGED)
    → keeper process()  → deploy WETH as MARGIN across the basket's legs
                          (venue.increasePosition per leg, by weight)
    → positions accrue PnL on the stock-perp venue
    → keeper realize()  → skim realized profit (settlement token) per leg
    → fund the SAME dividend tracker → holders claim               (UNCHANGED)
```

The reward holders receive is **WETH/stablecoin (the realized PnL)**, distributed by the
existing dividend tracker — the audited distribution path is untouched. The only new logic
is "deploy margin / realize profit" replacing "swap to reward asset."

It also reuses the **multi-reward-asset pattern** already in the Distributor
(`rewardTokensList()` + `rewardWeightBps`, per-`(token,asset)` registration frozen at
launch, L-03): a basket of stock legs is just a weighted list.

---

## 3. `IPerpsVenue` — the contract between the reward mechanism and the venue

This is the deliverable to lock now. The stock-perp venue implements it; the reward mode
only ever calls these. Keeping this surface tiny is what keeps the reward side auditable.

```solidity
interface IPerpsVenue {
    /// ERC20 the venue takes as margin / pays out (WETH or a stablecoin).
    function marginToken() external view returns (address);

    /// Open a position or add margin to an existing one. `market` is the venue's stock
    /// market id (e.g. keccak256("AAPL")); `leverageBps` e.g. 30000 = 3x. Returns a handle.
    function increasePosition(bytes32 market, bool isLong, uint256 margin, uint16 leverageBps)
        external returns (uint256 posId);

    /// Realize (skim) profit ABOVE the retained margin, paying `marginToken` to the caller.
    /// Leaves the position open with its base margin rolling. `minOut` guards slippage.
    function realizeProfit(uint256 posId, uint256 minOut) external returns (uint256 out);

    /// Fully close a position, returning remaining margin ± PnL.
    function closePosition(uint256 posId, uint256 minOut) external returns (uint256 out);

    /// Read state for the keeper's decisions + the UI.
    function positionValue(uint256 posId)
        external view returns (uint256 margin, int256 uPnl, uint256 liqPrice, bool open);

    /// Market-hours gate — false when the underlying stock market is closed.
    function marketOpen(bytes32 market) external view returns (bool);
}
```

**Venue responsibilities (NOT the reward mechanism's):** the equity price oracle,
liquidations, funding rates, margin accounting, solvency, market-hours, and the regulatory
framing. The reward side assumes the venue is correct and solvent — see Risk (§7).

---

## 4. Per-token config — the basket

Registered at launch and **frozen** (mirrors the reward-asset L-03 freeze), stored in the
Distributor keyed by token:

```solidity
struct PerpLeg {
    bytes32 market;     // venue stock market id (AAPL, NVDA, …)
    bool    isLong;     // long or short
    uint16  weightBps;  // share of each fee batch (Σ over legs == 10000)
    uint16  leverageBps;// e.g. 30000 = 3x, capped by MAX_LEVERAGE_BPS (mode-enforced)
    uint256 posId;      // venue handle; 0 until first opened (re-opened after a liquidation)
}
mapping(address token => PerpLeg[]) internal _legs;
```

Example basket a creator picks at launch:
| weight | side | leverage | market |
|---|---|---|---|
| 40% | long | 3× | AAPL |
| 30% | long | 2× | NVDA |
| 30% | short | 2× | TSLA |

---

## 5. Mechanism changes (Distributor + LaunchTokenV2)

- **`LaunchTokenV2.Mode`**: add `Perps` (or `StockPerps`). `LaunchFairV4` accepts it in
  `createAndBuy` and registers the leg basket (validating Σweight == 10000 and each
  `leverageBps ≤ MAX_LEVERAGE_BPS`).
- **`LaunchFairV4Distributor.process(token, minOuts[])`**: add a `Perps` branch. For each
  leg (skipping legs whose `marketOpen(market)` is false — hold that WETH):
  1. Compute the leg's WETH portion by `weightBps`.
  2. Convert WETH → `venue.marginToken()` if they differ (reuse the existing `_buyAsset`
     swap path).
  3. `venue.increasePosition(market, isLong, margin, leverageBps)` → store/refresh `posId`.
- **New keeper action `realize(token, minOuts[])`** (processor-gated, like `process`): for
  each open leg, `venue.realizeProfit(posId, minOut)` → collect the settlement token →
  convert to the tracker's reward token (WETH) if needed → fund the dividend tracker exactly
  as Reward mode does (`IERC20(reward).forceApprove(token, out)` → holders claim).
- **Liquidation recovery:** if `positionValue(posId).open == false`, the next `process()`
  re-opens the leg with fresh margin. No manual intervention, no principal at stake.

All keeper entry points stay **processor-gated** (`isProcessor`), and every swap/realize
carries a `minOut` (slippage/MEV guard), consistent with the existing Distributor.

---

## 6. Keeper loop (off-chain, extends the flagship/rh-keeper pattern)

```
every cycle, per Perps-mode token:
  • process(): deploy pendingWeth as margin across open-market legs (skip closed markets)
  • on a schedule / profit threshold: realize() → skim profit → distribute
  • monitor positionValue(): re-open any liquidated leg next process()
```

**Rule-based, minimal discretion:** realize on a fixed cadence or when unrealized profit
exceeds a threshold — the keeper decides *timing*, never *direction/leverage* (those are the
frozen leg config). That keeps the trust surface small.

---

## 7. Market-hours & stock-specific realities

- **Hours:** `marketOpen(market)` gates open + realize. When a stock market is closed, the
  keeper simply **holds the WETH in `pendingWeth`** until it reopens; already-realized
  profit can still be distributed. (If the venue offers 24/7 synthetics, hours are always
  open — the gate just no-ops.)
- **Funding:** stock perps charge funding; it nets out of PnL automatically (the venue
  handles it) — it just means the "reward" is *funding-adjusted* leveraged performance.
- **Oracle:** an equity price feed is the venue's dependency; the reward side never touches
  it directly, but a bad feed = bad PnL. Assumed reliable.
- **Regulatory:** the venue's concern (who can access RWA stock perps, KYC, jurisdictions).
  The reward mechanism is venue-agnostic.

---

## 8. Risk model

| Risk | Bound / mitigation |
|---|---|
| **Holder principal** | Never at risk — margin is fees. Worst case: a reward round pays 0. |
| **Leverage / liquidation** | Capped by `MAX_LEVERAGE_BPS` (mode-enforced). A liquidation wipes that leg's *margin* (fees) for the round; the leg re-opens next cycle. |
| **Keeper discretion** | Rule-based realization; keeper is processor-gated and can only time realizations, not change the frozen basket. |
| **Venue trust** | **The big one.** The stock-perp venue is a new external dependency — its solvency, oracle, funding, and liquidation logic are assumed correct. A compromised/insolvent venue can lose the deployed margin (fees, not principal). The venue itself must be audited and trustworthy. |
| **Slippage / MEV** | `minOut` on every convert / realize / close. |
| **This whole mode** | A large new surface (leverage + external venue + keeper). Needs **its own audit**, separate from the flagship flywheel. |

---

## 9. Sequencing (hard dependency order)

1. **Build the EVM stock-perp venue** on Robinhood Chain implementing `IPerpsVenue`
   (markets + equity oracle + margin + liquidation + hours). ← blocks everything.
2. **Add Perps mode**: `LaunchTokenV2.Mode.Perps` + leg config + Distributor `process`/
   `realize` branches + the keeper's open/realize loop.
3. **Audit the pair** (venue + reward mode) together — leverage/liquidation is the crux.
4. Frontend: a basket picker at launch + a "leveraged stock rewards" display on the token
   page (reuse the existing Reward/claim UI; the claimable is WETH/stable).

---

## 10. Open decisions (for you to pin before build)

1. **Settlement/margin token** — WETH, or a stablecoin (USDC-like)? Determines what holders
   claim and whether `process`/`realize` need a WETH↔stable swap leg.
2. **`MAX_LEVERAGE_BPS`** — the mode-enforced ceiling (the single biggest reward-vs-liquidation
   knob). E.g. cap at 5×.
3. **Realization policy** — fixed cadence (e.g. weekly) vs a profit threshold vs both.
4. **Leg mutability** — frozen at launch (recommended, transparent) vs dev-tunable.
5. **Reward token to holders** — WETH vs the stablecoin.
6. **Market set** — which RWA stock markets the venue lists (and thus which baskets are
   possible).

---

## TL;DR
It's the same `process → realize → dividend-tracker` flow as Reward mode, with "swap to a
reward ERC20" replaced by "deploy fee margin into a frozen basket of leveraged stock-perp
legs, skim PnL." Fully on-brand for a Robinhood chain, principal-safe by construction, but
gated on an EVM stock-perp venue existing to `IPerpsVenue`, and it needs its own audit.
