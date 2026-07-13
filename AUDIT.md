# LaunchFair — Security Audit Report

**Scope:** LaunchFair V1 (Uniswap V3) + V2/V4 (Uniswap V4 mode tokens) contracts, plus the
off-chain keeper's on-chain-facing assumptions.
**Commit basis:** current working tree (post-L-01/L-02 lottery work).
**Chain:** Robinhood Chain — Arbitrum Nitro v3.11.2, chainId 4663 (EIP-2537 + KZG live).
**Compiler:** solc 0.8.26, via-IR, optimizer 200.

## Engagement summary

This review was conducted as an internal-but-independent audit: five reviewers each took a
component and worked **adversarially** (mandate: find exploitable defects, not style), with
deliberate scope overlap so findings could be cross-checked. Every candidate finding was
then put through a **verification pass** against the actual code before inclusion, and each
confirmed finding was remediated and covered by a regression test where practical.

The headline result: the lottery's advertised "fully trustless" property was **not enforced
on-chain** — a malicious/compromised draw operator (or the owner, via a swappable randomness
source) could **steal any lottery pot**. This was the single most important finding; it and
all other confirmed High/Medium issues are now fixed. The dividend/reflection accounting and
the locked-liquidity design held up under attack.

### Reviewer coverage
| # | Component | Verdict |
|---|-----------|---------|
| 1 | `DrandBLS`, `LaunchFairVRFCoordinator` | crypto sound; 1 High (coordinator DoS) + 1 Low |
| 2 | `LaunchFairV4Distributor` | winner-*set* proof sound; **1 Critical** (round grinding) + Medium/Low |
| 3 | `LaunchTokenV2` | dividend + ticket invariants sound; Low/Info only |
| 4 | `LaunchFairV4` + locker + split + math + deployer | no theft path; launch-DoS + reward-key Lows |
| 5 | V1 stack + cross-cutting | confirmed Critical independently; V1 callback drain + centralization |

## Severity key

- **Critical** — direct theft or loss of user funds, or full break of a core security guarantee.
- **High** — theft/loss under specific conditions, or cheap indefinite denial of a core feature.
- **Medium** — bounded fund risk, meaningful griefing, or excessive trust not matching the docs.
- **Low** — limited-impact bugs, edge-case DoS, or config-dependent issues.
- **Info** — hardening, documentation accuracy, or theoretical-only concerns.

Status: **Fixed** (remediated in this tree) · **Fixed (V1 redeploy)** (source fixed; the
deployed immutable V1 contract must be redeployed to benefit) · **Acknowledged** (accepted
risk / documented / not economically exploitable).

