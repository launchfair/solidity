// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CoreTGE, IWETH9} from "../src/v2/v4/CoreTGE.sol";
import {TokenDeployerV2} from "../src/v2/TokenDeployerV2.sol";
import {IUniswapV3Factory, INonfungiblePositionManager, IV3SwapRouter} from "../src/interfaces/IUniswapV3.sol";

interface ISinkAdmin {
    function setFlagshipSink(address sink) external;
    function setDestinations(address treasury_, address flagshipSink_) external;
    function treasury() external view returns (address);
}

/// Deploys the CoreTGE war chest and points BOTH flagship fee sinks at it, so a slice of
/// every trade on the platform starts accumulating toward the seeded core-token launch:
///   - LaunchFairV4FeeLocker.setFlagshipSink(tge)   (mode-token trades, 0.1% carve)
///   - StockPairRouter.setDestinations(treasury, tge) (stock-token trades, flagship split)
/// The claims distributor is wired later (it needs the token address, which exists post-TGE).
///
/// Env: PRIVATE_KEY [required]; WETH, V3_FACTORY, POSITION_MANAGER, FEE_LOCKER, STOCK_ROUTER
/// [defaults below]; CLAIMS_BPS/TEAM_BPS/COMMUNITY_BPS/LP_BPS [default 5000/1000/3000/1000].
contract DeployCoreTGE is Script {
    address constant DEFAULT_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant DEFAULT_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant DEFAULT_POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    // Open-stock-pool stack (2026-08-13).
    address constant DEFAULT_FEE_LOCKER = 0x9c7C88D8338b13B4D04ee43334dd02522757AAC6;
    address constant DEFAULT_STOCK_ROUTER = 0xBb6f952a5fD28566b7f0d32Ac02F2aFc6bD782BC;
    address constant DEFAULT_STOCK_FEE_HOOK = 0x37Db3428A84f72e0df3d786483eaa1d1558d80CC;
    /// The live launchpad's TokenDeployerV2 (LaunchFairV4.deployer()) — the core token must
    /// come from the SAME factory as every launchpad token so aggregators index it as ours.
    address constant DEFAULT_TOKEN_DEPLOYER = 0x3CeCC9A0329FDE96d9563a96b4bA131A115b1Dd7;
    address constant DEFAULT_V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant DEFAULT_TREASURY = 0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3;
    string constant PLATFORM_WEBSITE = "https://hood.launchfair.app/";

    function run() external {
        // Foundry auto-loads the repo .env: fall back to the tester key so no shell-level
        // secret plumbing is needed to run this script.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        // WIRE_SINKS=0 skips repointing the live fee sinks — for throwaway/e2e TGE deploys.
        bool wireSinks = vm.envOr("WIRE_SINKS", uint256(1)) != 0;
        address owner = vm.addr(pk);
        address weth = vm.envOr("WETH", DEFAULT_WETH);
        address factory = vm.envOr("V3_FACTORY", DEFAULT_V3_FACTORY);
        address npm = vm.envOr("POSITION_MANAGER", DEFAULT_POSITION_MANAGER);
        address locker = vm.envOr("FEE_LOCKER", DEFAULT_FEE_LOCKER);
        address stockRouter = vm.envOr("STOCK_ROUTER", DEFAULT_STOCK_ROUTER);
        address stockFeeHook = vm.envOr("STOCK_FEE_HOOK", DEFAULT_STOCK_FEE_HOOK);
        address tokenDeployer = vm.envOr("TOKEN_DEPLOYER", DEFAULT_TOKEN_DEPLOYER);
        // Genesis split (2026-08-13): 90% into the locked pool (real float, deep liquidity,
        // FDV ≈ 1.11× the pot) + 10% team. Seasons are BUYBACK-funded (the keeper buys core
        // with fee ETH and funds each Merkle pot with the bought tokens), so no pre-minted
        // claims/community reserve is needed. Still owner-retunable until launch.
        uint16 claimsBps = uint16(vm.envOr("CLAIMS_BPS", uint256(0)));
        uint16 teamBps = uint16(vm.envOr("TEAM_BPS", uint256(1000)));
        uint16 communityBps = uint16(vm.envOr("COMMUNITY_BPS", uint256(0)));
        uint16 lpBps = uint16(vm.envOr("LP_BPS", uint256(9000)));

        vm.startBroadcast(pk);

        CoreTGE tge = new CoreTGE(
            owner,
            IWETH9(weth),
            IUniswapV3Factory(factory),
            INonfungiblePositionManager(npm),
            TokenDeployerV2(tokenDeployer),
            IV3SwapRouter(vm.envOr("V3_ROUTER", DEFAULT_V3_ROUTER)),
            vm.envOr("TREASURY", DEFAULT_TREASURY),
            PLATFORM_WEBSITE,
            10_000, // 1% pool fee tier for the seeded pool
            claimsBps,
            teamBps,
            communityBps,
            lpBps
        );

        // Launch-price floor: never list the core below a normal token's ~$2.5k starting
        // FDV, however small the pot (MIN_LAUNCH_PRICE env, WETH wei per whole token).
        tge.setMinLaunchPrice(vm.envOr("MIN_LAUNCH_PRICE", uint256(1_491_146_318)));

        // Point every flagship sink at the war chest — accumulation starts NOW.
        if (wireSinks) {
            address treasury = ISinkAdmin(stockRouter).treasury();
            ISinkAdmin(locker).setFlagshipSink(address(tge));
            ISinkAdmin(stockRouter).setDestinations(treasury, address(tge));
            if (stockFeeHook != address(0)) ISinkAdmin(stockFeeHook).setDestinations(treasury, address(tge));
        }

        vm.stopBroadcast();

        console2.log("CoreTGE (war chest + flagship sink):", address(tge));
        console2.log("  allocation bps (claims/team/community/lp):", claimsBps, teamBps);
        console2.log("  ", communityBps, lpBps);
        console2.log("  FeeLocker + StockPairRouter flagship sinks -> TGE");
    }
}
