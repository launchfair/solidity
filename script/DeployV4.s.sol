// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {LaunchFairVRFCoordinator} from "../src/v2/v4/LaunchFairVRFCoordinator.sol";
import {LaunchFairV4FeeLocker} from "../src/v2/v4/LaunchFairV4FeeLocker.sol";
import {LaunchFairV4Distributor} from "../src/v2/v4/LaunchFairV4Distributor.sol";
import {TokenDeployerV2} from "../src/v2/TokenDeployerV2.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {IUniswapV3Factory, IV3SwapRouter} from "../src/interfaces/IUniswapV3.sol";

/// Deploys the full LaunchFair V4 (mode-token) stack and wires it end to end:
///   VRF coordinator -> fee locker -> distributor -> token deployer -> launchpad,
/// then hooks up the keeper as the draw operator and the buyback processor (so the
/// auto-payout loop and lottery draws work out of the box). Posting drand beacons to
/// the coordinator needs no role — it's permissionless and verified on-chain.
///
/// Real-chain deploy only — V4 has no simple mock, so every external address must be
/// set. Env:
///   PRIVATE_KEY      — deployer key (also the initial admin owner unless OWNER set)
///   OWNER            — admin owner of every contract       (default: deployer)
///   KEEPER           — keeper wallet: drawOperator + buyback processor
///                                                          (default: deployer)
///   TREASURY         — protocol treasury (fee + creation-fee sink)
///   POOL_MANAGER     — Uniswap V4 PoolManager singleton
///   WETH             — chain's canonical wrapped native
///   UNIV3_FACTORY    — Uniswap V3 factory (validates V3 reward/prize pools exist)
///   V3_SWAP_ROUTER   — Uniswap SwapRouter02 (V3 reward/prize buybacks)
///   WEBSITE          — platform site stamped into every token
///
/// WARNING — verify the pool-shape constants below (supply, initial price, tick
/// spacing, and the single-sided tick range) against the chosen fee tier and price
/// on the REAL chain before broadcasting, exactly as for the V3 deploy. The wiring
/// is chain-agnostic; the tick math is not.
contract DeployV4 is Script {
    // ── pool shape (VERIFY before a real broadcast) ──────────────────────────────
    // Matches the V3 launchpad's economics: ~1.49e-9 WETH/token launch price → ~1.5 WETH
    // launch mcap. The EFFECTIVE launch price is set by the liquidity range bottom
    // (TICK_LOWER0), not INITIAL_PRICE — INITIAL_PRICE just starts the pool at/below it.
    uint128 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant INITIAL_PRICE = 1491146318; // WETH wei per whole token at launch (~1.49e-9)
    int24 constant TICK_SPACING = 200;
    int24 constant TICK_LOWER0 = -203200; // single-sided range start (token == currency0): price ~1.49e-9
    int24 constant TICK_UPPER0 = -143400; // single-sided range end (~395x above launch)
    uint16 constant MAX_BUY_BPS = 200; // 2% wallet cap during the launch window…
    uint32 constant MAX_BUY_BLOCKS = 100; // …for the first 100 L1 blocks (0 = off); owner-tunable post-deploy

    // Known Robinhood Chain mainnet addresses (override via env for other envs).
    address constant DEFAULT_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant DEFAULT_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant DEFAULT_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant DEFAULT_V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant DEFAULT_TREASURY = 0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3;
    // The standalone LaunchFairV4SwapRouter (stateless, reused across redeploys) — used by
    // createAndBuy for the atomic dev buy.
    address constant DEFAULT_V4_SWAP_ROUTER = 0x0e6c53664388B68F6b41851D224248F391CC8947;
    // The live TokenDeployerV2 (stateless CREATE2 factory, reused across redeploys so every
    // token generation — including the CoreTGE's core token — shares ONE on-chain creator,
    // which is what external indexers key on). Zero => deploy a fresh one.
    address constant DEFAULT_TOKEN_DEPLOYER = 0x87500DEedDb7C3F2a4c1Df435611a9b15590b2B6;

    function run() external {
        // Foundry auto-loads the repo .env: fall back to the tester key so no shell-level
        // secret plumbing is needed to run this script.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        address keeper = vm.envOr("KEEPER", deployer);
        address treasury = vm.envOr("TREASURY", DEFAULT_TREASURY);

        IPoolManager pm = IPoolManager(vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER));
        address weth = vm.envOr("WETH", DEFAULT_WETH);
        IUniswapV3Factory v3Factory = IUniswapV3Factory(vm.envOr("UNIV3_FACTORY", DEFAULT_V3_FACTORY));
        IV3SwapRouter v3Router = IV3SwapRouter(vm.envOr("V3_SWAP_ROUTER", DEFAULT_V3_ROUTER));
        string memory website = vm.envOr("WEBSITE", string("https://hood.launchfair.app/"));

        require(address(pm) != address(0) && weth != address(0), "set POOL_MANAGER + WETH");
        require(address(v3Factory) != address(0) && address(v3Router) != address(0), "set V3 factory + router");

        vm.startBroadcast(pk);

        // 1. Shared randomness coordinator. Permissionless + trustless: postRandomness
        //    verifies the drand BLS signature on-chain, so it needs no owner or poster.
        LaunchFairVRFCoordinator vrf = new LaunchFairVRFCoordinator();

        // 2. Fee locker (owns every token's single-sided position forever).
        LaunchFairV4FeeLocker locker = new LaunchFairV4FeeLocker(owner, pm, IERC20(weth), treasury);

        // 3. Distributor. registrar is a placeholder here (the launchpad doesn't exist
        //    yet); setRegistrar points it at the launchpad below and then freezes it.
        LaunchFairV4Distributor dist =
            new LaunchFairV4Distributor(owner, pm, v3Router, IERC20(weth), owner);

        // 4. Token deployer (holds the token bytecode; keeps the launchpad under EIP-170).
        //    Reused across stack generations by default — one creator address for every token.
        address td = vm.envOr("TOKEN_DEPLOYER", DEFAULT_TOKEN_DEPLOYER);
        TokenDeployerV2 tokenDeployer = td == address(0) ? new TokenDeployerV2() : TokenDeployerV2(td);

        // 5. The launchpad.
        LaunchFairV4 pad = new LaunchFairV4(
            owner,
            pm,
            v3Factory,
            locker,
            address(dist),
            tokenDeployer,
            weth,
            TOTAL_SUPPLY,
            INITIAL_PRICE,
            TICK_SPACING,
            TICK_LOWER0,
            TICK_UPPER0,
            MAX_BUY_BPS,
            MAX_BUY_BLOCKS,
            website
        );

        // 6. Wire everything. These setters are owner-gated; if OWNER != deployer, run
        //    them from the owner instead (the broadcast key must be the owner).
        locker.setLaunchpad(address(pad));
        locker.setDistributor(address(dist));
        dist.setLocker(address(locker));
        dist.setRegistrar(address(pad)); // set-once: freezes the registrar (L-03)
        dist.setVrf(address(vrf));
        dist.setDrawOperator(keeper); // keeper commits/settles lottery draws
        dist.setProcessor(keeper, true); // keeper may fire buybacks with a quoted minOut (M-02)
        pad.setSwapRouter(vm.envOr("V4_SWAP_ROUTER", DEFAULT_V4_SWAP_ROUTER)); // atomic dev buy

        vm.stopBroadcast();

        console2.log("owner:            ", owner);
        console2.log("keeper:           ", keeper);
        console2.log("treasury:         ", treasury);
        console2.log("PoolManager:      ", address(pm));
        console2.log("WETH:             ", weth);
        console2.log("VRF Coordinator:  ", address(vrf));
        console2.log("FeeLocker (V4):   ", address(locker));
        console2.log("Distributor:      ", address(dist));
        console2.log("TokenDeployer:    ", address(tokenDeployer));
        console2.log("LaunchFairV4:     ", address(pad));
    }
}
