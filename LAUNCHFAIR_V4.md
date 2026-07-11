# LaunchFair V4 (mode-token launchpad) — logic & security review

Scope: the Uniswap-V4 mode-token stack in `src/v2/` + `src/v2/v4/`.

| Contract | Role |
|---|---|
| `LaunchTokenV2` | The token. ERC20 + launch guard + dividend tracker (Reward/Increasing) + lottery tickets. |
| `TokenDeployerV2` | CREATE2 factory (keeps the launchpad under the 24KB code limit). |
| `LaunchFairV4` | Launchpad — creates a token, opens its V4 pool, locks liquidity, wires the mechanism. |
| `LaunchFairV4FeeLocker` | Owns each token's LP forever; on `claim` collects fees, burns the sell side, splits the buy side. |
| `LaunchFairV4Distributor` | Turns mechanism WETH into holder rewards (buyback) or a lottery draw. |
| `FeeSplitConfig` | The 3/5/10% fee tiers and how the buy-side WETH splits (treasury/dev/mechanism). |
| `LiquidityMath` | Single-sided liquidity amounts (copied from Uniswap's audited `LiquidityAmounts`). |

Everything is **immutable and mostly permissionless** — no proxy, no pause. The only privileged roles are an `owner` (wiring + fee-tier tuning) and a `drawOperator` (the lottery keeper). Tests: 75/75 green; all contracts well under EIP-170 (24,576 B).

---

## 1. Architecture

```
                         creator pays creationFee + picks mode/fee
                                        │
                                        ▼
                              ┌──────────────────┐   deploy(CREATE2)   ┌───────────────┐
                              │   LaunchFairV4   │────────────────────▶│ TokenDeployerV2│──▶ LaunchTokenV2
                              │   (launchpad)    │                     └───────────────┘
                              └──────────────────┘
                                 │  init V4 pool, compute single-sided liquidity,
                                 │  send full supply to the locker, lock it, wire mechanism
                                 ▼
   buys/sells ──▶ Uniswap V4 pool ──(LP fees)──▶ ┌───────────────────────┐
                        ▲                          │ LaunchFairV4FeeLocker │  claim(token) (permissionless)
                        │ liquidity locked forever │  • burn sell-side token│
                        └──────────────────────────│  • split buy-side WETH │
                                                    └───────────┬───────────┘
                                    treasury  ◀── dev ◀──────────┤ (FeeSplitConfig: treasury == dev)
                                                                 │ mechanism WETH
                                                                 ▼
                                                    ┌───────────────────────────┐
                                                    │  LaunchFairV4Distributor  │
                                                    │  Reward/Increasing/Burn:  │  process(token) buyback
                                                    │    swap WETH→asset (V3/V4)│  → fund dividends / burn
                                                    │  Lottery:                 │  commitDraw → settleDraw
                                                    │    pot = accrued WETH     │  → pay drawn winner
                                                    └───────────────────────────┘
```

The **keeper** (off-chain) drives liveness: it calls `claim` → `process` (or the lottery `commitDraw`/`settleDraw`) → pushes rewards. Every function it calls is permissionless **except the draw**, which is gated to the keeper (`drawOperator`).

---

## 2. The fee / economic model

Buys and sells are taxed by the pool's fee tier. The two sides are treated differently:

- **Sell side** → paid in the token → **burned** (deflationary, and no WETH sell pressure).
- **Buy side** → paid in WETH → **split** three ways by `FeeSplitConfig`:

```
pool fee   dev     treasury   mechanism   (as % of the trade)
3%         0.5%    0.5%       2.0%
5%         0.75%   0.75%      3.5%
10%        1.0%    1.0%       8.0%
```

Rule: **treasury == dev**, both always paid in WETH; the mechanism keeps the remainder (**≥ 20%** of the fee, enforced in `_setSideBps`). The mechanism WETH is what funds rewards / the lottery pot. Higher fee tiers hand holders a bigger share.

`splitOf` floors treasury and dev identically and gives the rounding remainder to the mechanism, so no wei is lost.

---

## 3. Component logic

### 3.1 `LaunchTokenV2` — the token

Five modes, fixed at construction:

- **Base** — plain fair launch (not used on V4; the launchpad rejects it — Base stays on V1/V3).
- **Reward** — holders earn a **dev-chosen external token**, funded by fee buybacks.
- **Increasing** (a.k.a. Redistribute) — holders earn **this token** back, pro-rata.
- **Burn** — fee buybacks buy back and **burn** this token.
- **Lottery** — buys earn session **tickets**; a random winner takes the pot.

**Dividend tracker (Reward / Increasing).** Classic *magnified-dividend-per-share*:

- A holder's `share` == their balance, unless excluded or below `minHoldForRewards` (then 0). Plumbing (pool, PM, locker, launchpad, distributor, this contract) is excluded.
- `fundRewards(amount)` pulls the distribution asset and does `magnifiedDividendPerShare += amount * 2¹²⁸ / totalShares`.
- `withdrawableDividendOf = accumulative − withdrawn`, where `accumulative = (magnifiedDividendPerShare · share + correction) / 2¹²⁸`. On every share change, `correction` is adjusted so already-accrued dividends are preserved.
- `processAccount` pays a holder their own owed amount, **updating `withdrawnDividends` before the transfer (CEI)** — so it can't double-pay and is reentrancy-safe. `processAccounts` batches it (keeper auto-push); `claim` is the self-service fallback.

Shares are updated on transfer **without touching balances**, so the V4 pool is unaffected (V3/V4 can't rebase, so rewards are claimable, not auto-compounding).

**Launch guard.** During `limitEndBlock` (L1-block based), non-exempt wallets can't exceed `maxWalletAmount` (anti-snipe). Plumbing is limit-exempt.

**Lottery tickets.** In `_update`, tickets track **tokens bought this session and still held**:
- a **buy** (transfer *from* `buySource`, the PoolManager) adds `ticketsOf[epoch][to] += value`;
- any **move out** of a wallet — sell (to the pool), transfer, or burn — removes `min(value, held)` from the sender's tickets.

So selling drops your odds to zero, a buy→sell round-trip nets nothing, and a receiver only earns tickets by buying from the pool (transfers can't launder tickets). Tickets are per-session; `advanceLotteryEpoch` (distributor-only) resets them via a fresh epoch. `TicketsChanged(epoch, holder, newTickets)` is emitted on every change so the keeper/verifier can reconstruct final balances.

Set-once launchpad wiring: `setPool`, `setBuySource`, `setLotteryOperator`. `owner()` returns `address(0)` (renounced appearance). `contractURI()` is a plain bot-readable URL; every metadata field is also a plain getter.

### 3.2 `TokenDeployerV2` — factory

`deploy(params, salt)` does `new LaunchTokenV2{salt}(...)` with **`msg.sender` (the launchpad) as `launchpad_`**. So the token trusts the *launchpad*, not the factory, and mints its whole supply to the launchpad. Split out purely to keep the launchpad under 24KB.

### 3.3 `LaunchFairV4` — launchpad

`createToken(params)` (payable, `nonReentrant`):
1. Charge the creation fee (`msg.value ≥ creationFeeWei`, capped by `MAX_CREATION_FEE_WEI`), reject Base mode, **sanitize metadata** (`_validate`: ≤256 chars, no control chars / `"` / `\` — prevents breaking the token's JSON/OG page).
2. Validate the reward/prize asset (Reward requires one; Lottery may optionally have one). For a **V3** reward/prize, require the `WETH/asset` pool at that fee tier to exist (`v3Factory.getPool ≠ 0`) so the buyback can't be permanently un-routable.
3. Deploy the token (CREATE2, `salt = keccak256(msg.sender, userSalt)` — **namespaced by creator**, so no cross-user address collision or front-run).
4. `_launchOnV4`: initialize the V4 pool, compute the single-sided liquidity for the full supply, exclude plumbing from dividends + the launch guard, **send the supply to the locker and lock it forever**, then wire the mechanism:
   - **Reward** → register the reward token's buyback venue (V3 or V4).
   - **Lottery** → `setBuySource(PoolManager)` + `setLotteryOperator(distributor)`, and if a prize token was chosen, register its venue too.
   - **Increasing / Burn** → register the token's **own** pool as the buyback venue.
5. Creation fee → treasury; refund the excess to the creator (both after state changes, inside `nonReentrant`).

### 3.4 `LaunchFairV4FeeLocker` — LP owner + fee router

- `lockLiquidity` (launchpad-only, once): adds the single-sided position via the PoolManager `unlock`/`modifyLiquidity` flow. **No decrease path exists — liquidity is locked forever.**
- `claim(token)` (permissionless, `nonReentrant`): pokes the position with 0 liquidity to accrue fees, `take`s them, then:
  - token-side fees → `burn`,
  - WETH-side fees → `splitOf` → treasury + dev (`creatorOf`, or treasury if unknown) + mechanism → transfer to the distributor and `notify` it.
- V4 deltas are settled in `unlockCallback`, which is gated to `msg.sender == poolManager`.

### 3.5 `LaunchFairV4Distributor` — rewards + lottery

**Buyback path (Reward/Increasing/Burn).** `process(token, minOut)` (permissionless, `nonReentrant`):
`pendingWeth → 0` (CEI), then `_buyAsset(token, asset, wethIn)` routes the swap by the registered venue — **V3** (`SwapRouter02.exactInputSingle`) or **V4** (`PoolManager.unlock` → `swap` → settle/take) — then `if (out < minOut) revert`. Finally `fundBurn` (Burn) or `fundRewards` (Reward/Increasing). Reverts for Base/Lottery.

**Lottery path.** The pot is the accrued mechanism WETH. Two-phase, powerball-style:
1. `commitDraw(token, drandRound)` (operator-only): requires the current session has tickets, then **advances the epoch (closing ticket sales), reserves the pot** as `pd.prize`, and locks the draw to a **future drand round** whose randomness can't yet be known. Buys after this count toward the next session.
2. `settleDraw(token, randomness, winner, cumulativeStart, minPrizeOut)` (operator-only, `nonReentrant`): derives `winningTicket = keccak256(randomness, token, round) % totalTickets` **on-chain**, checks the winner (see §4.1), records the `Draw`, and pays the reserved prize — **WETH**, or a **dev-chosen prize token** bought with the pot on the same V3/V4 venue (`minPrizeOut` guards that swap).
3. `cancelDraw(token)` (operator-only): recovery for a stuck draw — returns the reserved pot to `pendingWeth`.

Draw history is on-chain: `drawCount(token)` + `draws(token, i)` return `{epoch, round, randomness, winner, prize, totalTickets, winningTicket, timestamp}`, re-verifiable off-chain from `TicketsEarned` events + the drand beacon.

**Randomness = drand.** The keeper commits to a future drand round (its BLS-signed beacon doesn't exist yet, so it can't be known or ground), then settles once it's public. `prevrandao` on this chain is constant, so it can't be used.

**Self-paying & self-funding.** The prize is **pushed** to the winner inside `settleDraw` — there is no claim step. Meanwhile new buy-fees keep flowing to `pendingWeth`, which becomes the **next** session's pot, so rounds fund themselves with no extra plumbing. A keeper is still required for *timing* — someone has to bring the drand beacon on-chain (the contract can't fetch it) and pick the commit round — but the payout itself is automatic.

---

## 4. Security review

**What's solid:** every fund-moving function is `nonReentrant` **and** follows checks-effects-interactions; the V4 unlock callbacks are gated to the PoolManager; metadata is sanitized; the CREATE2 salt is namespaced by creator (no front-run/collision); the fee split guarantees the mechanism ≥ 20% and loses no wei; the dividend tracker is the standard, well-trodden magnified-dividend pattern; `process` can't touch a lottery pot (reverts for Lottery) and the pot has no admin drain.

Findings below, most-important first. None is a "funds can be stolen by anyone" bug; the notable ones are trust/economic and a known slippage TODO.

### 4.1 [MEDIUM · trust] The lottery winner is chosen by the operator; the on-chain check does **not** prove correct selection

`settleDraw`'s guard is:
```solidity
if (winnerTickets == 0 || winningTicket < cumulativeStart
    || winningTicket >= cumulativeStart + winnerTickets) revert BadProof();
```
The operator supplies both `winner` and `cumulativeStart`. Setting **`cumulativeStart = winningTicket`** satisfies the check for **any** ticket holder with `winnerTickets > 0` (then `wt ≥ wt` and `wt < wt + winnerTickets`). So the on-chain check only guarantees *"the named winner holds ≥ 1 ticket in the drawn epoch"* — **not** that they own the drawn ticket.

Consequences: a malicious or compromised `drawOperator` could direct the prize to any ticket holder (e.g., an address it controls that bought a minimal ticket **and still holds it** — sold-out addresses now have zero tickets and are rejected). No funds leave the current-holder set, and it is **publicly detectable** (anyone recomputes the true winner from `TicketsChanged` + the drand beacon), but on-chain it is not prevented.

Today this is acceptable *because* the operator is our own keeper and the draw is auditable — but it should be stated plainly, not sold as a trustless proof. Options, if you want to reduce trust:
- Enforce a **canonical on-chain ticket ordering** (e.g., a running cumulative index emitted/stored at buy time) and check `cumulativeStart` against it — costs gas per buy.
- Switch to **winner-claims-with-a-Merkle-proof**: the operator posts a Merkle root of `(offset → buyer)` at settle; the winner claims by proving membership at `winningTicket`.
- Keep the trusted-keeper model and **document** it (multisig/hardened key for the operator; a public verifier script).

### 4.2 [MEDIUM · slippage] Buybacks and token-prize swaps run with `minOut = 0` from the keeper

`process` and `settleDraw` both accept a `minOut`/`minPrizeOut`, but the keeper currently passes `0`, so the WETH→asset swaps (reward buybacks **and** lottery token prizes) can be **sandwiched**. The contracts are fine — wire a **V3/V4 quoter** in the keeper and pass a real minimum before real value flows. (Already tracked as the pre-mainnet TODO.)

### 4.3 [MEDIUM · integration] `buySource = PoolManager` assumes the router `take`s tokens **directly to the buyer**

Tickets accrue on `PoolManager → wallet` transfers. If the production swap router `take`s the output **to itself** and then forwards to the user, the **router** earns the tickets (and could even become the drawn "winner"), while the buyer gets none. Verify the router used on this chain settles output straight to the recipient; if not, exclude that router (and consider crediting the ultimate recipient instead). The direct-`take` pattern (used by the standard V4 router and the test harness) works correctly.

### 4.4 [RESOLVED] Tickets now track holding, not just buy volume

*Previously* tickets rewarded buy volume and were kept after selling, so they were wash-farmable and the winner need not still hold. **Fixed:** a move out of a wallet (sell/transfer/burn) now removes tickets, so a `buy → sell` round-trip nets zero, a fully-sold holder has zero odds (and is rejected on-chain by the `winnerTickets > 0` check), and only current holders of this session's buys are eligible. Tickets = tokens bought this session and still held.

### 4.5 [LOW · griefing] Permissionless `fundRewards` + tiny `totalShares` can inflate `magnifiedDividendPerShare`

`fundRewards` is permissionless. Funding a large amount while `totalShares` is very small spikes `magnifiedDividendPerShare`; a later large share increase computes `magnifiedDividendPerShare * add`, which could **overflow and revert** (a DoS on transfers/share syncs). It requires attacker capital and is **unreachable via normal fee revenue** (would need an absurd distributed-per-share ratio), and for Increasing mode the attacker burns their own tokens. Consider a minimum `totalShares` (or minimum add) before accepting a distribution, or a sanity cap.

### 4.6 [INFO · token quality] Dev-chosen reward/prize tokens aren't validated for standard behavior

The launchpad checks a **pool exists**, not that the token behaves. A **fee-on-transfer / rebasing** reward token would under-deliver vs. the recorded dividend accounting (holder shortfall); a pathological token could otherwise misbehave. Reentrancy is already guarded. Mitigate with a UI warning or an allowlist of "known-good" reward assets.

### 4.7 [INFO · recoverability] A stuck lottery pot has no admin recovery if the operator key is lost

The pot lives in the distributor and is moved only by `settleDraw`/`cancelDraw` (operator-only) — good for trustlessness, but if the operator key is lost, the pot is stuck forever. Consider an **owner, time-locked** recovery as a backstop (trade-off against trustlessness).

### 4.8 [INFO] Minor / housekeeping

- `LaunchTokenV2.pool` is **vestigial in V4** (the distributor uses its own registered buyback key); it's never set. Harmless dead field.
- **Owner powers** (set treasury, tune `sideBps` up to a 40%/side cap, set `drawOperator`/`registrar`, one-time locker/distributor wiring) should sit behind a **multisig**. Most setters are one-shot.
- **Reward-token accounting truncates** to 1-wei dust (kept, not lost) — expected.

---

## 5. Pre-mainnet checklist

- [ ] **Deploy script** for the V4 stack + wiring (locker↔distributor↔launchpad, `drawOperator`, the SwapRouter02 `0xCaf681a66D020601342297493863E78C959E5cb2` + V3 factory `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` addresses). *(not written yet)*
- [ ] **Keeper `minOut`/`minPrizeOut`** via a real V3/V4 quote (fixes §4.2).
- [ ] Decide the **lottery trust model** (§4.1) — keep trusted-keeper + document, or harden to on-chain/Merkle selection.
- [ ] Confirm the production **swap router's `take` recipient** (§4.3).
- [ ] Put `owner` + `drawOperator` behind a **multisig / hardened key**.
- [ ] External **audit** of the fund-custody paths (locker, distributor) before real value.
- [ ] Optional: min-`totalShares` guard (§4.5), reward-token allowlist (§4.6), owner recovery for a stuck pot (§4.7).
