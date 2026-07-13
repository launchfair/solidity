# LaunchFair — Contracts, Logic & Security Audit

A single reference for every contract in this repo: what each token type is, how the
two launchpads work, how money moves, and a security review of the whole thing.

LaunchFair is a pump.fun-style launchpad on **Robinhood Chain** (EVM L2, chainId
`4663`, gas token ETH). There are **two contract stacks**:

| Stack | For | Trades on | Contracts |
|-------|-----|-----------|-----------|
| **V1 (base)** | plain fair-launch tokens | Uniswap **V3** | `LaunchToken`, `V3Launchpad`, `FeeLocker` |
| **V2 / V4 (mode tokens)** | tokens with a reward/redistribute/lottery mechanism | Uniswap **V4** | `LaunchTokenV2`, `TokenDeployerV2`, `LaunchFairV4`, `LaunchFairV4FeeLocker`, `FeeSplitConfig`, `LiquidityMath`, `LaunchFairV4Distributor`, `LaunchFairVRFCoordinator`, `DrandBLS` |

Both stacks share the same core idea: **the full token supply is minted straight
into a single-sided liquidity position and locked forever.** There is no bonding
curve phase and no migration — a single-sided range order *is* mathematically a
constant-product bonding curve, so terminals (DexScreener/GMGN) index every token
from block one while traders still get the classic price ladder.

---

## Table of contents

