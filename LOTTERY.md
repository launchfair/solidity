# LaunchFair Lottery — how it works

The **Lottery** mode is a holdings-weighted, provably-fair on-chain raffle — the same
idea as $BALL / powerball.tech, built into the token itself. Every trade feeds a pot,
and on each draw a random holder wins it. Randomness comes from **drand** (a public
randomness beacon), verified on-chain, so nobody — not the dev, not the operator — can
pick or predict the winner.

---

## In one paragraph

You enter just by **holding the token**. Your odds are your share of the tokens held:
hold 1% of the circulating supply and you have a 1% chance each draw. A slice of every
trade's fee builds the **jackpot**. When a draw fires, the contract **snapshots everyone's
holdings** and waits for a future drand beacon it can't predict. That beacon rolls for a
**jackpot hit**: most draws miss and the pot **rolls over and keeps growing**, but when one
hits, the whole pot goes to a single holder chosen at random — weighted by that snapshot.
Everything needed to re-check the result is stored on-chain.

---

## Entering & your odds

- **Tickets = your held balance.** There's no "buying a ticket" and no minimum — if you
  hold the token, you're in, weighted by how much you hold.
- **Odds = `yourBalance / totalHeld`.** `totalHeld` is every eligible holder's balance
  added up. Buying more raises your odds; selling lowers them.
- **Excluded from the count:** protocol plumbing only — the locked liquidity pool, the
  fee locker, and the distributor. The locked LP (the majority of supply) can't win, so
  odds are computed over *circulating, wallet-held* tokens.

The token keeps a block-stamped history of every holder's eligible balance
(`balanceOfAt(holder, block)`) and the running total (`totalEligibleAt(block)`), so a
draw can read exactly what everyone held at a chosen moment.

---

## The pot — a rolling jackpot

- Funded by **trade fees**. Each token picks a fee tier (3% / 5% / 10%); the mechanism's
  share of the WETH fee accrues to the token's pot (`distributor.pendingWeth[token]`).
- The pot is a **rolling jackpot**, powerball-style — it is **not** paid out on every
  draw. Each draw the beacon rolls for a **jackpot hit**:
  - **Hit** → a holdings-weighted random holder wins the **entire pot**, and it resets to 0.
  - **Miss** → nobody wins; the pot **rolls over** and keeps growing into the next draw.
- The chance of a hit is a fixed difficulty the dev chooses once at creation
  (`jackpotChanceBps`, in bps; default **200 = 1-in-50** per draw). Lower odds → the pot
  rolls longer and grows bigger before someone finally lands it.
- **No cap, no artificial partial payout.** Every draw pays the *whole* pot or nothing, so
  a jackpot can roll across many draws and grow unbounded until one hits — and the winner
  takes all of it.
- The pot is **never reserved or zeroed at commit.** It stays live and keeps growing right
  up to the settle of a *winning* draw; a draw that misses leaves it fully intact. So the
  pot only ever drops when someone actually wins.
- The **hit roll comes from the same future drand beacon as the winner** —
  `keccak256(abi.encode(randomness, token, round, 1)) % 10000 < jackpotChanceBps` — so it's
  unknowable at commit and provably fair: nobody (dev, operator, or holder) can know whether
  a draw will hit, or force one to. A distinct preimage (the trailing `1`) keeps it
  independent of the winning-ticket draw.
- By default the pot pays out in **ETH**. A dev can optionally set a **prize token** —
  then the winning pot is swapped to that token and the winner is paid in it.

---

## A draw, step by step

A draw is run by the keeper (a permissionless operator role) in two phases so the
randomness can't be known — let alone gamed — in advance.

1. **Commit** (`commitDraw`)
   - Checks the draw timer has elapsed and the pot has holders.
   - **Snapshots the block** (`snapshotBlock = block.number`). The winner will be drawn
     from holdings *as of this block*.
   - **Leaves the pot untouched.** Nothing is reserved or zeroed — the pot rolls over on a
     miss and is only emptied by a *winning* settle, so it keeps growing across draws.
   - Commits to a **future drand round** whose beacon does not exist yet. (A guard
     rejects any round that's already in the past, so a past, publicly-known beacon can
     never be chosen.)

2. **Beacon** (off-chain → on-chain)
   - drand quicknet produces a beacon every 3 seconds. Once the committed round exists,
     its **BLS signature** is posted to the VRF coordinator, which **verifies the
     signature on-chain** (EIP-2537 BLS12-381) against the quicknet public key. A forged
     value reverts, so the randomness is provably the real beacon.
   - The on-chain randomness is `keccak256(signature)`.

