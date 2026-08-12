// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {StockPairRouter, IWETH, ILaunchpadV4} from "../src/v2/v4/StockPairRouter.sol";
import {RouterGateHook} from "../src/v2/v4/RouterGateHook.sol";
import {IV3SwapRouter} from "../src/interfaces/IUniswapV3.sol";
import {HookMiner} from "./HookMiner.sol";

interface ILaunchpadAdmin {
    function setStockPairRouter(address r) external;
    function setStockGateHook(address hook) external;
    function setAllowedQuote(address stock, bool allowed, uint24 v3Fee) external;
}

/// Deploys the stock-paired stack for an existing LaunchFairV4: the StockPairRouter + a mined
/// RouterGateHook bound to it, wires them onto the launchpad, sets the router's fee destinations,
/// and allow-lists the initial liquid Robinhood stock quotes (NVDA, AAPL) with their <stock>/WETH V3
/// fee tiers. Add more quotes later with `LaunchFairV4.setAllowedQuote`.
///
/// Env:
///   PRIVATE_KEY    deployer key (becomes the router owner)                    [required]
///   POOL_MANAGER   the Uniswap V4 PoolManager                                 [required]
///   WETH           the WETH ERC20                                             [required]
///   V3_ROUTER      Uniswap V3 SwapRouter02 (for the <stock>/WETH hop)         [required]
///   LAUNCHPAD      the LaunchFairV4 to extend                                 [required]
///   TREASURY       platform treasury (fee split + fallback)                   [required]
///   FLAGSHIP_SINK  flagship buyback sink                                      [optional]
///   STOCK_FEE_BPS  router fee in bps of the WETH leg (default 100 = 1%)       [optional]
contract DeployStockPair is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // First-party Robinhood tokenized stocks + the deepest <stock>/WETH V3 fee tier (verified live).
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address weth = vm.envAddress("WETH");
        address v3Router = vm.envAddress("V3_ROUTER");
        address launchpad = vm.envAddress("LAUNCHPAD");
        address treasury = vm.envAddress("TREASURY");
        address flagshipSink = vm.envOr("FLAGSHIP_SINK", address(0));
        uint16 feeBps = uint16(vm.envOr("STOCK_FEE_BPS", uint256(100)));

        vm.startBroadcast(pk);

        StockPairRouter router = new StockPairRouter(
            owner, pm, IWETH(weth), IV3SwapRouter(v3Router), ILaunchpadV4(launchpad), feeBps
        );
        router.setDestinations(treasury, flagshipSink);

        // The gate hook's address must encode BEFORE_SWAP only; CREATE2-mine a matching salt.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(pm, address(router));
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(RouterGateHook).creationCode, args);
        RouterGateHook gate = new RouterGateHook{salt: salt}(pm, address(router));
        require(address(gate) == hookAddr, "mined-address mismatch");

        ILaunchpadAdmin pad = ILaunchpadAdmin(launchpad);
        pad.setStockPairRouter(address(router));
        pad.setStockGateHook(address(gate));
        pad.setAllowedQuote(NVDA, true, 3000); // NVDA/WETH — deepest at 0.3%
        pad.setAllowedQuote(AAPL, true, 500); // AAPL/WETH — deepest at 0.05%

        vm.stopBroadcast();

        console2.log("StockPairRouter:", address(router));
        console2.log("RouterGateHook: ", address(gate));
        console2.log("  feeBps:       ", feeBps);
        console2.log("Allow-listed quotes: NVDA, AAPL (add more via LaunchFairV4.setAllowedQuote)");
    }
}
