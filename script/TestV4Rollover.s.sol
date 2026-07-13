// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

interface ISwapRouter {
    function buy(PoolKey calldata key, uint256 minOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out);
}

/// Live check of the ROLLOVER jackpot: create a Lottery token with a hard per-draw hit
/// chance and seed the pot with a buy. The keeper then commits draws; each one either HITS
/// (winner takes the whole pot) or MISSES (pot rolls over). Chance = 50% so we see both fast.
contract TestV4Rollover is Script {
    address constant PAD = 0x95082BdfaA8A354c60771914C1628cC8B45c5f66;
    address constant ROUTER = 0x0e6c53664388B68F6b41851D224248F391CC8947;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    uint24 constant FEE = 100_000;
    int24 constant TICK_SPACING = 200;
    uint256 constant BUY = 0.0015 ether;

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
        PoolKey memory empty = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(0)),
            fee: 0, tickSpacing: 0, hooks: IHooks(address(0))
        });
        LaunchTokenV2.Metadata memory meta = LaunchTokenV2.Metadata({
            logoURI: "", website: "https://hood.launchfair.app/", telegram: "", discord: "", twitter: ""
        });
        LaunchFairV4.CreateParams memory p = LaunchFairV4.CreateParams({
            name: "Rollover Jackpot", symbol: "ROLL", metadata: meta, salt: keccak256("rollover-test-1"),
            mode: LaunchTokenV2.Mode.Lottery, fee: FEE, rewards: new LaunchFairV4.RewardVenue[](0),
            prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: empty,
            minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, jackpotChanceBps: 5000 // 50% per draw
        });
        uint256 feeWei = pad.creationFeeWei();

        vm.startBroadcast(pk);
        address token = pad.createToken{value: feeWei}(p);
        router.buy{value: BUY}(_key(token), 0, me, block.timestamp + 3600);
        vm.stopBroadcast();

        LaunchTokenV2 t = LaunchTokenV2(token);
        console2.log("ROLL token:          ", token);
        console2.log("mode (3=Lottery):    ", uint8(t.mode()));
        console2.log("my balance:          ", t.balanceOf(me));
        console2.log("totalEligibleSupply: ", t.totalEligibleSupply());
    }
}
