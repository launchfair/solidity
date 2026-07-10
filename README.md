# LaunchFair — V3 hybrid launchpad

A token launchpad where every token launches **straight into a real Uniswap V3 pool** as a single-sided range order, with the LP locked forever. Because the market is a normal V3 pool from block one, DEX terminals (GMGN, DexScreener, GeckoTerminal, …) index it automatically — no paid data integrations.

**The curve is still here.** A single-sided V3 range order *is* a bonding curve — mathematically identical to a pump.fun-style virtual-reserve constant-product curve. All supply sits above the launch price, so price only moves by buyers walking it up a deterministic ladder. A token **bonds/graduates once `graduationWethAmount` of WETH has been raised into its pool** (net of sells, measured as `WETH.balanceOf(pool)`). Each token **snapshots its bond target at creation** from `defaultGraduationWethAmount` — the manual "WETH to bond" knob (`setGraduationWethAmount`, owner-settable). Changing it only affects **future** tokens; existing tokens keep the target they launched with (never retroactive). `V3Launchpad.curveProgress(token)` returns progress toward it in bps (0–10 000) for the frontend progress bar. The only differences from a standalone curve: it lives inside the pool (that's what makes it indexable), it never "sells out" (price can keep climbing past graduation), and there's no transfer lock.

**Fee model** (via the pool's 1% fee tier — V3 fees accrue in the swap's *input* asset):

- **Buys pay 1% in WETH** → on claim, split **50% treasury / 50% token dev** (constant, no setter).
- **Sells pay 1% in the token** → **burned**. Neither the dev nor the platform ever receives tokens, so nobody can dump fee-tokens on holders; seller fees are pure deflation.

Plus a **flat creation fee** of **0.000005 ETH** charged to the dev at `createToken` and forwarded to the treasury (overpayment refunded). Owner-tunable via `setCreationFee`, hard-capped at `MAX_CREATION_FEE_WEI` (0.001 ETH). The treasury address is `locker.treasury()` — a single source of truth shared with the WETH fee split.

**Anti-sniper launch guard.** For the first **360 blocks** after launch, no wallet may hold more than **2% of supply** (`maxBuyBps`/`maxBuyBlocks`, deploy-time config). Enforced in the token's transfer hook, so it applies to pool buys and wallet-to-wallet stacking alike; sells always work (the pool is exempt, as are the locker/position manager — protocol plumbing only, set by immutable launchpad code). The guard **auto-expires** and nobody can extend, tighten, or re-enable it — check `limitActive()` / `maxWalletAmount()` on the token.

**Trust model — everything is renounced at launch.** Tokens have no owner (`owner() == 0`), no mint, no fee knobs, no blacklist, and are freely transferable from creation. The LP NFT is minted directly into the `FeeLocker`, which has *no function* to withdraw it or decrease liquidity — the pool can never be rugged or migrated. The 50/50 WETH split is a compile-time constant. The only owner powers are the treasury payout address, the website stamped into future tokens, and the flat creation fee (capped).

## Contracts

| Contract | Purpose |
|---|---|
| `src/V3Launchpad.sol` | `createToken(name, symbol[, metadata, salt])`: deploys the token (CREATE2, creator-scoped salt), creates + initializes the V3 pool at the configured launch price, mints the full supply as a single-sided range order with the `FeeLocker` as LP owner. `checkGraduation` is a permissionless poke that bonds a token once its pool has raised its snapshotted `graduationWethAmount` WETH (default owner-settable for future tokens; cosmetic — nothing migrates). Handles pool pre-creation griefing safely. |
| `src/FeeLocker.sol` | Permanently holds every LP NFT. `claim(token)` (permissionless) collects pool fees: WETH → 50/50 treasury/dev, token side → burned. No liquidity-withdrawal path exists by construction. |
| `src/LaunchToken.sol` | Vanilla OZ ERC20 + Burnable. Renounced, fixed supply. Carries creator metadata — logo (IPFS URI), website, Telegram, Discord, X — plus the platform site, immutable at creation, exposed as getters and via ERC-7572 `contractURI()` (validated at creation against JSON injection; emoji names fine). |
| `src/interfaces/IUniswapV3.sol` | Minimal factory / pool / position-manager surfaces. |

## Launch parameters (deploy-time, `V3Launchpad.PoolConfig`)

| Parameter | Default | Meaning |
|---|---|---|
| `tokenTotalSupply` | 1,000,000,000 | Full supply — all of it becomes pool liquidity |
| `initialPriceWethPerToken` | 1.491e9 wei | Launch price (~1.49 gwei/token) |
| `feeTier` | 10 000 (1%) | The "1%/1% both ends" — enforced by the pool itself |
| `tickLower0` / `tickUpper0` | −203 200 / 887 200 | Curve bounds (token0 orientation; mirrored automatically) |
| `graduationWethAmount` (→ `defaultGraduationWethAmount`) | 4.6 WETH | WETH raised into the pool that bonds a token; snapshotted per token at creation. Owner-settable default (`setGraduationWethAmount`) for **future** tokens only; drives `checkGraduation` + `curveProgress` |

## Run it

```bash
forge test          # 18 tests, each run under BOTH token/WETH address orderings

# Local end-to-end demo (launch -> fees -> claim/burn -> graduation):
anvil                                                                          # terminal 1
forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast    # terminal 2
```

Real deployment (`script/Deploy.s.sol`) — set `WETH`, `UNIV3_FACTORY`, `POSITION_MANAGER`, `TREASURY`, `WEBSITE`, `PRIVATE_KEY`; local runs fall back to mocks and anvil's account 0.

## Robinhood Chain deployment (chain id 4663)

Verified on-chain (2026-07-09) against mainnet `https://rpc.mainnet.chain.robinhood.com`:

| Contract | Address | Verification |
|---|---|---|
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | Robinhood docs + live `symbol()` |
| UniswapV3Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` | owner = aliased Uniswap governance timelock; 21k+ pools |
| NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` | `factory()`/`WETH9()` match; "Uniswap V3 Positions NFT-V1" |

**`block.number` on this chain returns the Ethereum L1 block (~12s), not the 100ms L2 block** (verified via Multicall3: EVM sees ~25.49M vs L2 height ~4.8M). So `maxBuyBlocks = 360` ≈ **72 minutes** of launch protection.

```bash
# Fork test against the LIVE chain (launch, real swaps, guard, claim, graduation):
RUN_FORK_TESTS=true forge test --match-contract RobinhoodChainFork -vv

# Deploy:
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 \
UNIV3_FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA \
POSITION_MANAGER=0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3 \
TREASURY=<multisig> WEBSITE=<your site> PRIVATE_KEY=<deployer> \
forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast
```

DexScreener already indexes Robinhood Chain Uniswap V3 pairs (dexscreener.com/robinhood), so launched tokens chart automatically.

## Before mainnet — non-negotiables

1. ~~Fork test against the real Uniswap V3~~ **Done for Robinhood Chain** — `test/RobinhoodChainFork.t.sol` passes against live mainnet state (pool init, single-sided mint at our ticks, real swaps, max-buy guard, fee claim, graduation).
2. ~~Verify tick constants~~ **Done for the default config** — the real position manager accepted the mint (spacing 200, 1% tier).
3. ~~Confirm terminal indexing~~ **DexScreener covers Robinhood Chain Uniswap V3.** Check GMGN/GeckoTerminal coverage as they roll out support for the (very new) chain.
4. Independent security review; `AUDIT.md` records the internal one.
5. Use a multisig for `TREASURY` and the owner key.
