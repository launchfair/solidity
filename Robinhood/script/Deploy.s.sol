// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {V3Launchpad} from "../src/V3Launchpad.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {IUniswapV3Factory, INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockV3Factory, MockPositionManager} from "../test/mocks/MockUniswapV3.sol";

/// Deploys the V3 hybrid launchpad. Env overrides:
///   WETH             — chain's canonical wrapped native (default: MockWETH, local only)
///   UNIV3_FACTORY    — Uniswap V3 factory (default: mock, local only)
///   POSITION_MANAGER — Uniswap V3 NonfungiblePositionManager (default: mock, local only)
///   TREASURY         — treasury payout address (default: the deployer)
///   WEBSITE          — platform site stamped into every token
///   PRIVATE_KEY      — deployer key (default: anvil account 0, local only)
///
/// NOTE for real chains: verify the tick constants against the chosen fee
/// tier's spacing and the initial price BEFORE deploying (see AUDIT.md), and
/// run the fork test against the real factory/position manager.
contract Deploy is Script {
    uint128 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant INITIAL_PRICE = 1_491_146_318; // WETH wei per whole token
    uint24 constant FEE_TIER = 10_000; // 1% per swap
    int24 constant TICK_LOWER0 = -203_200;
    int24 constant TICK_UPPER0 = 887_200;
    uint256 constant GRADUATION_PRICE = 15 * INITIAL_PRICE; // milestone at 15x launch

    // Default: anvil's well-known account 0, for local runs. Set PRIVATE_KEY for real deploys.
    uint256 constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", ANVIL_KEY_0);
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        address weth = vm.envOr("WETH", address(0));
        if (weth == address(0)) weth = address(new MockWETH());
        address factory = vm.envOr("UNIV3_FACTORY", address(0));
        if (factory == address(0)) factory = address(new MockV3Factory());
        address positionManager = vm.envOr("POSITION_MANAGER", address(0));
        if (positionManager == address(0)) positionManager = address(new MockPositionManager());
        // Platform treasury: receives the 50% WETH fee share and the flat
        // per-token creation fee. Override with TREASURY env if needed.
        address treasury = vm.envOr("TREASURY", address(0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3));

        FeeLocker locker = new FeeLocker(deployer, INonfungiblePositionManager(positionManager), IERC20(weth), treasury);
        V3Launchpad pad = new V3Launchpad(
            deployer,
            IUniswapV3Factory(factory),
            INonfungiblePositionManager(positionManager),
            locker,
            weth,
            V3Launchpad.PoolConfig({
                feeTier: FEE_TIER,
                tickLower0: TICK_LOWER0,
                tickUpper0: TICK_UPPER0,
                tokenTotalSupply: TOTAL_SUPPLY,
                initialPriceWethPerToken: INITIAL_PRICE,
                graduationPriceWethPerToken: GRADUATION_PRICE,
                maxBuyBps: 200, // 2% wallet cap...
                maxBuyBlocks: 360 // ...for the first 360 blocks
            }),
            vm.envOr("WEBSITE", string("https://fun.example.xyz"))
        );
        locker.setLaunchpad(address(pad));

        vm.stopBroadcast();

        console2.log("WETH:            ", weth);
        console2.log("V3 Factory:      ", factory);
        console2.log("Position Manager:", positionManager);
        console2.log("FeeLocker:       ", address(locker));
        console2.log("V3Launchpad:     ", address(pad));
        console2.log("Treasury:        ", treasury);
    }
}
