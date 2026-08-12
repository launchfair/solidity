// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";
import {LaunchFairV4FeeLocker} from "../src/v2/v4/LaunchFairV4FeeLocker.sol";
import {StockPairRouter} from "../src/v2/v4/StockPairRouter.sol";

interface IV4SwapRouter {
    function buy(PoolKey calldata key, uint256 minOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out);
    function sell(PoolKey calldata key, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        returns (uint256 out);
}

interface IDistributor {
    function pendingWeth(address token) external view returns (uint256);
    function process(address token, uint256[] calldata minOuts) external;
    function jackpotChanceBps(address token) external view returns (uint16);
    function missBps(address token) external view returns (uint16);
}

/// Live end-to-end check of EVERY launchable token type (Perps excluded — sunset) on the
/// current V4 stack: Reward, Redistribute (Increasing), Lottery, and a DIRECT-quoted stock
/// pair (the USDG-routed variant is covered by SmokeStockPair). For each: launch → buy →
/// sell → and for the mechanism modes, the full fee loop (locker.claim → distributor pot →
/// process() buyback → holder payout observed).
/// Env: PRIVATE_KEY (stack owner — needed for process()).
contract TestV4Modes is Script {
    address constant PAD = 0xE30fA0e668b1bd229854b70d7F3d7B4D48e0A8C5;
    address constant V4_ROUTER = 0x0e6c53664388B68F6b41851D224248F391CC8947;
    address constant STOCK_ROUTER = 0x502Bba6Bf09C430e63709335904dCE5AcA2b6cF6;
    address constant LOCKER = 0x366d2dC5d7b600D582e553C1380cf0F45F684651;
    address constant DIST = 0xD58E7d7c65E3f3CEe3a89F8E29E16B0c369b11A3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // reward asset (real V3 WETH pool @0.3%)
    address constant COIN = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b; // direct-WETH stock quote
    uint24 constant FEE = 100_000; // 10% tier → chunky LP fees from small trades
    uint256 constant BUY = 0.001 ether;

    function _key(address token) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = token < WETH
            ? (Currency.wrap(token), Currency.wrap(WETH))
            : (Currency.wrap(WETH), Currency.wrap(token));
        return PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: 200, hooks: IHooks(address(0))});
    }

    function _params(string memory name, string memory symbol, LaunchTokenV2.Mode mode)
        internal
        view
        returns (LaunchFairV4.CreateParams memory p)
    {
        p.name = name;
        p.symbol = symbol;
        p.metadata.website = "https://hood.launchfair.app/";
        p.salt = keccak256(abi.encodePacked("e2e-modes", name, block.timestamp));
        p.mode = mode;
        p.fee = FEE;
        p.rewards = new LaunchFairV4.RewardVenue[](0);
        p.perps = new LaunchFairV4.PerpLeg[](0);
    }

    /// buy → sell a third → claim LP fees into the mechanism pot. Returns the pot.
    function _tradeAndClaim(address token, address me) internal returns (uint256 pot) {
        IV4SwapRouter router = IV4SwapRouter(V4_ROUTER);
        PoolKey memory key = _key(token);
        uint256 got = router.buy{value: BUY}(key, 0, me, block.timestamp + 3600);
        IERC20(token).approve(V4_ROUTER, got / 3);
        router.sell(key, got / 3, 0, me, block.timestamp + 3600);
        LaunchFairV4FeeLocker(payable(LOCKER)).claim(token);
        pot = IDistributor(DIST).pendingWeth(token);
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        LaunchFairV4 pad = LaunchFairV4(PAD);
        uint256 feeWei = pad.creationFeeWei();
        uint256[] memory minOuts = new uint256[](1);

        vm.startBroadcast(pk);

        // ── 1. REWARD (holders earn NVDA) ────────────────────────────────────────
        LaunchFairV4.CreateParams memory rp = _params("E2E Reward", "E2ERWD", LaunchTokenV2.Mode.Reward);
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
        address reward = pad.createToken{value: feeWei}(rp);
        uint256 rewardPot = _tradeAndClaim(reward, me);
        IDistributor(DIST).process(reward, minOuts); // buys NVDA, funds the holder tracker
        uint256 nvdaEarned = LaunchTokenV2(reward).withdrawableDividendOf(NVDA, me);
        console2.log("1) REWARD  token:", reward);
        console2.log("   pot (WETH) after claim:", rewardPot);
        console2.log("   my withdrawable NVDA:  ", nvdaEarned);

        // ── 2. REDISTRIBUTE (balances auto-grow) ─────────────────────────────────
        address redis = pad.createToken{value: feeWei}(_params("E2E Redis", "E2ERED", LaunchTokenV2.Mode.Increasing));
        uint256 redisPot = _tradeAndClaim(redis, me);
        uint256 balBefore = LaunchTokenV2(redis).balanceOf(me);
        IDistributor(DIST).process(redis, minOuts); // buys the token back, reflects to holders
        uint256 balAfter = LaunchTokenV2(redis).balanceOf(me);
        console2.log("2) REDIS   token:", redis);
        console2.log("   pot (WETH) after claim:", redisPot);
        console2.log("   my balance before/after process:", balBefore, balAfter);

        // ── 3. LOTTERY (holdings-weighted, ETH pot) ──────────────────────────────
        address lotto = pad.createToken{value: feeWei}(_params("E2E Lotto", "E2ELOT", LaunchTokenV2.Mode.Lottery));
        uint256 lottoPot = _tradeAndClaim(lotto, me);
        console2.log("3) LOTTERY token:", lotto);
        console2.log("   pot (WETH) after claim:", lottoPot);
        console2.log("   my tickets (=balance): ", LaunchTokenV2(lotto).balanceOf(me));
        console2.log("   eligible supply:       ", LaunchTokenV2(lotto).totalEligibleSupply());
        console2.log("   jackpot/miss bps:      ", IDistributor(DIST).jackpotChanceBps(lotto), IDistributor(DIST).missBps(lotto));

        // ── 4. STOCK PAIR, DIRECT WETH QUOTE (COIN) ──────────────────────────────
        LaunchFairV4.CreateParams memory sp = _params("E2E Coin Stock", "E2ECOIN", LaunchTokenV2.Mode.Base);
        address stockTok = LaunchFairV4(PAD).createStockToken{value: feeWei}(sp, COIN);
        StockPairRouter srouter = StockPairRouter(payable(STOCK_ROUTER));
        uint256 sGot = srouter.buy{value: BUY}(stockTok, 0, me, block.timestamp + 3600);
        IERC20(stockTok).approve(STOCK_ROUTER, sGot / 3);
        uint256 sEth = srouter.sell(stockTok, sGot / 3, 0, me, block.timestamp + 3600);
        uint256 sFees = srouter.distribute(stockTok);
        console2.log("4) STOCK   token (COIN-paired, direct):", stockTok);
        console2.log("   bought / sold-third ETH out:", sGot, sEth);
        console2.log("   fees distributed (WETH):    ", sFees);

        vm.stopBroadcast();
    }
}
