# LaunchFair ABIs

Contract ABIs for the live LaunchFair production stack on Robinhood Chain
(Arbitrum Nitro L2, chainId 4663). Extracted from the compiled artifacts of the
deployed source in this repository.

| Contract | Address | ABI |
| --- | --- | --- |
| LaunchFairTokenFactory (canonical creator of every token) | `0x1Afe4453fB79Bdf2880119e3EaB8d2BFc2d7a986` | [LaunchFairTokenFactory.abi.json](./LaunchFairTokenFactory.abi.json) |
| LaunchFairV4 (launchpad) | `0xC7b63a6B5A75d47FF412A975A488DceAc3Ea3B6e` | [LaunchFairV4.abi.json](./LaunchFairV4.abi.json) |
| LaunchTokenV2 (every launched token) | deployed per token by the factory | [LaunchTokenV2.abi.json](./LaunchTokenV2.abi.json) |
| WethFeeHookImmutable | `0x72c08F4E6cD41a1f0e7BE0F9D156C905c12080cc` | [WethFeeHookImmutable.abi.json](./WethFeeHookImmutable.abi.json) |
| StockFeeHookImmutable | `0xbf0D20EE5Efe516537a249E35a32BD14Ac4c80CC` | [StockFeeHookImmutable.abi.json](./StockFeeHookImmutable.abi.json) |
| LaunchFairV4FeeLocker | `0x9017f2E9116926a5e9Fb1b86a3D7a962352927dD` | [LaunchFairV4FeeLocker.abi.json](./LaunchFairV4FeeLocker.abi.json) |
| LaunchFairV4Distributor | `0xF7059b08F0B6f92Aa3967832D159CB74fedC7ACf` | [LaunchFairV4Distributor.abi.json](./LaunchFairV4Distributor.abi.json) |
| StockPairRouter | `0x78937423726f43FDE0038B53D230ad028F4A7bD6` | [StockPairRouter.abi.json](./StockPairRouter.abi.json) |
| LaunchFairV4SwapRouter | `0x0e6c53664388B68F6b41851D224248F391CC8947` | [LaunchFairV4SwapRouter.abi.json](./LaunchFairV4SwapRouter.abi.json) |
| CoreTGE (platform token war chest) | `0xf553Ec9A5162842E39932EE30855923FBcCD0a18` | [CoreTGE.abi.json](./CoreTGE.abi.json) |

Trades execute on the Uniswap V4 PoolManager (`0x8366a39CC670B4001A1121B8F6A443A643e40951`);
its `Initialize` and `Swap` events use the canonical Uniswap V4 core ABI.

Key indexing events: `TokenLaunchedV4` and `StockTokenLaunched` on the launchpad
(stock launches emit only the latter), `Swap` on the PoolManager filtered by pool id,
`FeeTaken`/`Distributed` on the hooks.
