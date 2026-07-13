// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

/// Re-launch $RobinBall on the createAndBuy stack, with an atomic dev buy (also live-verifies
/// createAndBuy). Default 3-outcome odds (10% miss / 2% jackpot / 88% regular @ 70/30), 1-hour
/// time-based draw cadence, payoutThreshold 0.
contract RelaunchRobinBall is Script {
    address constant PAD = 0x1Eb48f62c37c2455c7a0Ad4662C7cd774e19e858;
    uint24 constant FEE = 100_000; // 10% mode-token fee funds the pot
    uint256 constant DEV_BUY = 0.002 ether;
    uint256 constant DRAW_EVERY_BLOCKS = 300; // ~1 hour of L1 blocks (12s each)

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        LaunchFairV4 pad = LaunchFairV4(PAD);

        PoolKey memory empty = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(0)),
            fee: 0, tickSpacing: 0, hooks: IHooks(address(0))
        });
        LaunchTokenV2.Metadata memory meta = LaunchTokenV2.Metadata({
            logoURI: "https://green-left-alpaca-676.mypinata.cloud/ipfs/bafybeifukdx4o4f6tnwspqwwyqqkvepjib2trxmf5tkvfno7oz5yjbz2yu",
            website: "https://robinball.app", telegram: "", discord: "", twitter: "https://x.com/robinballrh"
        });
        LaunchFairV4.CreateParams memory p = LaunchFairV4.CreateParams({
            name: "Robinhood Lottery", symbol: "RobinBall", metadata: meta, salt: keccak256("robinball-v2"),
            mode: LaunchTokenV2.Mode.Lottery, fee: FEE, rewards: new LaunchFairV4.RewardVenue[](0),
            prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: empty,
            minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: DRAW_EVERY_BLOCKS,
            missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0 // 0 → launchpad defaults
        });
        uint256 feeWei = pad.creationFeeWei();

        vm.startBroadcast(pk);
        address token = pad.createAndBuy{value: feeWei + DEV_BUY}(p, 0);
        vm.stopBroadcast();

        LaunchTokenV2 t = LaunchTokenV2(token);
        console2.log("NEW RobinBall CA:    ", token);
        console2.log("mode (3=Lottery):    ", uint8(t.mode()));
        console2.log("dev bag (createAndBuy):", t.balanceOf(me));
        console2.log("totalEligibleSupply: ", t.totalEligibleSupply());
    }
}
