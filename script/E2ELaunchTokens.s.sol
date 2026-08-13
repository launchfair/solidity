// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

/// E2E seed: launches the demo token fleet on a fresh stack, every mode with a real logo
/// (DiceBear PNG URLs — deterministic per symbol, so the UI looks neat, not blank):
///   1. Reward (NVDA)   "Nebula"        NBLA
///   2. Redistribute    "Compound Cat"  CCAT
///   3. Lottery         "Lucky Ladle"   LDLE
///   4. Stock/COIN      "Coin Rocket"   CROCK  (direct WETH quote)
///   5. Stock/NVDA      "Green Chip"    GCHIP  (USDG-routed quote)
/// Env: PRIVATE_KEY (or TESTER_DEPLOYER_PKEY via .env), LAUNCHPAD [required].
contract E2ELaunchTokens is Script {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant COIN = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;
    uint24 constant FEE = 100_000; // 10% tier

    function _params(string memory name, string memory symbol, LaunchTokenV2.Mode mode)
        internal
        view
        returns (LaunchFairV4.CreateParams memory p)
    {
        p.name = name;
        p.symbol = symbol;
        p.metadata.logoURI = string.concat("https://api.dicebear.com/9.x/shapes/png?size=256&seed=", symbol);
        p.metadata.website = "https://hood.launchfair.app/";
        p.metadata.twitter = "@launchfair";
        p.salt = keccak256(abi.encodePacked("e2e-fleet", symbol, block.timestamp));
        p.mode = mode;
        p.fee = FEE;
        p.rewards = new LaunchFairV4.RewardVenue[](0);
        p.perps = new LaunchFairV4.PerpLeg[](0);
    }

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        LaunchFairV4 pad = LaunchFairV4(vm.envAddress("LAUNCHPAD"));
        uint256 feeWei = pad.creationFeeWei();

        vm.startBroadcast(pk);

        LaunchFairV4.CreateParams memory rp = _params("Nebula", "NBLA", LaunchTokenV2.Mode.Reward);
        rp.rewards = new LaunchFairV4.RewardVenue[](1);
        rp.rewards[0] = LaunchFairV4.RewardVenue({
            token: NVDA,
            weightBps: 10_000,
            isV3: true,
            v3Fee: 3000,
            v4Key: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            })
        });
        address nbla = pad.createToken{value: feeWei}(rp);

        address ccat = pad.createToken{value: feeWei}(_params("Compound Cat", "CCAT", LaunchTokenV2.Mode.Increasing));
        address ldle = pad.createToken{value: feeWei}(_params("Lucky Ladle", "LDLE", LaunchTokenV2.Mode.Lottery));
        address crock =
            pad.createStockToken{value: feeWei}(_params("Coin Rocket", "CROCK", LaunchTokenV2.Mode.Base), COIN);
        address gchip =
            pad.createStockToken{value: feeWei}(_params("Green Chip", "GCHIP", LaunchTokenV2.Mode.Base), NVDA);

        vm.stopBroadcast();

        console2.log("NBLA (Reward/NVDA):    ", nbla);
        console2.log("CCAT (Redistribute):   ", ccat);
        console2.log("LDLE (Lottery):        ", ldle);
        console2.log("CROCK (Stock/COIN):    ", crock);
        console2.log("GCHIP (Stock/NVDA):    ", gchip);
    }
}
