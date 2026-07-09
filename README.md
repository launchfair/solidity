# LaunchFair — Solidity contracts

Solidity/EVM smart contracts for LaunchFair launchpads.

## Layout

| Directory | Contents |
|---|---|
| [`Robinhood/`](./Robinhood) | Robinhood Chain (chain id 4663) launchpad — a noxa-style hybrid that launches each token straight into a locked Uniswap V3 pool. WETH-only trading fees split 50/50 treasury/dev, token-side fees burned, plus a flat creation fee to the treasury. Foundry project (contracts, tests, deploy scripts, audit notes). |

Each subdirectory is a self-contained Foundry project (vendored `lib/`):

```bash
cd Robinhood
forge build
forge test
```
