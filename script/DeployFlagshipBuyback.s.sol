// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlagshipBuyback, IWETH9B} from "../src/flywheel/FlagshipBuyback.sol";
import {SeasonMerkleDistributor} from "../src/flywheel/SeasonMerkleDistributor.sol";
import {IUniswapV3Factory, IV3SwapRouter} from "../src/interfaces/IUniswapV3.sol";

/// POST-CORE-LAUNCH deploy: the FlagshipBuyback vault + its SeasonMerkleDistributor, wired as
/// a pair (the distributor's rootPublisher is the VAULT, so bought core never touches an EOA).
/// Afterwards repoint every flagship sink (V4 locker, stock router, StockFeeHook) at the vault;
/// the cron then just calls vault.buyback() / vault.publishSeason() with the owner key.
///
/// Env: PRIVATE_KEY (or TESTER_DEPLOYER_PKEY via .env), CORE [required]; WETH, V3_FACTORY,
/// V3_ROUTER, TREASURY, POOL_FEE [defaults below].
contract DeployFlagshipBuyback is Script {
    address constant DEFAULT_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant DEFAULT_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant DEFAULT_V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant DEFAULT_TREASURY = 0x82C8f63D0E578bA3d800BA5d48F8e9dD2a009Af3;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        address owner = vm.addr(pk);
        address core = vm.envAddress("CORE");
        address weth = vm.envOr("WETH", DEFAULT_WETH);
        address factory = vm.envOr("V3_FACTORY", DEFAULT_V3_FACTORY);
        address v3Router = vm.envOr("V3_ROUTER", DEFAULT_V3_ROUTER);
        address treasury = vm.envOr("TREASURY", DEFAULT_TREASURY);
        uint24 poolFee = uint24(vm.envOr("POOL_FEE", uint256(10_000)));

        vm.startBroadcast(pk);
        FlagshipBuyback vault = new FlagshipBuyback(
            owner, IWETH9B(weth), IUniswapV3Factory(factory), IV3SwapRouter(v3Router), IERC20(core), poolFee
        );
        SeasonMerkleDistributor dist =
            new SeasonMerkleDistributor(owner, IERC20(core), treasury, address(vault));
        vault.setDistributor(address(dist));

        // Keeper gas auto-top-up: the vault keeps the cron wallet funded from fee ETH, so the
        // flywheel never stalls on an empty keeper. Off unless KEEPER is provided.
        address keeper = vm.envOr("KEEPER", address(0));
        if (keeper != address(0)) {
            // Authorize the cron for buyback + publishSeason ONLY (never the withdrawals), so the
            // hot key can move value along the on-chain flow but can't drain the vault.
            vault.setKeeper(keeper, true);
            vault.setGasPolicy(
                keeper,
                vm.envOr("GAS_FLOOR_WEI", uint256(0.03 ether)),
                vm.envOr("GAS_MAX_PER_TOPUP_WEI", uint256(0.02 ether)),
                vm.envOr("GAS_DAILY_CAP_WEI", uint256(0.1 ether))
            );
        }
        vm.stopBroadcast();

        console2.log("FlagshipBuyback vault:  ", address(vault));
        console2.log("SeasonMerkleDistributor:", address(dist));
        console2.log("  rootPublisher = the vault; owner =", owner);
        console2.log("  keeper gas top-up:", keeper);
        console2.log("Next: repoint locker/router/hook flagship sinks -> the vault");
    }
}