## Findings summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| C-01 | Critical | Lottery round not bound to the future → operator grinds the seed to steal the pot | **Fixed** |
| H-01 | High | Coordinator fan-out is an unbounded, permissionless loop → settle-blocking DoS | **Fixed** |
| M-01 | Medium | `setVrf` re-pointable → owner can swap the randomness source and rig draws | **Fixed** |
| M-02 | Medium | `cancelDraw` allowed after the beacon is revealed → operator vetoes outcomes | **Fixed** |
| M-03 | Medium | V1 `uniswapV3SwapCallback` trusts `data` → arbitrary WETH-drain primitive | **Fixed (V1 redeploy)** |
| L-01 | Low | `round` truncated to `uint64` in the beacon message vs full `uint256` key | **Fixed** |
| L-02 | Low | V4 reward pool key registered unvalidated (asymmetric with the V3 path) | **Fixed** |
| L-03 | Low | Prize-token payout can wedge a now-uncancelable draw | **Fixed** |
| L-04 | Low | V4 pool pre-initialization bricks a launch (H-01 was over-claimed for V4) | **Acknowledged** |
| L-05 | Low | V1 partial-fill dev buy leaves WETH stuck in the launchpad | **Fixed (V1 redeploy)** |
| L-06 | Low | `cancelDraw` voids a closed session's tickets | **Acknowledged** |
| L-07 | Low | V4 fee split is adjustable against already-accrued fees (doc over-claimed) | **Acknowledged** |
| L-08 | Low | Fee-on-transfer / rebasing reward token under-funds the tracker | **Fixed** |
| L-09 | Low | `processAccounts` batch reverts wholesale if one recipient's transfer reverts | **Fixed** |
| I-01 | Info | Treasury can reassign any token's dev fee stream (unbounded CTO) | **Acknowledged** |
| I-02 | Info | `fundRewards` reentrancy / sole-shareholder div-by-zero / non-FoT credit | **Fixed** |
| I-03 | Info | `from == buySource` aliases the constructor mint when `buySource` unset | **Fixed** |
| I-04 | Info | `process` with `minOut==0` and a dead swap burns the pending pot | **Fixed** |
| I-05 | Info | Doc §9 states `Σ balanceOf == totalSupply`; it is `≤` (dust favors the contract) | **Acknowledged** |
| I-06 | Info | `int256` cast in dividend math can wrap (unreachable at realistic supply) | **Acknowledged** |
| I-07 | Info | Per-token `pendingWeth` trusts the locker; cross-token WETH commingled | **Acknowledged** |
| I-08 | Info | Creation reverts if treasury/creator rejects ETH; V4 locker strands dust | **Acknowledged** |

---

## Critical

### C-01 — Lottery draw is not bound to a future drand round; the operator grinds the seed to steal the pot · **Fixed**
`src/v2/v4/LaunchFairV4Distributor.sol` `commitDraw`, winner derivation in `settleDraw`.

The lottery's entire "no operator discretion" guarantee rests on the committed drand round
being in the **future** (its beacon not yet produced). The docs and code comments state this,
but `commitDraw(token, drandRound)` accepted **any** `drandRound` with no on-chain check, and
the coordinator verifies a valid BLS signature for **any** round, past or future. Every past
drand quicknet beacon is public.

