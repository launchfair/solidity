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

/// The WethFeeHook's 4-arg setDestinations (mode-token fee sink) + the fields to preserve.
interface IWethHookAdmin {
    function setDestinations(address treasury_, address distributor_, address flagshipSink_, address launchpad_)
        external;
    function distributor() external view returns (address);
    function launchpad() external view returns (address);
}

/// Cross-check: the core token must be minted by the same factory as every launchpad token.
interface ILaunchpadDeployer {
    function deployer() external view returns (address);
}

/// Deploys the CoreTGE war chest and points BOTH flagship fee sinks at it, so a slice of
/// every trade on the platform starts accumulating toward the seeded core-token launch:
///   - LaunchFairV4FeeLocker.setFlagshipSink(tge)   (mode-token trades, 0.1% carve)
///   - StockPairRouter.setDestinations(treasury, tge) (stock-token trades, flagship split)
/// The claims distributor is wired later (it needs the token address, which exists post-TGE).
///
/// Env: PRIVATE_KEY, TEAM_WALLET [required — where the team fee lands]; WETH, V3_FACTORY,
/// POSITION_MANAGER, FEE_LOCKER, STOCK_ROUTER, TREASURY
/// [defaults below]; CLAIMS_BPS/TEAM_BPS/COMMUNITY_BPS/LP_BPS [default 0/1000/0/9000 = NO pre-mint:
/// 0% claims + 0% community (seasons are buyback-funded), 10% team, 90% into the locked seed pool].
contract DeployCoreTGE is Script {
    address constant DEFAULT_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant DEFAULT_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant DEFAULT_POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    // NO stale defaults for the per-stack contracts. These MUST be passed explicitly at deploy —
    // hardcoding an old stack's addresses meant the sink-repoint silently succeeded against dead
    // contracts (or reverted mid-broadcast), and pinning a stale TOKEN_DEPLOYER gave the core
    // token a creator no launchpad uses (the exact orphan the permanent factory exists to prevent).
    // The token deployer especially: it is CoreTGE's immutable, so a wrong value can't be fixed.
    address constant DEFAULT_V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant DEFAULT_TREASURY = 0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3;
    string constant PLATFORM_WEBSITE = "https://hood.launchfair.app/";

    function run() external {
        // Foundry auto-loads the repo .env: fall back to the tester key so no shell-level
        // secret plumbing is needed to run this script.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) {
            require(!vm.envOr("PROD", false), "PROD deploy needs PRIVATE_KEY (the real deployer) - no tester fallback");
            pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        }
        // WIRE_SINKS=0 skips repointing the live fee sinks — for throwaway/e2e TGE deploys.
        bool wireSinks = vm.envOr("WIRE_SINKS", uint256(1)) != 0;
        address owner = vm.addr(pk);
        address weth = vm.envOr("WETH", DEFAULT_WETH);
        address factory = vm.envOr("V3_FACTORY", DEFAULT_V3_FACTORY);
        address npm = vm.envOr("POSITION_MANAGER", DEFAULT_POSITION_MANAGER);
        address locker = vm.envAddress("FEE_LOCKER");
        address stockRouter = vm.envAddress("STOCK_ROUTER");
        address stockFeeHook = vm.envAddress("STOCK_FEE_HOOK");
        // The permanent factory. Must equal the launchpad's deployer() so the core token shares
        // the one canonical creator; cross-checked below.
        address tokenDeployer = vm.envAddress("TOKEN_DEPLOYER");
        address wethFeeHook = vm.envOr("WETH_FEE_HOOK", address(0)); // repointed too, if given
        // Guard the immutable: if LAUNCHPAD is given, prove the core token will share its factory.
        address launchpadForCheck = vm.envOr("LAUNCHPAD", address(0));
        if (launchpadForCheck != address(0)) {
            require(
                ILaunchpadDeployer(launchpadForCheck).deployer() == tokenDeployer,
                "TOKEN_DEPLOYER != launchpad.deployer(): core token would have an orphan creator"
            );
        }
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
            vm.envAddress("TEAM_WALLET"), // REQUIRED: where the team's fee share lands (no default)
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

        // Point every flagship sink at the war chest — accumulation starts NOW. There are FIVE
        // sinks, and the WethFeeHook one (mode-token revenue, the main product) was the one this
        // script silently skipped — so all mode-token flagship revenue leaked to treasury.
        if (wireSinks) {
            address treasury = ISinkAdmin(stockRouter).treasury();
            ISinkAdmin(locker).setFlagshipSink(address(tge));
            ISinkAdmin(stockRouter).setDestinations(treasury, address(tge));
            ISinkAdmin(stockFeeHook).setDestinations(treasury, address(tge));
            if (wethFeeHook != address(0)) {
                // setDestinations(treasury, distributor, flagshipSink, launchpad) — preserve the
                // distributor + launchpad the hook already has; only move the flagship sink.
                IWethHookAdmin(wethFeeHook).setDestinations(
                    treasury,
                    IWethHookAdmin(wethFeeHook).distributor(),
                    address(tge),
                    IWethHookAdmin(wethFeeHook).launchpad()
                );
            }
        }

        vm.stopBroadcast();

        console2.log("CoreTGE (war chest + flagship sink):", address(tge));
        console2.log("  allocation bps (claims/team/community/lp):", claimsBps, teamBps);
        console2.log("  ", communityBps, lpBps);
        console2.log("  FeeLocker + StockPairRouter flagship sinks -> TGE");
    }
}
