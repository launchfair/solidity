# Security review — Fun Launchpad (V3 hybrid)

**Scope:** `src/V3Launchpad.sol`, `src/FeeLocker.sol`, `src/LaunchToken.sol` @ current tree.
**Method:** manual review against standard EVM exploit classes plus a dedicated test suite (18 tests) executed under **both token/WETH address orderings** (the ordering flips all tick/price math). The earlier bonding-curve stack this repo previously contained was reviewed, hardened, and later removed in favor of this architecture; findings specific to it are gone with it. This is an internal review, not a substitute for an independent audit before mainnet.

---

## Findings fixed during development

### H-01 — Pool-poisoning could permanently brick token creation (fixed)
The launched token's address is predictable before creation, and Uniswap V3 pool creation is permissionless — so an attacker could pre-create/pre-initialize the token's pool. In the original nonce-based CREATE design this was fatal: the creation reverts, the nonce doesn't advance, the "next" address never changes, and **one poisoned pool would have blocked all future launches**. Caught by `test_poolGriefing_handledSafely`.

**Fix (three layers):**
- Tokens deploy via **CREATE2 with a creator-scoped salt** — a retry with a fresh salt gets a fresh address, and each attack round costs the griefer more gas (pool creation) than the creator's retry.
- Pre-created but uninitialized pools are simply initialized at the launch price and used.
- Pools pre-initialized **at or below** the launch price are harmless (the single-sided order still mints entirely in tokens) and are used as-is; only a price **above** the launch price (which would break the mint) reverts with `PoolPriceUnsafe`.

Residual: a mempool-watching attacker can grief individual creation transactions in real time at a net gas loss; creators using a private RPC are immune.

### M-01 — JSON injection into `contractURI()` metadata (prevented by design)
Creator-supplied strings (name, symbol, logo URI, socials) are embedded in the on-chain ERC-7572 JSON. A name like `","image":"evil` would forge metadata fields for indexers. The launchpad rejects `"`, `\`, and control characters in all metadata strings at creation (multi-byte UTF-8/emoji allowed). Covered by `test_metadataCarriesOver`.

---

## Design guarantees (each enforced by code + tests)

| Guarantee | Mechanism |
|---|---|
| Liquidity can never be pulled or migrated | `FeeLocker` holds every LP NFT and has **no function** to transfer it or decrease liquidity; `onERC721Received` only accepts NFTs from the position manager. |
| Dev/treasury can never dump fee-tokens | `claim` burns the token side of collected fees; only WETH is ever paid out (`test_claim_devGetsOnlyWeth_tokenFeesBurned` asserts dev/treasury token balances stay 0). |
| 50/50 WETH split cannot be changed retroactively | `TREASURY_SHARE_BPS` is a compile-time constant; no setter exists. |
| Tokens are renounced | No owner (explicit `owner() == 0`), no mint, fixed supply, no transfer restrictions, metadata immutable after creation. |
| Graduation cannot move funds | `checkGraduation` only reads `WETH.balanceOf(pool)` and sets a flag + event. |
| Graduation target frozen per token | Each token snapshots its WETH-to-bond at creation from `defaultGraduationWethAmount`. `setGraduationWethAmount` (owner-only, rejects 0) changes only the default for FUTURE tokens — existing tokens' graduation/`curveProgress` never change. Not a fund-moving power and not retroactive. |
| Launch guard cannot be abused | 2%-wallet/360-block cap is fixed at creation and auto-expires; `setLimitExempt` is callable only by the launchpad, whose immutable code only exempts the pool, position manager, and locker — there is no path to exempt a private wallet or to extend/re-enable the guard. Post-expiry the check short-circuits (near-zero gas). |
| Fee claims are permissionless but payout-fixed | `claim` pays only the fixed treasury and the token's registered creator (transferable via `transferCreator`, creator-gated, zero-address-guarded). |
| Launchpad keeps nothing | Full supply goes to the pool position; any position-manager rounding dust is burned in the creation tx. |

## Attack surfaces checked and found sound

- **Reentrancy:** `nonReentrant` on `createToken` and `claim`; CEI ordering; external calls limited to WETH (no hooks), the launched token (self-minted, hook-free), and the Uniswap factory/position manager.
- **Access control:** `FeeLocker.register` launchpad-only; `setLaunchpad` write-once; owner powers limited to treasury address + website-for-future-tokens.
- **Integer safety:** Solidity 0.8 checked arithmetic; `sqrtPriceX96` computed with `Math.mulDiv` (512-bit intermediates); supply bounded to `uint128`.
- **Ordering correctness:** every test runs with token as token0 AND token1 (WETH pinned via `vm.etch` at extreme addresses); ticks/prices mirror correctly.
- **Exotic assets:** only WETH and self-minted `LaunchToken`s touch the system.
- No `delegatecall`, assembly, `selfdestruct`, upgradeability, or oracles.

## Open items / residual risk — read before mainnet

1. **The V3 integration is now verified against the REAL canonical Uniswap V3 on Robinhood Chain mainnet (chain id 4663)** — `test/RobinhoodChainFork.t.sol` (run with `RUN_FORK_TESTS=true`): pool creation + initialize precision, single-sided mint at the exact configured ticks, real swaps through the pool (including the max-buy guard blocking an oversized swap as `"TF"` and expiring on schedule), `collect` into the locker with the 50/50 WETH split and token-side burn, and graduation after a real 5-ETH curve walk. Note: on this chain `block.number` is the **Ethereum L1 block** (verified on-chain), so `maxBuyBlocks = 360` ≈ 72 minutes; foundry forks use L2 heights, so the fork test exercises mechanics, not wall-clock duration. Re-run the fork test for any other target chain.
2. **Range tick constants (`tickLower0`/`tickUpper0`) are deploy-time config and must be consistent** with `initialPriceWethPerToken` and the fee tier's tick spacing (1% tier ⇒ spacing 200). The contract validates ordering but cannot validate spacing alignment or the price↔tick relationship — check off-chain (defaults: price 1.491e9 wei ⇒ tick ≈ −203 246; range starts at −203 200). Graduation is WETH-amount-based (`graduationWethAmount`, `WETH.balanceOf(pool)`), independent of ticks; `curveProgress` derives from WETH bonded.
3. **Graduation target is per-token frozen (not retroactive).** `setGraduationWethAmount` sets only the default for future tokens; each token's target is snapshotted at creation and can never be changed afterward — consistent with the renounced/no-retroactive-change trust model. The owner's only graduation power is choosing the default new tokens launch with (and even that is cosmetic — it can't move funds or the locked liquidity).
3. **Economic note:** all fee revenue comes from the pool's 1% tier. Anyone trading the pool directly pays the same fee — there is no frontend-only fee, and none can be added without breaking the "real pool" visibility property.
4. **Honeypot scanners:** during the first 360 blocks the max-wallet guard is active and some scanners will report "max wallet: 2%" (accurate, and a common pattern they recognize); after expiry tokens read fully clean. Register the launchpad with scanner vendors (GoPlus etc.) so tokens get platform attribution and the temporary limit is labeled as launch protection.
5. Single-EOA owner in the deploy script — use a multisig for owner and treasury in production.
6. `claimMany` reverts the whole batch if one entry has nothing to claim.