**Exploit:** the winning ticket is `keccak256(randomness, token, round) % totalTickets`, and
`round` is an input to the hash — so each candidate round yields an independent winner over
the public, frozen ticket set. A malicious/compromised `drawOperator` iterates already-revealed
rounds off-chain, finds one whose winner is its own (or a confederate's) ticket-holding
address, and calls `commitDraw(token, thatRound)`. `settleDraw` then pays that address using a
perfectly honest, complete holder set — so L-01's completeness proof passes and every on-chain
re-verification artifact checks out. This is **direct theft of user-funded pots** and a total
break of the trustlessness claim. (L-01 secured the *set*; nothing secured the *round*.)

**Fix:** `commitDraw` now derives the round currently being produced from `block.timestamp`
using drand quicknet's baked-in genesis (`1692803367`) + period (`3s`) and requires
`drandRound > currentRound` (`RoundNotFuture`). A round strictly in the future cannot have a
known beacon, restoring the "seed fixed before it existed" property on-chain.
*Residual assumption:* `block.timestamp` ≈ wall-clock (honest sequencer). A sequencer that
sets timestamps far in the past could reopen grinding — a much stronger adversary than a hot
keeper key, and noted as a trust boundary. Regression: `test_lottery_commitRejectsPastRound`.

---

## High

### H-01 — Coordinator fan-out is an unbounded, permissionless loop → any lottery draw can be blocked forever · **Fixed**
`src/v2/v4/LaunchFairVRFCoordinator.sol`.

`requestRandomness(round)` was permissionless and unbounded; `postRandomness` copied
`_roundRequests[round]` into memory and iterated it **atomically with the state write**. An
attacker who saw a committed round (public via `DrawCommitted`) could spam `requestRandomness`
a few thousand times before the beacon existed, making every `postRandomness(round, ·)` revert
out-of-gas → `randomnessOf[round]` never set → `settleDraw` reverts `RandomnessNotReady`
forever. Cheap on an L2, and repeatable against each fresh round. `try/catch` didn't help — the
array length itself is the weapon.

**Fix:** the coordinator is now **pull-only and O(1)**. `postRandomness` verifies the
signature, stores `keccak256(signature)`, and emits — no per-round list, no fan-out loop.
`requestRandomness` just returns an id + emits an event. Consumers (the distributor's
`settleDraw`) read `randomnessOf(round)` directly, which they already did as the primary path.
Nothing an attacker can spam affects the O(1) store.

---

## Medium

### M-01 — `setVrf` is re-pointable → the owner can swap the randomness source and rig every draw · **Fixed**
`src/v2/v4/LaunchFairV4Distributor.sol` `setVrf`.

Unlike `setLocker`/`setRegistrar` (set-once), `setVrf` could be re-pointed by the owner at any
time to a coordinator it controls returning attacker-chosen `randomnessOf`. Combined with C-01,
the "trustless drand" property was not enforced against the owner at all.
**Fix:** `setVrf` is now **set-once** (`vrfLocked`). Regression: `test_setVrf_setOnce`.

### M-02 — `cancelDraw` after the beacon is revealed lets the operator veto/resample outcomes · **Fixed**
`src/v2/v4/LaunchFairV4Distributor.sol` `cancelDraw`.

`cancelDraw` only checked `onlyDrawOperator` + `active`. After a committed (future) round's
beacon became public, the operator could compute the winner and, if unfavorable, `cancelDraw`
to roll the pot forward and try again — a reveal-then-veto lever that biases outcomes and can
hold a pot hostage.
**Fix:** `cancelDraw` now reverts (`BeaconAlreadyProduced`) once `block.timestamp` has passed
the round's beacon-production time; after reveal the operator must settle to the deterministic
winner. Cancel remains available for a genuinely stuck (far-future/bad) round *before* reveal.
Regression: `test_lottery_cancelRejectedAfterBeacon`.

### M-03 — V1 `uniswapV3SwapCallback` trusts caller-supplied `data` → arbitrary WETH-drain primitive · **Fixed (V1 redeploy)**
`src/V3Launchpad.sol` `uniswapV3SwapCallback` / `_devBuy`.

The callback authorized the caller by `msg.sender == factory.getPool(token, weth, feeTier)`
where `token` came from attacker-supplied `data`. An attacker could deploy `X`, create the
canonical `(X, weth, feeTier)` pool, and swap on it with `data = abi.encode(X)`; the check
passed and the launchpad paid WETH **from its own balance** to the attacker's pool. A drain of
any WETH the launchpad held — normally 0, but the partial-fill leftover (L-05) makes that
non-zero and thus stealable.
**Fix:** the callback now authorizes against a transient `_devBuyPool` set only for the
duration of the launchpad's own dev-buy swap, not against `data`. **V1 is deployed and
immutable — this requires redeploying `V3Launchpad` to take effect.**

---

## Low

- **L-01 — `round` truncated to `uint64` in the beacon message** (`DrandBLS.verifyBeacon`) vs the
  full `uint256` storage key: rounds sharing the low 64 bits would accept the same signature.
  Unreachable by real drand (rounds ≪ 2⁶⁴) but a latent correctness gap. **Fixed:**
  `verifyBeacon` rejects `round > type(uint64).max`.
- **L-02 — V4 reward pool key unvalidated** (`LaunchFairV4.createToken`): the V3 reward path
  checks the pool exists; the V4 path passed `rewardPoolKey` straight through. A key not pairing
  WETH with the reward token strands that token's `pendingWeth` (no cross-token drain — confirmed).
  **Fixed:** the V4 key must now pair `weth` with `rewardToken` (`InvalidRewardPool`), symmetric
  with V3.
- **L-03 — Prize-token payout can wedge a now-uncancelable draw** (`settleDraw`): with M-02
  fixed, a hostile prize token / un-receivable winner / broken venue would permanently lock the
  pot. **Fixed:** the token-prize buy+send runs in a `try/catch` self-call; on any failure the
  draw finalizes by paying the **WETH pot** to the winner (full value; a sandbox/sandwich gains
  nothing since the swap rolls back). Regression: `test_lottery_tokenPrize_slippageFallsBackToWeth`.
- **L-04 — V4 pool pre-initialization bricks a launch** (`LaunchFairV4._launchOnV4`): a
  front-runner can `poolManager.initialize` the predicted `PoolKey` (no token deploy needed),
  making `createToken` revert. The H-01 pool-poisoning defense (creator-scoped CREATE2) prevents
  token-address squatting but **not** pool pre-init, so the doc's "H-01 resolved on both stacks"
  was inaccurate for V4. **Acknowledged:** Robinhood Chain (Nitro) has no public gossip mempool,
  so only *pre-announced* launches are exposed, and the impact is DoS-only (retry with a fresh
  salt). Doc corrected. Optional future hardening: `try initialize` + accept an existing pool
  only if its price equals the launch price.
- **L-05 — V1 partial-fill dev buy leaves WETH stuck** (`V3Launchpad._devBuy`): a dev buy large
  enough to exhaust the range partially fills; the refund used the requested `devBuyWei`, stranding
  the unspent WETH (and, pre-M-03, making it stealable). **Fixed (V1 redeploy):** `_devBuy` now
  refunds any unconsumed WETH to the creator.
- **L-06 — `cancelDraw` voids a closed session's tickets:** commit advances the epoch; cancel
  rolls the pot forward but doesn't reopen that session, so its buyers' tickets are lost.
  **Acknowledged:** with M-02, cancel is only reachable pre-reveal (bad/far-future round), it's
  operator-gated, and the pot is preserved. Documented behavior.
- **L-07 — V4 fee split adjustable against accrued fees** (`FeeSplitConfig`): `splitOf` uses the
  current `sideBps` at claim time, so an owner change applies to already-accrued-but-unclaimed
  fees (bounded: mechanism always ≥ 20%; treasury == dev). **Acknowledged:** the code makes no
  false "non-retroactive" claim; the behavior (split applies to all unclaimed fees at claim
  time, at owner-tunable but floored rates) is the documented, intended one.
- **L-08 — Fee-on-transfer / rebasing reward token under-funds the tracker** (`fundRewards`,
  Reward mode): crediting the nominal `amount` while receiving less eventually strands the last
  claimers. **Fixed:** `fundRewards` now credits the measured received delta.
- **L-09 — `processAccounts` batch reverts wholesale** on one recipient whose reward-token
  transfer reverts (e.g. a blacklist). **Fixed:** each account is now wrapped in `try/catch`;
  a bad recipient is skipped and can still `claim()`.

## Informational

- **I-01 — Treasury can reassign any token's dev fee stream** (`V3Launchpad.transferCreatorByTreasury`):
  unbounded CTO, no "abandoned" gate. **Acknowledged** as an intended, fully-trusted treasury
  power (it cannot touch liquidity or holder funds); documented as such.
- **I-02 — `fundRewards` hardening:** now `nonReentrant`, credits the received delta, and
  re-reads `totalShares` after the transfer (fixes a sole-shareholder self-fund div-by-zero and
  the ERC777-reward-token reentrancy code-smell). **Fixed.**
- **I-03 — `from == buySource` aliases the constructor mint** when `buySource` is unset (0):
  safe today only because the mint recipient is excluded. **Fixed:** ticket credit now requires
  `buySource != address(0)`.
- **I-04 — `process` with `minOut==0` + dead swap burns the pot:** **Fixed** (`out > 0` required).
- **I-05 — `Σ balanceOf == totalSupply` is actually `≤`** (rounding dust accretes in the netted
  reflection pool, favoring the contract). **Acknowledged:** doc §9 corrected; the project's own
  test already asserts within a 100-wei tolerance.
- **I-06 — `int256(...)` cast in dividend math can wrap** for a single holder entitled to ≈2¹²⁷
  wei of dividends. **Acknowledged** as unreachable at any realistic supply/fee volume (same
  pattern as the widely-used Roger-Wu tracker).
- **I-07 — Per-token `pendingWeth` trusts the locker** (single commingled WETH balance).
  **Acknowledged:** `notify` is `onlyLocker` (set-once, trusted); an honest locker keeps
  `Σ pendingWeth ≤ balance`.
- **I-08 — Liveness/dust edges:** creation reverts if the owner-set treasury (or a creator smart
  wallet) rejects ETH; the V4 locker strands rounding dust (V1 burns it). **Acknowledged**
  (owner/config responsibility; cosmetic).

---

## What was checked and found sound

- **Lottery winner-*set* proof (L-01 design):** strict-ascending + `tk!=0` + `Σ==totalTickets`
  genuinely force a complete, canonical partition; the operator cannot omit, duplicate, pad, or
  reorder to steer the winner — **given a future round (C-01)**. Reviewers 2 & 3 independently
  confirmed the token maintains `Σ ticketsOf[e] == totalTickets[e]`, that no excluded/plumbing
  address can hold tickets, and that the drawn epoch is frozen at commit.
- **Dividend / reflection accounting:** no drain, no over-claim, no `_reflectionHeld` underflow,
  no `totalShares`/`Σ shareOf` desync; rounding strictly favors the contract; a holder's
  displayed balance is always fully transferable; CEI holds on all payouts.
- **Locked liquidity is permanent** on both stacks — no decrease/withdraw path exists; NFTs/
  positions can only be added.
- **V4 flash-accounting** (locker + distributor `unlockCallback`s) is `onlyPoolManager`, with
  correct settle/take delta-sign handling; V3/V4 swap slippage is caller-enforced and, post-fix,
  `process` is keeper-gated so `minOut` is meaningful.
- **DrandBLS** matches RFC 9380 / drand quicknet exactly (expand_message_xmd, hash-to-G1, the
  pairing identity, EIP-2537 encodings) — verified against a real beacon with an independent BLS
  library and end-to-end against the live chain's precompiles.
- **Fee splits** account for funds exactly (no lost/extra wei); tokens are renounced/immutable;
  metadata is validated against JSON injection.

## Verdict

The core value-custody design is sound: liquidity is unpullable, the dividend math is correct,
and the token invariants the lottery relies on hold. The audit's decisive contribution was
catching that the lottery's trustlessness was **advertised but not enforced** (C-01/M-01/M-02):
a hot keeper key or the owner could have drained pots while every public re-verification looked
legitimate. Those paths, the coordinator DoS (H-01), and the V1 WETH-drain (M-03) are now closed,
with regression tests for the lottery guards.

**Recommended before mainnet value at scale:**
1. **Redeploy `V3Launchpad`** to ship the M-03 / L-05 fixes (the live V1 instance is immutable).
2. A **second, external firm** review — especially of `DrandBLS` (hand-rolled pairing crypto)
   and the lottery timing assumptions (the `block.timestamp`/sequencer trust boundary in C-01).
3. Consider the optional hardenings noted in L-04 (V4 pool-init) and I-01 (bounded CTO).

*Contracts audited: `src/LaunchToken.sol`, `src/V3Launchpad.sol`, `src/FeeLocker.sol`,
`src/v2/LaunchTokenV2.sol`, `src/v2/TokenDeployerV2.sol`, `src/v2/v4/LaunchFairV4.sol`,
`src/v2/v4/LaunchFairV4FeeLocker.sol`, `src/v2/v4/FeeSplitConfig.sol`,
`src/v2/v4/LiquidityMath.sol`, `src/v2/v4/LaunchFairV4Distributor.sol`,
`src/v2/v4/LaunchFairVRFCoordinator.sol`, `src/v2/v4/DrandBLS.sol`.*
