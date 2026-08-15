# LaunchFair: token launchpad (Uniswap V4)

A token launchpad where every token launches **straight into a real Uniswap V4 pool** as a
single-sided range order, with the LP locked forever. Because the market is a normal pool from block
one, DEX terminals (GMGN, DexScreener, GeckoTerminal, and others) index it automatically, with no paid
data integrations.

See [`src/README.md`](src/README.md) for the full file-by-file layout. The launchpad and its contracts
live in `src/v2/` and `src/v2/v4/`; the flagship flywheel lives in `src/flywheel/`.

---

## The bonding curve

A single-sided range order *is* a bonding curve, mathematically identical to a pump.fun-style
virtual-reserve constant-product curve. All supply sits above the launch price, so price only moves
by buyers walking it up a deterministic ladder. A token **bonds / graduates once its
`graduationWethAmount` of WETH has been raised into the pool** (net of sells, measured as
`WETH.balanceOf(pool)`). The target is snapshotted per token at creation and never changes
retroactively. `curveProgress(token)` returns progress in bps (0 to 10000) for the frontend progress
bar. The curve lives *inside* the pool (that is what makes it indexable), never "sells out" (price can
keep climbing past graduation), and there is no transfer lock.

## Anti-sniper launch guard

For a fixed window after launch, no wallet may hold more than a capped share of supply. The default is
**1 percent of supply for the first 60 seconds** (`setAntiSnipe(bps, secs)` sets the launchpad default
for future tokens; `0` disables it). The window is time-based and enforced in the token's transfer
hook, so it covers pool buys and wallet-to-wallet stacking alike. Sells always work (the pool, locker,
and position manager are exempt as protocol plumbing). The guard values are **immutable on each token**
and the window **auto-expires**: nobody can extend, tighten, or re-enable it after the token is
created.

## Trust model

Tokens have no owner, no mint, no blacklist, and are freely transferable from creation. LP NFTs are
minted directly into a **FeeLocker** that has *no function* to withdraw the NFT or decrease liquidity,
so the pool can never be rugged or migrated. Selling uses a standard one-time ERC-20 `approve`: no
launched token grants a standing or infinite allowance to any address. The only owner powers are
payout and treasury addresses, the site metadata stamped into future tokens, and capped fee knobs.

---

## Mode tokens

`LaunchTokenV2` picks one **mode** at launch (immutable); `LaunchFairV4Distributor` turns the
mechanism fee slice into holder value per mode:

| Mode | # | Payout |
|---|---|---|
| **Base** | 0 | Plain fair launch, no mechanism payout. |
| **Reward** | 1 | Buys up to 5 dev-chosen external tokens and distributes them to holders. |
| **Increasing** | 2 | Auto-compounding: buys back THIS token and distributes it (balances grow). |
| **Lottery** | 3 | Holdings-weighted three-outcome draw (miss / regular win / jackpot); a random holder takes the pot. |

A token can be paired against **WETH** (the default) or a **Robinhood stock quote**. Stock-paired
pools trade with ETH in and out and take the fee in WETH at a gated router, so any terminal can trade
them.

