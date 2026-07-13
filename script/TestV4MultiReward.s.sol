// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";
import {LaunchFairV4Distributor} from "../src/v2/v4/LaunchFairV4Distributor.sol";

/// Live validation: create a Reward token that distributes TWO existing WETH-paired
/// tokens in parallel (60/40 split), then read back the on-chain reward config +
/// per-asset buyback venues to confirm the multi-reward wiring.
contract TestV4MultiReward is Script {
    address constant PAD = 0x7c94c5c0804C1e55CC4Ee6B6979c0219e37ef4b0;
    address constant DIST = 0x01be7000DD51c6E5ED5875aD1bE2aDD06675b839;
    address constant REWARD_A = 0x3b387BEe3481A1027446AF768a2547016cE38F21; // 60%
    address constant REWARD_B = 0xbfbf8d5072eE49CAc4Ecc8F238b7593727A71055; // 40%

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        LaunchFairV4 pad = LaunchFairV4(PAD);

        PoolKey memory empty =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(0)), fee: 0, tickSpacing: 0, hooks: IHooks(address(0))});

        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](2);
        rewards[0] = LaunchFairV4.RewardVenue({token: REWARD_A, weightBps: 6_000, isV3: true, v3Fee: 10_000, v4Key: empty});
        rewards[1] = LaunchFairV4.RewardVenue({token: REWARD_B, weightBps: 4_000, isV3: true, v3Fee: 10_000, v4Key: empty});

        LaunchTokenV2.Metadata memory meta = LaunchTokenV2.Metadata({
            logoURI: "", website: "https://hood.launchfair.app/", telegram: "", discord: "", twitter: ""
        });

        LaunchFairV4.CreateParams memory p = LaunchFairV4.CreateParams({
            name: "MultiReward Live",
            symbol: "MRWD",
            metadata: meta,
            salt: keccak256("multireward-live-1"),
            mode: LaunchTokenV2.Mode.Reward,
            fee: 30_000,
            rewards: rewards,
            prizeToken: address(0),
            prizeIsV3: false,
            prizeV3Fee: 0,
            prizePoolKey: empty,
            minHold: 0,
            payoutThreshold: 0,
            payoutIntervalBlocks: 0, jackpotChanceBps: 10000
        });

        uint256 feeWei = pad.creationFeeWei();

        vm.startBroadcast(pk);
        address token = pad.createToken{value: feeWei}(p);
        vm.stopBroadcast();

        LaunchTokenV2 t = LaunchTokenV2(token);
        address[] memory list = t.rewardTokensList();
        LaunchFairV4Distributor dist = LaunchFairV4Distributor(DIST);

        console2.log("token:            ", token);
        console2.log("mode (1=Reward):  ", uint8(t.mode()));
        console2.log("reward count:     ", list.length);
        console2.log("asset0:           ", list[0]);
        console2.log("  weightBps:      ", t.rewardWeightBps(list[0]));
        console2.log("  venue(1=V3):    ", dist.buybackVenue(token, list[0]));
        console2.log("asset1:           ", list[1]);
        console2.log("  weightBps:      ", t.rewardWeightBps(list[1]));
        console2.log("  venue(1=V3):    ", dist.buybackVenue(token, list[1]));
        console2.log("pad.creatorOf:    ", pad.creatorOf(token));
    }
}