3. **Settle** (`settleDraw`)
   - Reads the verified randomness and **rolls for the jackpot** first:
     `keccak256(abi.encode(randomness, token, round, 1)) % 10000`. If that is **≥** the
     token's `jackpotChanceBps`, the draw **misses** — no winner, the pot stays put and
     rolls over, and the draw is recorded with `won = false` (no holder set needed, so a
     miss settles in one cheap call).
   - Otherwise it's a **hit**. The winning ticket is
     `winningTicket = keccak256(abi.encode(randomness, token, round)) % totalHeldAtSnapshot`.
   - The caller supplies the holder set (sorted by address). The contract reads each
     holder's **snapshot** balance (`balanceOfAt(holder, snapshotBlock)`), lays them out
     as contiguous ranges, and the holder whose range contains `winningTicket` wins.
   - The set must be **complete** — the balances must sum to the on-chain total — so no
     holder can be omitted and no fake holder padded in. The winner is fully determined
     by the data; the operator has **no discretion**.
   - The winner is paid the **entire live pot** (ETH, or the swapped prize token), which is
     then zeroed to start the next jackpot. Big lotteries can be settled across multiple
     transactions (the holder set is fed in chunks).

---

## Why it can't be gamed (front-run-proof)

The winner is drawn from the **commit-block snapshot**, taken *before* the drand beacon
for the future round exists. Because holdings are frozen at that block:

- Nobody can wait for the random number to become public and then **buy exactly enough
  to land on the winning ticket** — their post-commit balance change simply isn't in the
  snapshot.
- Selling after the commit doesn't remove you from the draw either — you're still in at
  your snapshot balance.

This is the whole reason for the two-phase commit/settle and the block-stamped balance
history.

---

## Provably fair — verifying a draw yourself

Every settled draw stores, on-chain (`distributor.draws[token][i]`): the drand `round`,
the `randomness`, the `winner` (zero on a miss), the `prize`, the `totalTickets` (total
held at the snapshot), the `winningTicket`, the `hitRoll`, and `won`. Anyone can re-check
both the jackpot roll and the winner end to end:

1. **Beacon → randomness.** Fetch the drand beacon for `round` from a public gateway
   (`https://api.drand.sh/<chain>/public/<round>`), verify its BLS signature against the
   quicknet public key, and confirm `keccak256(signature)` equals the on-chain
   `randomness`.
2. **Randomness → jackpot hit.** Recompute
   `keccak256(abi.encode(randomness, token, round, 1)) % 10000` and confirm it equals the
   recorded `hitRoll`; `won` is true exactly when `hitRoll < jackpotChanceBps`.
3. **Randomness → winning ticket** (only on a win). Recompute
   `keccak256(abi.encode(randomness, token, round)) % totalTickets` and confirm it equals
   the recorded `winningTicket`.
4. **Winning ticket → winner.** Lay out every holder's snapshot balance in address order;
   the winning ticket falls in exactly one holder's range — the winner.

The **token page does step 2 for you in the browser** and shows a "Verified" badge on
each past draw, with a link to the drand beacon for step 1.

drand quicknet: chain `52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971`,
3-second rounds, signatures on G1 (bls-unchained-g1-rfc9380).

---

## Contracts (Robinhood Chain mainnet)

| Contract | Address | Role |
|---|---|---|
| LaunchFairV4 (launchpad) | `0xFdCF1476718b695E62d3E8A91452B7008C39A5Dc` | creates mode tokens |
| Distributor | `0x661eB57fB7112Dd5A8b10ecccC48EF03eB1C4fE4` | holds the pot, runs draws |
| VRF Coordinator | `0x1E4F4009864a404f99e2117C632aaa2E28a6F017` | verifies drand BLS on-chain |
| SwapRouter | `0x0e6c53664388B68F6b41851D224248F391CC8947` | native-ETH buy/sell of mode tokens |

Key views on the token: `totalEligibleSupply()`, `balanceOfAt(holder, block)`,
`totalEligibleAt(block)`, `lotteryEpoch()`. On the distributor: `pendingWeth(token)`
(the live, rolling pot), `jackpotChanceBps(token)` (per-draw hit odds), `drawCount(token)`,
`draws(token, i)`, `pendingDraw(token)`.

---

## Developer notes

- **Holdings are tracked with block-indexed checkpoints** (OpenZeppelin `Checkpoints`),
  written on every lottery-mode transfer for both the holder and the running total. Only
  Lottery tokens pay this cost.
- **L1 vs L2 blocks.** On this chain the EVM `block.number` opcode is the **L1** block
  (~25.5M), while `eth_blockNumber` / log block numbers are the **L2** block (~8.4M). The
  checkpoints and `snapshotBlock` key on the **L1** block, and `balanceOfAt` /
  `totalEligibleAt` take an L1 block. The keeper therefore enumerates candidate holders
  from `TicketsChanged` events but reads each one's snapshot balance from the contract
  (`balanceOfAt(holder, snapshotBlock)`) rather than trusting the L2-stamped event value.
- **Draw cadence** is set per token (`payoutIntervalBlocks`) and driven by the keeper.
- Source: `src/v2/LaunchTokenV2.sol` (checkpoints + views), `src/v2/v4/LaunchFairV4Distributor.sol`
  (commit/settle), `src/v2/v4/LaunchFairVRFCoordinator.sol` + `DrandBLS.sol` (on-chain BLS).
