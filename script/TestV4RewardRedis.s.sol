// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISwapRouter {
    function buy(PoolKey calldata key, uint256 minOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out);
}

/// Live check: create a Reward token + a Redistribute token on the current launchpad and
/// seed each with a buy so the keeper has fees to process. The Reward asset is an existing
/// V3 launchpad token (0xc47d…, real 1% WETH pool) since WETH can't be a reward.
contract TestV4RewardRedis is Script {
    address constant PAD = 0x05288001d14162322Bb28Abe105A23e7691C39eE;
    address constant ROUTER = 0x0e6c53664388B68F6b41851D224248F391CC8947;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant REWARD_ASSET = 0xc47DA5396AF44E4EDEAA912f1da10CB3843b72ac; // has 1% V3 WETH pool
    uint24 constant FEE = 100_000; // 10% mode-token fee tier
    int24 constant TICK_SPACING = 200;
    uint256 constant BUY = 0.004 ether;

    function _key(address token) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = token < WETH
            ? (Currency.wrap(token), Currency.wrap(WETH))
            : (Currency.wrap(WETH), Currency.wrap(token));
        return PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(0))});
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        LaunchFairV4 pad = LaunchFairV4(PAD);
        ISwapRouter router = ISwapRouter(ROUTER);
        uint256 feeWei = pad.creationFeeWei();

        LaunchTokenV2.Metadata memory meta = LaunchTokenV2.Metadata({
            logoURI: "", website: "https://hood.launchfair.app/", telegram: "", discord: "", twitter: ""
        });
        PoolKey memory empty = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(0)),
            fee: 0, tickSpacing: 0, hooks: IHooks(address(0))
        });

        // Reward token: one reward asset (the existing V3 token), full weight, V3 venue.
        LaunchFairV4.RewardVenue[] memory rv = new LaunchFairV4.RewardVenue[](1);
        rv[0] = LaunchFairV4.RewardVenue({
            token: REWARD_ASSET, weightBps: 10_000, isV3: true, v3Fee: 10_000, v4Key: empty
        });
        LaunchFairV4.CreateParams memory rp = LaunchFairV4.CreateParams({
            name: "Reward Test", symbol: "RWDT", metadata: meta, salt: keccak256("reward-test-1"),
            mode: LaunchTokenV2.Mode.Reward, fee: FEE, rewards: rv,
            prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: empty,
            minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
        });

        // Redistribute token: no external asset (buys back its own pool → balances grow).
        LaunchFairV4.CreateParams memory dp = LaunchFairV4.CreateParams({
            name: "Redistribute Test", symbol: "REDT", metadata: meta, salt: keccak256("redistribute-test-1"),
            mode: LaunchTokenV2.Mode.Increasing, fee: FEE, rewards: new LaunchFairV4.RewardVenue[](0),
            prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: empty,
            minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
        });

        vm.startBroadcast(pk);
        address reward = pad.createToken{value: feeWei}(rp);
        address redis = pad.createToken{value: feeWei}(dp);
        router.buy{value: BUY}(_key(reward), 0, me, block.timestamp + 3600);
        router.buy{value: BUY}(_key(redis), 0, me, block.timestamp + 3600);
        vm.stopBroadcast();

        console2.log("REWARD token (RWDT):    ", reward);
        console2.log("  mode (1=Reward):      ", uint8(LaunchTokenV2(reward).mode()));
        console2.log("  my RWDT balance:      ", LaunchTokenV2(reward).balanceOf(me));
        console2.log("  my reward-asset bal:  ", IERC20(REWARD_ASSET).balanceOf(me));
        console2.log("REDIS token (REDT):     ", redis);
        console2.log("  mode (2=Increasing):  ", uint8(LaunchTokenV2(redis).mode()));
        console2.log("  my REDT balance:      ", LaunchTokenV2(redis).balanceOf(me));
    }
}
