// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

/// Live check: create a holdings-weighted Lottery token (WETH pot) on the new launchpad.
contract TestV4Lottery is Script {
    address constant PAD = 0x05288001d14162322Bb28Abe105A23e7691C39eE;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        LaunchFairV4 pad = LaunchFairV4(PAD);
        PoolKey memory empty = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(0)),
            fee: 0, tickSpacing: 0, hooks: IHooks(address(0))
        });
        LaunchTokenV2.Metadata memory meta = LaunchTokenV2.Metadata({
            logoURI: "", website: "https://hood.launchfair.app/", telegram: "", discord: "", twitter: ""
        });
        LaunchFairV4.CreateParams memory p = LaunchFairV4.CreateParams({
            name: "Price Check", symbol: "PCHK", metadata: meta, salt: keccak256("price-check-1"),
            mode: LaunchTokenV2.Mode.Lottery, fee: 100_000,
            rewards: new LaunchFairV4.RewardVenue[](0),
            prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: empty,
            minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
        });
        uint256 feeWei = pad.creationFeeWei();
        vm.startBroadcast(pk);
        address token = pad.createToken{value: feeWei}(p);
        vm.stopBroadcast();

        LaunchTokenV2 t = LaunchTokenV2(token);
        console2.log("token:              ", token);
        console2.log("mode (3=Lottery):   ", uint8(t.mode()));
        console2.log("lotteryOperator:    ", t.lotteryOperator());
        console2.log("totalEligibleSupply:", t.totalEligibleSupply()); // 0: only the excluded pool holds tokens
    }
}