> A fifth enum value, **Perps** (#4), exists in the contracts but is **not currently offered**: its
> reference venue is not production (operator-set oracle) and would need a real push oracle
> (Chainlink / Pyth) plus liquidations and funding before it could ship. See
> [`docs/PERPS_REWARD_MODE.md`](docs/PERPS_REWARD_MODE.md).

### Contracts

- **`LaunchFairTokenFactory.sol`**: a small delegatecall proxy in front of the stateless
  `TokenDeployerV2`. Every token is deployed in the proxy's context, so all launched tokens share ONE
  canonical, permanent creator address that indexers and token trackers can key on, even across
  token-code upgrades. See [Permanent creator address](#permanent-creator-address) below.
- **`LaunchFairV4.sol`**: the launchpad. `createToken` plus atomic **`createAndBuy`** (front-run-proof
  dev buy in the launch tx). It wires the fee hook and the swap router, and holds the authoritative
  per-token launch record (creator, pool key, fee tier).
- **`WethFeeHookImmutable.sol`**: the V4 hook that takes the fee in **WETH on BOTH buys and sells** (no
  token sell pressure) as ERC-6909 claims, on every trade regardless of router, then runs the split.
  Its fee rate, split, and destinations are **constructor immutables with no owner and no setters**.
- **`LaunchFairV4FeeLocker.sol`**: locks the V4 LP, claims fees, and carves the flagship slice from the
  dev share.
- **`LaunchFairV4Distributor.sol`**: the reward and lottery mechanism and the WETH-to-asset buyback
  engine. Mechanism funding is accepted only from allow-listed fee sources.
- **`LaunchFairVRFCoordinator.sol` plus `DrandBLS.sol`**: trustless lottery randomness via on-chain
  BLS12-381 verification of the public drand beacon. A draw snapshots holdings at its commit block, so
  the winner is frozen before the beacon is public.

**Fee model:** the fee is charged in WETH on both sides at the token's chosen **tier (3, 5, or 10
percent)**, written once into the launch record and not changeable afterward. The `FeeSplitConfig`
per-tier table sets treasury, dev, and mechanism shares; treasury, dev, and flagship are paid out as
native ETH, while the mechanism slice stays in WETH to fund the reward or prize buyback. A Base token
has no mechanism, so its mechanism slice folds into the flagship. See
[`docs/V4_WETH_FEE_HOOK.md`](docs/V4_WETH_FEE_HOOK.md).

**Lottery** is three-outcome with two pools (pot plus jackpot): **miss** rolls the pot over,
**regular** pays a random holder a share and skims the rest to the jackpot, and **jackpot** pays pot
plus the whole jackpot pool. Odds are dev-tunable and set-once.

## Flagship flywheel (`src/flywheel/`)

Fees feed a **flagship** platform token: a slice funds **buybacks** of the flagship, and each weekly
**season** the bought flagship is split pro-rata by trading points, which users **claim on-chain** from
**`SeasonMerkleDistributor.sol`** (per-season Merkle roots, transparent and admin-recoverable). The
buyback vault (`FlagshipBuyback.sol`) and the season distributor are driven by an automated keeper
whose authority is deliberately minimized (see [Flywheel keeper hardening](#flywheel-keeper-hardening)).

---

## Build and test

```bash
forge build
forge test          # 256 tests pass (0 failed); 8 fork tests gated behind RUN_FORK_TESTS

# Fork tests against the LIVE Robinhood Chain (real pool init, swaps, guard, claim, graduation):
RUN_FORK_TESTS=true forge test --match-contract RobinhoodChainFork -vv
```

Toolchain: solc **0.8.26**, `via_ir = true`, optimizer runs 200. Tests mirror `src/`: `test/v2/` (the
V4 engine) and `test/flywheel/`, with shared mocks in `test/mocks/`.

Deploy scripts (`script/`): `DeployV4.s.sol` (the launchpad stack), `DeployTokenFactory.s.sol` (the
permanent factory), `DeployWethFeeHookImmutable.s.sol` plus `HookMiner.sol` (the immutable fee hook,
deployed to a mined address), `DeploySeasonDistributor.s.sol` (after the flagship launches), and
`SwapTokenImpl.s.sol` (hot-swap the factory's token implementation).

## Robinhood Chain (chain id 4663)

Stable infra, verified on-chain against `https://rpc.mainnet.chain.robinhood.com`:

| Contract | Address |
|---|---|
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Uniswap V4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| UniswapV3Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |

> UniswapV3Factory is listed because reward venues and multi-hop stock quote routes can resolve through
> V3 pools; the launchpad itself and every launched market are Uniswap V4.

> **Two block numbers on this chain:** the EVM `block.number` opcode returns the **Ethereum L1 block**
> (~12 s), while `eth_blockNumber` returns the **L2 block** (~100 ms). The anti-snipe guard is
> time-based (seconds), but any block-height logic must read the L1 block via
> `Multicall3.getBlockNumber()`, not `eth_blockNumber`.

The permanent token factory address (see below) is stable across redeploys. The launchpad,
distributor, locker, and hook addresses rotate across stack redeploys; the frontend and indexer
configs are the source of truth for the current deployment.

---

## Security, audits, and fixes

### Review process

The contracts have been through layered review: per-component internal audits (the launchpad and fee
locker, the V4 WETH fee hook, the reward and lottery modes, and the flywheel), a multi-pass
pre-production sweep covering the contract diff, the deploy-script wiring, the keeper money-paths, and
the points and admin-auth surface, and a final adversarial pass that attempted to break the deployed
stack on-chain (launcher gating, fee routing, a compromised keeper key, and Merkle-root forgery).
Findings were fixed and then re-verified with unit tests plus live on-chain checks on Robinhood Chain.

### Token safety and scanner posture

- **No infinite allowances.** Earlier builds shipped a `trustedSpender` shortcut so platform routers
  needed no approval: the token's `allowance()` returned `type(uint256).max` for those routers.
  Third-party token scanners correctly read that as an unsafe, unauthorized-transfer pattern. It has
  been removed. Selling now uses a standard one-time ERC-20 `approve`, so no launched token grants a
  standing allowance to any address. A no-op `setTrustedSpender` remains only as an ABI shim, so a new
  token implementation can be swapped in under an already-deployed launchpad through the permanent
  factory without a launchpad redeploy; it records nothing and changes no allowance.
- **Immutable fee hook.** The V4 WETH fee hook is deployed as `WethFeeHookImmutable`: the fee rate,
  split, and destinations are constructor immutables with no owner and no setters. There is no path to
  raise the fee, redirect fee routing, or retune the split after launch, so a scanner sees no admin
  surface on the hook. The launchpad points new pools at this hook via `setFeeHook`; a pool's hook is
  fixed at creation, so this only affects future launches.
- **Per-token fee is fixed.** A token's fee tier (3, 5, or 10 percent) is written once into the
  launchpad's launch record and has no setter, so it cannot be changed after holders enter.
- **Locked liquidity.** Every LP position is minted into a fee locker with no withdrawal or
  liquidity-decrease path. Liquidity cannot be pulled or migrated.
- **Anti-snipe guard.** The time-based wallet cap (default 1 percent for 60 seconds) is set immutably
  at token creation and auto-expires. Nobody can extend, tighten, or re-enable it.

### Permanent creator address

`LaunchFairTokenFactory` is a small delegatecall proxy in front of a stateless `TokenDeployerV2`.
Because every token is deployed in the proxy's context, all launched tokens share ONE canonical,
permanent creator address that indexers and token trackers can key on, even across token-code
upgrades. The upgrade surface is deliberately bounded:

- only the deployer or the treasury can repoint the implementation;
- the implementation is checked to be a contract on every set and on every call, because a delegatecall
  to a codeless address would otherwise succeed silently and hand the launchpad a null "token";
- only allow-listed launchers (the launchpad and the token-generation contract) can deploy through it,
  so nobody can mint a scam token that indexes as "created by LaunchFair";
- `renounceOwnership` is disabled, so ownership can only be transferred, never dropped to the treasury
  as the sole un-freezable upgrader;
- `freezeImplementation()` permanently gives up the upgrade power once the token code is final, after
  which the address behaves like a plain immutable factory.

### Flywheel keeper hardening

The season keeper is an automated hot key, so its authority is minimized:

- **Claim veto window.** A keeper-published Merkle root is unclaimable until `claimDelay` has elapsed.
  That gives the cold owner a window to override a fraudulent or buggy root via `adminSetRoot` before
  anyone can claim against it.
- **Fixed-destination team cut.** `FlagshipBuyback.carveTeamCut` is keeper-callable but pays only the
  owner-set `teamWallet` and is bounded by a max bps. A leaked keeper key cannot redirect value.
- **Buyback only, no withdrawals.** The keeper can fire buybacks with a caller-supplied minimum-out for
  slippage protection, but token withdrawals remain owner-only and cold.

### Other fixes

- **Fee-source allowlisting.** The distributor accepts mechanism funding only from allow-listed fee
  sources, so a squatted or foreign pool cannot inject value into a token's reward or lottery
  mechanism.
- **Launch-record-anchored quotes.** V4 launch pricing reads the authoritative launch record rather
  than the permissionless pool key, closing a quote-slot squatting vector.
- **Guarded rescue path.** The distributor's pending-WETH rescue is gated on there being no active draw
  plus a staleness delay, so it cannot be used to interfere with a live lottery.
- **Lottery snapshot integrity.** A draw snapshots holder balances at `block.number - 1` and verifies
  the drand BLS beacon on-chain, so the winner is frozen before the beacon is public and cannot be
  ground out.
- **Protected buybacks.** `CoreTGE.buybackAndFund` rejects a zero minimum-out, and adopting a
  pre-initialized pool is bounded to within 1 percent of the intended launch price.
- **Merkle leaf-boundary validation and vault-balance clamps** from an off-chain re-audit were applied
  to the settlement path.

### Known limitations and pre-production requirements

- The perps reference venue is **not production** (operator-set oracle) and the Perps mode is not
  offered. A real deployment must swap in a genuine push oracle plus liquidations and funding, or leave
  the mode disabled. See [`docs/PERPS_REWARD_MODE.md`](docs/PERPS_REWARD_MODE.md).
- Before mainnet with real value: an independent external audit, and a **multisig for every owner and
  treasury key**.
- Off-chain, the points rollup and admin-auth hardening (chain-scoped trading volume, hook-verified
  pool registration, capped and bounded admin grants, and short-lived admin signatures) live in the API
  and keeper services, not in this repo.

For a broader end-to-end description of the platform, see [`PLATFORM_OVERVIEW.md`](PLATFORM_OVERVIEW.md).