1. [The token model (3 types)](#1-the-token-model-3-types)
2. [V1 stack — base fair launch](#2-v1-stack--base-fair-launch)
3. [V4 stack — mode tokens](#3-v4-stack--mode-tokens)
4. [The lottery, end to end](#4-the-lottery-end-to-end)
5. [Money flow & fee routing](#5-money-flow--fee-routing)
6. [Off-chain components (keeper + drand)](#6-off-chain-components-keeper--drand)
7. [Security audit](#7-security-audit)
8. [Trust & centralization matrix](#8-trust--centralization-matrix)
9. [Invariants & design guarantees](#9-invariants--design-guarantees)
10. [Open items / TODO before mainnet](#10-open-items--todo-before-mainnet)

---

## 1. The token model (3 types)

A V4 mode token picks exactly one mechanism at creation, fixed forever
(`LaunchTokenV2.Mode`, immutable). "Base" (mode 0) exists in the enum but is
**rejected by the V4 launchpad** — plain tokens stay on the V1/V3 stack.

| # | Type (UI name) | `Mode` enum | What holders get | Funded by | Payout cadence |
|---|----------------|-------------|------------------|-----------|----------------|
| 1 | **Redistribute** | `Increasing` (2) | more of **this** token — balance grows on its own | buy-side WETH fees, used to buy the token back on its own pool | dev-set, usually "insta" (interval 0) |
| 2 | **Rewards** | `Reward` (1) | a dev-chosen **external** token (any V3 or V4 token) | buy-side WETH fees, used to buy that token | dev-set block timer + pot threshold |
| 3 | **Lottery** | `Lottery` (3) | one random buyer wins the **whole WETH pot** (or a prize token) | buy-side WETH fees accrue into the pot | dev-set block timer + pot threshold |

Common rules across all three:

- **Buys pay their fee in WETH; sells pay their fee in the token and it's burned.**
  So the reward/pot mechanism is only ever fed by *buy* pressure, and sells are
  deflationary with no sell pressure on the pool.
- **The dev sets two gates:** `payoutThreshold` (minimum pending WETH) and
  `payoutIntervalBlocks` (a block-based timer, L1 blocks ~12s). A payout/draw only
  fires when *both* are satisfied. Redistribute typically leaves the interval at 0.
- **Nobody has to claim.** A keeper pushes rewards to wallets; Redistribute
  compounds automatically into `balanceOf`. A trustless `claim()` fallback exists.
- **`minHold`** (dev-set) keeps dust wallets from earning — below it an account
  accrues nothing and isn't pushed to.

### Why "Redistribute" is auto-compound, not a reflection tax

Classic reflection/RFI tokens are fee-on-transfer + rebasing, which **breaks
Uniswap V4** (it can't handle fee-on-transfer or balances that change without a
transfer — sells and reserves desync). LaunchFair's Redistribute instead:

- takes **no transfer tax** (the fee is the pool's swap fee, same as every mode);
- buys the token back with the mechanism WETH and folds it into holders'
  `balanceOf` via a magnified-dividend-per-share tracker;
- **excludes the pool** (and all plumbing) from the tracker, so the pool always
  reads exact raw balances — no rebase from the AMM's point of view.

The result reads like a reflection token to a holder (balance just grows) but is
fully V4-safe. See [§9](#9-invariants--design-guarantees) for the accounting
invariant that makes this sound.

---

## 2. V1 stack — base fair launch

### 2.1 `LaunchToken.sol` (132 lines)

A deliberately minimal `ERC20Burnable`:

- **No owner, no mint, no fee, no blacklist.** `owner()` returns `address(0)` so
  explorers report it renounced. Supply is fixed at construction.
- **Launch guard:** during `limitEndBlock` (set from `maxBuyBlocks`), a non-exempt
  wallet can't exceed `maxWalletAmount` (from `maxBuyBps`). Enforced in `_update`:
  `if (limitActive() && to != 0 && !limitExempt[to] && balanceOf(to)+value > maxWalletAmount) revert`.
  The launchpad exempts the pool, position manager and locker; the dev's own buy is
  **not** exempt (anti-snipe applies to the creator too).
- **`contractURI()`** returns base64-encoded ERC-7572 JSON metadata. All metadata
  strings are validated at the launchpad (see M-01) to prevent JSON injection.

### 2.2 `V3Launchpad.sol` (432 lines)

`Ownable`, `ReentrancyGuard`. Launches a token straight into a **real Uniswap V3
pool** as a single-sided full-supply range order.

**Creation flow (`_createToken`):**

1. Charge the flat `creationFeeWei` (default 0.000005 ETH, capped at
   `MAX_CREATION_FEE_WEI = 0.001 ETH`), forwarded to the treasury; excess refunded.
2. Validate every metadata string (`_validateMetadataString`: length ≤ 256, rejects
   `"`, `\`, and control chars).
3. Deploy the token with **CREATE2 salted by `keccak256(msg.sender, salt)`** — the
   griefing fix (H-01).
4. Create/initialize the V3 pool at the launch price. Handles a third party having
   pre-created the pool: if it's initialized *above* our launch price the mint would
   need WETH we don't provide, so it reverts `PoolPriceUnsafe` (retry with a new salt).
5. Mint the entire supply as a single-sided range order **to the FeeLocker** (LP NFT
   owned by the locker forever). Burn any rounding dust.
6. Register the position with the locker, emit `TokenLaunched`.
7. Optional **atomic dev buy** (`createAndBuy`): swaps the caller's extra ETH through
   the fresh pool for tokens delivered to the creator, guarded by `minTokensOut` and
   still subject to the 2% launch cap.

**Graduation** (`checkGraduation`) is **pure gamification** — a permissionless poke
that emits `Graduated` once the pool holds ≥ `graduationWethAmount` WETH. Liquidity
never moves. `curveProgress()` returns bonding progress in bps for the frontend.
The graduation target is **snapshotted per token at creation** — `setGraduationWethAmount`
(owner) only affects future tokens, never retroactive. (Live default is currently 1 ETH.)

**CTO / community takeover:** `transferCreatorByTreasury` lets the **treasury** (only)
reassign a token's `creator` — and thus its dev fee stream — to a new address. There
is no dev-initiated transfer; it's treasury-controlled.

### 2.3 `FeeLocker.sol` (147 lines)

Owns each V1 token's V3 LP NFT **forever** — there is no decrease/withdraw function,
so liquidity can never be pulled. `claim(token)` (permissionless, `nonReentrant`):

- `positionManager.collect`s accrued fees;
- **burns** the token-side fees (deflationary);
- splits the WETH-side fees **50/50 treasury/dev** (`TREASURY_SHARE_BPS = 5000`); the
  dev address comes from `launchpad.creatorOf(token)`, falling back to treasury if unset.

`onERC721Received` only accepts NFTs from the position manager.

---

## 3. V4 stack — mode tokens

### 3.1 `LaunchTokenV2.sol` (408 lines)

`ERC20Burnable` with everything V1 has (launch guard, renounced owner, plain-URL
`contractURI` pointing at `<platformWebsite>/token/<address>`) **plus** the mode
machinery. Privileged calls (`setPool`, `setBuySource`, `setLotteryOperator`,
`excludeFromDividends`, `setLimitExempt`) are `launchpad`-only and mostly set-once.

**Dividend tracker (Reward & Increasing)** — magnified-dividend-per-share:

- `shareOf[account]` == the holder's raw balance, unless excluded or below `minHold`
  (then 0). `_syncShare` keeps it current on every transfer using the **raw** balance
  (`super.balanceOf`) to avoid a circular definition.
- `fundRewards(amount)` (permissionless — normally the keeper after a buyback) pulls
  the distribution asset and bumps `magnifiedDividendPerShare`. Reverts `NoShares` if
  `totalShares == 0` (so the whole `process()` tx rolls back atomically and the WETH
  stays pending — no loss).
- **Reward mode:** the distribution asset is the external `rewardToken`; `processAccount`
  transfers it out to the wallet.
- **Increasing (Redistribute) mode:** the distribution asset is `address(this)`.
  Funded THIS-token becomes `_reflectionHeld`, a reflection pool **netted out of
  `balanceOf(this)`**. Holders' `balanceOf` returns `raw + withdrawableDividendOf`,
  so it grows with no claim. On any transfer, `_realize(from)` first folds the
  sender's accrued reflection into its real balance (so the displayed balance is
  always fully spendable), then the transfer proceeds.

**Lottery ticketing** (in `_update`): tickets track **tokens bought this session and
still held**, not just bought:

- a buy (transfer **from `buySource`**, i.e. the pool, to a wallet) **adds** tickets;
- **any** move out of a wallet — sell, transfer, or burn — **removes** tickets (down
  to zero, `cut = min(value, held)`).

So selling drops your odds to zero, a buy→sell round-trip nets nothing, and you can't
launder tickets by moving tokens between wallets (the receiver only earns tickets by
buying from the pool). `TicketsChanged(epoch, holder, newTickets)` is emitted on every
change so the keeper/anyone can rebuild the exact ticket ledger. Tickets are
per-`lotteryEpoch` and reset when a draw advances the epoch.

### 3.2 `TokenDeployerV2.sol` (49 lines)

A thin CREATE2 factory that holds the token's (large) creation bytecode, keeping the
launchpad under the **EIP-170 24KB** limit. It passes the **launchpad** (its caller)
as the token's privileged controller — the token trusts the launchpad, not this
factory.

### 3.3 `LaunchFairV4.sol` (306 lines)

The V4 launchpad. `createToken(CreateParams)`:

1. Requires `msg.value ≥ creationFeeWei`; fee ∈ {3%, 5%, 10%} (`30000/50000/100000`);
   `mode != Base`. Validates all metadata strings.
2. For **Reward**, `rewardToken` is required (≠ 0, ≠ WETH). For **Lottery**,
   `rewardToken` is optional (0 ⇒ WETH pot; else a prize token). If the reward/prize
   is on **V3**, the WETH/asset pool at `rewardV3Fee` **must already exist** (else the
   buyback would be permanently unroutable → `InvalidRewardPool`).
3. Deploys the token via `TokenDeployerV2` (CREATE2 salted by `keccak256(msg.sender, salt)`).
4. `_launchOnV4`: initializes the V4 pool at the launch price, computes single-sided
   liquidity (`LiquidityMath`), excludes plumbing (poolManager/locker/distributor) from
   dividends and the launch guard, transfers the full supply to the locker, and calls
   `locker.lockLiquidity`.
5. Wires the mechanism:
   - **Lottery** → `setBuySource(poolManager)`, `setLotteryOperator(distributor)`,
     and if a prize token was chosen, register its V3/V4 buyback venue.
   - **Reward** → register the reward token's V3/V4 buyback venue.
   - **Redistribute** → `registerBuyback(token, ownPoolKey)` (buys the token back on
     its own pool).
   - Apply `payoutThreshold` / `payoutIntervalBlocks` if set.
6. Fee → treasury, refund the rest, emit `TokenLaunchedV4`.

All of this happens in one `nonReentrant` call, so the pool is initialized and the
supply locked atomically — no price gap for a sandwich between init and mint (hence
`amount*Min = 0` is safe).

### 3.4 `LaunchFairV4FeeLocker.sol` (219 lines)

The V4 analog of `FeeLocker`. Owns each token's single-sided V4 position **forever**
(added once in `lockLiquidity`, no decrease function). `claim(token)` (permissionless,
`nonReentrant`) uses V4 flash-accounting (`unlock`/`unlockCallback`):

- pokes the position with 0 liquidity to accrue fees, then takes them;
- **burns** the token (sell) side;
- splits the WETH (buy) side by the pool's fee tier (`FeeSplitConfig.splitOf`):
  **treasury = dev** (both in WETH), **remainder → mechanism**. Dev from
  `launchpad.creatorOf(token)`, falling back to treasury. Mechanism WETH is
  transferred to the distributor and `notify`'d.

`setLaunchpad` / `setDistributor` are **set-once**; `setTreasury` / `setSideBps` are
owner-tunable.

### 3.5 `FeeSplitConfig.sol` (69 lines)

Per-tier split of the buy-side WETH fee. Higher tiers hand holders a bigger share:

| Pool fee | dev | treasury | mechanism (rewards) | stored `sideBps` |
|----------|-----|----------|---------------------|------------------|
| 3% | 0.5% | 0.5% | 2.0% | 1667 |
| 5% | 0.75% | 0.75% | 3.5% | 1500 |
| 10% | 1.0% | 1.0% | 8.0% | 1000 |

`sideBps` is per-side (treasury == dev) as bps **of the collected fee**. Owner can tune
via `setSideBps`, but the guard `side*2 ≤ 8000` means **the mechanism always keeps
≥ 20%**.

### 3.6 `LiquidityMath.sol` (26 lines)

The two single-sided liquidity functions (`getLiquidityForAmount0/1`) copied verbatim
from Uniswap's audited `LiquidityAmounts` library so we don't import test utilities.

### 3.7 `LaunchFairV4Distributor.sol` (469 lines)

Turns accrued mechanism WETH into holder rewards, and runs lottery draws. `Ownable`,
`ReentrancyGuard`, `IUnlockCallback`, `IRandomnessConsumer`.

**Buyback (`process(token, minOut)`, keeper-gated, `nonReentrant`):**

- callable only by the **owner or an allowlisted processor** (`isProcessor`), so an
  untrusted caller can't force a `minOut = 0` buyback and sandwich it (M-02);
- gated by `pendingWeth > 0`, `≥ payoutThreshold`, `timerElapsed`, `registered`, and
  `mode ∈ {Reward, Increasing}` (Base has no mechanism; Lottery uses draws);
- zeroes `pendingWeth`, resets the block timer, buys `distributionAsset()` with the
  WETH on the token's registered venue, enforces `out ≥ minOut` (`Slippage`), then
  `fundRewards`.

The buyback **venue is registered once at launch and then frozen** (`registerBuyback*`
reverts `AlreadyRegistered`), and `setRegistrar` is set-once (L-03).

**Buyback venue** (`Venue.V4` / `Venue.V3`, per token): V4 pools swap via
`poolManager.unlock` flash-accounting (`unlockCallback`); V3 pools swap via
`SwapRouter02.exactInputSingle`. So a reward/prize token is **not restricted to V4** —
most established tokens on this chain trade on V3.

**Lottery draws:** `commitDraw` / `settleDraw` / `cancelDraw` — covered in [§4](#4-the-lottery-end-to-end).

### 3.8 `LaunchFairVRFCoordinator.sol` + `DrandBLS.sol`

**Our own reusable randomness coordinator** — so we never pay a third-party VRF, and
one contract serves every lottery. The entropy is **drand quicknet** (a public,
BLS-signed beacon; free). Flow:

1. a lottery `requestRandomness(round)` for a **future** drand round (its beacon
   doesn't exist yet, so it can't be known or ground in advance) → returns a `requestId`;
2. **anyone** `postRandomness(round, signature)` **once** per round — the coordinator
   **verifies the drand BLS signature on-chain** (`DrandBLS`, EIP-2537) and rejects
   anything that isn't the real beacon, then stores `keccak256(signature)` and **pushes**
   it to every consumer waiting on that round (self-emitting);
3. any consumer whose push reverted can still **pull** `randomnessOf(round)`.

Because the signature is verified on-chain, `postRandomness` is **permissionless and
trustless** — there is no `poster` role and no owner; a forged beacon simply reverts, so
no one (keeper included) can substitute a value of their choosing. A round's value is
**write-once** (`AlreadyPosted`), identical for every consumer, and re-derivable by anyone
from the public drand signature. `_fulfill` uses **CEI + try/catch** (marks the request
fulfilled before the external call), so one reverting consumer never blocks the fan-out.

**`DrandBLS.sol`** implements the verification for the quicknet scheme
`bls-unchained-g1-rfc9380` (sigs on G1, pubkey on G2, message `SHA-256(round)`): RFC 9380
`expand_message_xmd`(SHA-256) + hash-to-G1 (`MAP_FP_TO_G1` + `G1ADD`) and the pairing
check `e(sig, -g2) · e(H(m), pk) == 1` via the EIP-2537 pairing precompile. The quicknet
public key, `-G2` generator, DST and field modulus are baked-in constants, cross-checked
against a real beacon with an independent BLS library and validated end-to-end against the
live chain (see [§7](#7-security-audit)).

---

## 4. The lottery, end to end

The token accrues WETH exactly like a reward token, but instead of a buyback the pot
is paid whole to one ticket holder. A draw is a **commit-reveal** against drand:

**Commit (`commitDraw(token, drandRound)`, `drawOperator`-only):**

1. requires Lottery mode, VRF wired, no active draw, timer elapsed, a non-empty session
   (`totalTickets(epoch) > 0`), and — critically — that **`drandRound` is in the future**,
   enforced on-chain by comparing it to `block.timestamp` via drand's genesis+period
   (`RoundNotFuture`). This stops a malicious operator committing to an already-produced
   round whose beacon it could grind to choose the winner (audit **C-01**);
2. resets the block timer, **reserves the pot** (`pendingWeth → 0`, snapshot as prize),
   and **advances the epoch** — *ticket sales for the drawn session close here*, so any
   buy after commit counts toward the next session and no one can act on the randomness
   once it's revealed;
3. `requestRandomness(drandRound)` from the coordinator for a future round;
4. records the `PendingDraw` (round, epoch, prize, requestId).

**Settle (`settleDraw(token, holders, minPrizeOut)`, `drawOperator`-only,
`nonReentrant`):**

1. reads the randomness from the coordinator — pushed via `fulfillRandomness`, or
   pulled via `randomnessOf(round)` — reverts `RandomnessNotReady` if absent. The
   coordinator only ever stores a value whose **drand BLS signature it verified
   on-chain**, so the seed is provably the real beacon — the keeper cannot substitute
   its own;
2. derives the winning ticket **on-chain**:
   `winningTicket = keccak256(randomness, token, round) % totalTickets`;
3. **derives the winner on-chain** from `holders` — the epoch's ticket-holders, sorted
   strictly ascending by address. Strict ordering makes them distinct and defines a
   canonical partition of `[0, totalTickets)`; each holder's stored ticket count is read
   and accumulated, and the total must equal `totalTickets` (`IncompleteHolderSet`
   otherwise). That forces `holders` to be the **complete** set, so `winningTicket` lands
   in exactly one holder's range — the winner. The operator supplies the *set*, not the
   *winner*: it has **no discretion** (any omission undershoots the sum; any padding is a
   non-holder → `BadHolderSet`);
4. records the `Draw` (randomness, round, winner, prize, totalTickets, winningTicket)
   and pays the reserved pot — as **WETH**, or (if the dev chose a prize token) that
   token bought with the pot on the registered V3/V4 venue (`minPrizeOut` guards the swap).

`settleDraw` costs O(n) in the holder count (one `SLOAD` per holder), one-time per draw
with no per-trade overhead, and is **paginated**: the sorted set can be fed across
multiple calls (each continuing strictly after the previous call's last holder), so a
lottery with *any* holder count is always settleable within block limits. Progress
accumulates in `settlement[token]` and the draw finalizes on the call whose cumulative
reaches `totalTickets`. `resetSettlement` restarts a botched chunk sequence;
`cancelDraw` abandons the whole draw (and clears any partial progress).

**Cancel (`cancelDraw`, `drawOperator`-only):** emergency recovery for a stuck draw
(e.g. a bad committed round). Rolls the reserved pot back into `pendingWeth` for the
next draw. The closed session is **not** reopened — its tickets stay reset.

**Public verifiability:** the chain *enforces* the draw, and anyone can independently
re-derive it: read the `Draw` event, confirm `randomness` is drand round `round`'s real
beacon (the coordinator already did), recompute `winningTicket`, and re-map it over the
epoch's `TicketsChanged` events sorted by address. Powerball, but cryptographically
enforced end to end.

---

## 5. Money flow & fee routing

```
                 ┌─────────────── a trade on the pool ───────────────┐
   BUY  (WETH)   │                                                   │  SELL (token)
       │         ▼                                                   ▼        │
       │   buy-side WETH fee                                 sell-side token fee
       │         │                                                   │        │
       ▼         ▼                                                   ▼        ▼
   ┌──────────────────────────── FeeLocker.claim() ───────────────────────────┐
   │  V1:  50% treasury  |  50% dev                    token fees ─────► BURN  │
   │  V4:  treasury == dev (per tier)  +  mechanism →  token fees ─────► BURN  │
   └────────────────────────────────────┬─────────────────────────────────────┘
                                         │ mechanism WETH (V4 only)
                                         ▼
                           LaunchFairV4Distributor  (pendingWeth[token])
                                         │
              ┌──────────────────────────┼───────────────────────────────┐
     Redistribute                     Reward                           Lottery
   buy THIS token on its           buy the dev's reward             accrue the pot;
   own V4 pool, fold into          token (V3 or V4), push           draw one holder
   holders' balances               to holder wallets                the whole pot
```

- **Devs are always paid in WETH** (never the token), on both stacks.
- **Sell fees are always burned** — deflationary, no sell pressure on the pool.
- **Only buys feed the reward/pot mechanism.**
- Fees sit unclaimed until `claim()` is poked (permissionless); the keeper does it.

---

## 6. Off-chain components (keeper + drand)

The contracts are **permissionless** — the keeper only guarantees liveness. Each tick,
per token: `claim()` (collect/split/burn fees) → if `readyToProcess`, `process()` (buyback
+ fund) → for Reward/Redistribute, `processAccounts()` pushes owed rewards to wallets
(holder list from the indexer). For Lottery it runs the two-phase draw (commit to a
future drand round, then post the beacon to the VRF coordinator and settle).

- **Slippage:** the keeper static-calls `process` to quote, then passes
  `minOut = (100 - SLIPPAGE_PCT)%` (default 15%), so a sandwich beyond tolerance reverts
  and it retries next tick.
- **drand:** quicknet chain (3s period, BLS-signed, free). Commit is always to a *future*
  round so the seed is unknowable at commit time; `prevrandao` is constant on this chain
  and deliberately **not** used. To settle, the keeper decompresses the beacon's BLS
  signature to an EIP-2537 G1 point and posts it; the coordinator verifies it on-chain
  (so this step is permissionless — anyone can post the real beacon).
- **Setup (one-time, by the owner):** `setDrawOperator(keeper)`, `setProcessor(keeper)`,
  `setVrf(coordinator)`. The coordinator needs no setup — it's ownerless and
  `postRandomness` is permissionless.

---

## 7. Security audit

Severity: **H** high, **M** medium, **L** low / informational. Findings marked
*resolved* are fixed in the current tree; the rest are documented trust assumptions or
open items.

> **See [AUDIT.md](AUDIT.md)** for the full independent audit report. It found — and this
> tree fixes — a **Critical**: the lottery's future-round requirement was *not enforced
> on-chain*, so a malicious/compromised draw operator (or the owner via a swappable VRF)
> could grind a public past beacon to **steal any pot** (C-01/M-01/M-02), plus a coordinator
> DoS (H-01) and a V1 WETH-drain (M-03). The section below reflects the post-remediation state.

### Resolved / mitigated

**H-01 — Pool-poisoning / token-address squatting at launch *(resolved).*** A front-runner
could try to squat a token's predicted address. Fixed on both stacks by **CREATE2 salted
with `keccak256(msg.sender, salt)`** (the deployer bakes the launchpad into the initcode),
so a griefer can only block one `(creator, salt)` combo and the creator retries with a fresh
salt. **Caveat (audit L-04):** the *V4 pool* can still be **pre-initialized** by a front-runner
(a V4 pool is pure PoolManager storage, needs no token deploy), which makes that one
`createToken` revert — a DoS, not theft. V1 guards the analogous case (`PoolPriceUnsafe`); V4
does not yet. Robinhood Chain (Arbitrum Nitro) has no public gossip mempool, so only
*pre-announced* launches are realistically exposed. See [AUDIT.md](AUDIT.md) L-04.

**M-01 — JSON/metadata injection *(resolved).*** `contractURI()` embeds metadata.
Every metadata string is validated (`_validate*`: length ≤ 256; rejects `"`, `\`, and
control chars < 0x20) on both launchpads, so nothing can break out of the JSON. V4
tokens further reduce exposure by using a **plain URL** `contractURI` (no inline JSON).

**Reflection double-counting / V4 rebase incompatibility *(resolved by design).*** See
[§9](#9-invariants--design-guarantees): the Increasing reflection pool is netted out of
`balanceOf(this)` so `Σ balanceOf ≤ totalSupply` (floor dust favors the contract), and the pool is excluded so it never
sees a rebase — making auto-compound V4-safe without a transfer tax.

**Ticket laundering via sells/transfers *(resolved).*** Tickets track *held* bought
tokens, not lifetime buys: any move-out removes tickets, so selling → 0 odds and
wallet-to-wallet moves can't launder tickets.

**M-02 — Permissionless `process()` sandwich *(resolved).*** `process(token, minOut)`
is now gated to the distributor **owner or an allowlisted keeper**
(`isProcessor` + `setProcessor`); an untrusted caller can no longer force the buyback
through at `minOut = 0` and sandwich it. The caller's quoted `minOut` is the
protection, and only trusted callers can trigger it. Already-distributed rewards stay
claimable trustlessly on the token (`claim()` / `processAccounts()`), so no new
liveness trust is added beyond the keeper the mechanism already relies on.

**M-03 — Lottery prize-token swap unguarded *(resolved).*** `settleDraw` now **returns
the amount paid** to the winner, so the keeper `eth_call`s it with `minPrizeOut = 0` to
quote the pot→prize swap, then re-sends with `(100 - SLIPPAGE_PCT)%` applied — exactly
how the buyback is quoted. A sandwich beyond tolerance reverts and the draw retries.
WETH-pot draws do no swap and are unaffected.

**L-03 — Registrar / buyback-venue hijack *(resolved).*** `setRegistrar` is now
**set-once** (`registrarLocked`) — the first post-deploy call wires the real launchpad
and freezes it — and `registerBuyback*` reverts `AlreadyRegistered`, so a token's
buyback venue is frozen at launch. The owner can no longer re-point the registrar to
redirect an existing token's mechanism WETH onto a rigged pool.

**L-02 — Lottery randomness trusted the poster *(resolved).*** `postRandomness` now
**verifies the drand BLS12-381 signature on-chain** (`DrandBLS`, EIP-2537) against the
quicknet public key, so it only ever stores a value proven to be the real beacon —
a forged one reverts. This removes the poster entirely: the coordinator is ownerless and
`postRandomness` is **permissionless**. The seed a draw settles on is now provably the
genuine drand output, not a value anyone was trusted to relay honestly. Verified against a
real beacon (round 30364827) both with an independent BLS library and **end-to-end against
the live Robinhood Chain precompiles** via `eth_call` state-override (`hashToG1` matched
the reference; valid → true; wrong round → false; tampered → revert). See
`test/v2/DrandBLS.t.sol` (skips locally — the forge EVM has no BLS12-381 precompiles).

**L-01 — `drawOperator` could steer the winner *(resolved).*** `settleDraw` no longer
takes a `(winner, cumulativeStart)` the operator picks. It takes `holders` — the epoch's
ticket-holders **sorted strictly ascending by address** — and derives the winner on-chain:
strict order ⇒ distinct + a canonical partition of `[0, totalTickets)`; each holder's
stored ticket count is accumulated and must sum to `totalTickets` (`IncompleteHolderSet`),
which forces the set to be **complete** (any omission undershoots; any padding is a
non-holder → `BadHolderSet`). The drawn ticket then falls in exactly one holder's range, so
the winner is a **deterministic function of on-chain state** — the operator supplies the
set, not the winner, and cannot favor anyone. Combined with L-02, the entire draw (seed +
winner) is now cryptographically enforced on-chain, not merely publicly auditable. Cost is
O(holders) at settle only — no per-trade overhead (a per-trade cumulative structure was
rejected for exactly that reason) — and `settleDraw` is **paginated** (the sorted set can
be fed across multiple calls), so no lottery is ever too large to settle.

### Open / MEV

**L-04 — Stranded rewards when `totalShares == 0`.** If `minHold` is set high enough that
no wallet qualifies, `fundRewards` reverts `NoShares` and `process()` rolls back, so WETH
accrues in the distributor indefinitely (retryable, **not** lost) until someone qualifies.
A dev-config edge case, not a fund-loss.

**L-05 — Redistribute `balanceOf` changes without a `Transfer` event.** For Increasing
mode, a holder's `balanceOf` grows on each buyback with no `Transfer` emitted (folded in on
the next transfer via `_realize`). Wallets/UIs are fine and the balance is always fully
spendable, but a third-party contract that caches balances off `Transfer` events could read
stale values. The **pool is excluded** (reads raw), so AMM math is unaffected. Informational.

### Positives worth noting

- **Liquidity is locked forever** on both stacks — no decrease/withdraw function exists,
  so a rug via LP pull is impossible.
- **Tokens are renounced** (`owner() == address(0)`, no mint/fee/blacklist).
- **Reentrancy:** `createToken`, `claim`, `process`, `settleDraw` are all `nonReentrant`;
  the VRF fan-out uses CEI + try/catch; all payout paths follow checks-effects-interactions
  and only ever credit an account its *own* owed amount. `claim`, `checkGraduation`,
  `fundRewards`, and the token's self-`claim()` stay permissionless (they can only add or
  hand out owed value); the swap-bearing paths (`process`, the lottery draw) are
  access-controlled so their `minOut`/`minPrizeOut` bound is meaningful.
- **Atomic launch:** V4 pool init + single-sided lock happen in one `nonReentrant` call, so
  there's no init→mint price gap to sandwich.
- **Fee-split floor:** the mechanism always keeps ≥ 20% of the fee (`side*2 ≤ 8000`), so the
  owner can't starve holders via `setSideBps`.
- **Verified randomness:** the lottery seed is a drand beacon whose BLS signature is
  checked on-chain (`DrandBLS` + EIP-2537), so a draw can only settle on the genuine,
  unforgeable drand output — the coordinator is ownerless and permissionless.
- **Deterministic winner:** the winner is a pure function of the verified seed and the
  sorted, complete holder set — `settleDraw` derives it on-chain, so the operator submits
  the holder set but has no say in who wins.

---

## 8. Trust & centralization matrix

| Role | Held by | Powers | Bound |
|------|---------|--------|-------|
| **Launchpad/locker/distributor owner** | protocol multisig | tune fee splits, treasury, creation fee, wire locker/distributor/VRF, set draw operator + processor allowlist | mechanism ≥ 20%; creation fee ≤ 0.001 ETH; `setLocker` **and `setRegistrar` set-once**; a token's buyback venue is frozen at launch (L-03) |
| **Treasury** | protocol | receives its fee share; **reassigns any token's dev (CTO)** | can't touch liquidity or holder rewards |
| **Dev (creator)** | token launcher | receives dev fee share (WETH); sets `payoutThreshold` / `payoutInterval` for its token | can't mint, can't pull liquidity, not exempt from launch cap |
| **drawOperator (keeper)** | protocol hot wallet | commits/settles draws, pushes rewards | **can't forge the seed (verified on-chain) and can't steer the winner (derived on-chain from the sorted, complete holder set) — supplies the holder *set*, not the winner (L-01/L-02 resolved)** |
| **Beacon poster** | *anyone* | `postRandomness` (bring a drand beacon on-chain) | signature verified on-chain — a forged beacon reverts; no trust, no role |
| **Anyone** | public | `claim` (fee collect/split/burn), `checkGraduation`, `fundRewards`, self-`claim()` (own dividends) | only credits owed amounts / cosmetic; `process()` is keeper-gated (M-02) |

---

## 9. Invariants & design guarantees

- **`Σ balanceOf(all) ≤ totalSupply` (Increasing mode).** Each holder's `balanceOf`
  includes its pending reflection; the contract nets the same total out of
  `balanceOf(this)` via `_reflectionHeld`, so the accrued-but-unrealized tokens are never
  double-counted. Rounding (floor) leaves negligible dust in the netted pool, so the sum is
  `≤`, never `>`, `totalSupply` — the safe direction (no over-claim). Verified in the tests
  within a small tolerance (audit I-05).
- **The pool always reads exact raw balances.** All plumbing — the V4 PoolManager / V3
  pool, position manager, locker, distributor, and the token itself — is
  `excludedFromDividends`, so its `balanceOf` bypasses the reflection fold. No rebase from
  the AMM's point of view → V4-safe, and no fee-on-transfer anywhere.
- **A displayed balance is always spendable.** Before any transfer, `_realize(from)` folds
  the sender's accrued reflection into its raw balance, so `balanceOf(from)` tokens can
  always be moved.
- **Liquidity can only ever be added, never removed.** Neither locker exposes a decrease
  path.
- **Ticket odds equal held-bought fraction.** `ticketsOf[epoch][h] / totalTickets[epoch]`,
  and both sides are reconstructable from `TicketsChanged` events.
- **Draws are frozen at commit.** The epoch is advanced and the pot reserved at
  `commitDraw`, so neither can change between commit and settle.

---

## 10. Open items / TODO before mainnet

Done since the first review:

- ~~**M-02:** restrict `process()` to the keeper.~~ Gated to owner/allowlisted processor.
- ~~**M-03:** quote a real `minPrizeOut` for the lottery prize-token swap.~~ `settleDraw`
  returns the payout; the keeper quotes and bounds it.
- ~~**L-03:** make `setRegistrar` set-once / freeze a token's venue.~~ Both done.
- ~~**Deploy script** for the V4 stack.~~ `script/DeployV4.s.sol` deploys and wires the
  whole stack (VRF coordinator, draw operator, processor allowlist).
- ~~**L-02:** on-chain drand BLS verification.~~ Built (`DrandBLS.sol`); the coordinator
  verifies every beacon and is now permissionless/ownerless. Validated against a real
  beacon with an independent library and end-to-end against the live chain's EIP-2537
  precompiles.
- ~~**L-01:** on-chain winner selection.~~ `settleDraw` derives the winner from the sorted,
  complete holder set — no operator discretion. The whole draw (seed + winner) is now
  enforced on-chain.
- ~~**Settle pagination.**~~ `settleDraw` is paginated — the sorted holder set can be fed
  across multiple txs, so a lottery of any size is always settleable (no un-settleable pot).

Still open:

- **External audit** before handling real value at scale (third-party human review — not a
  code change) — the `DrandBLS` verifier especially warrants expert review.
- **Verify the V4 pool-shape constants** in `DeployV4.s.sol` (supply, initial price, tick
  spacing, single-sided range) against the real chain/fee tier before broadcasting.

---

*Scope: `src/LaunchToken.sol`, `src/V3Launchpad.sol`, `src/FeeLocker.sol`,
`src/v2/LaunchTokenV2.sol`, `src/v2/TokenDeployerV2.sol`, `src/v2/v4/LaunchFairV4.sol`,
`src/v2/v4/LaunchFairV4FeeLocker.sol`, `src/v2/v4/FeeSplitConfig.sol`,
`src/v2/v4/LiquidityMath.sol`, `src/v2/v4/LaunchFairV4Distributor.sol`,
`src/v2/v4/LaunchFairVRFCoordinator.sol`, `src/v2/v4/DrandBLS.sol`. Off-chain:
`launchfair-keeper`.*
