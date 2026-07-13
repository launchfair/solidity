// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {TokenDeployerV2} from "../../src/v2/TokenDeployerV2.sol";
import {LaunchFairV4} from "../../src/v2/v4/LaunchFairV4.sol";
import {LaunchFairV4FeeLocker} from "../../src/v2/v4/LaunchFairV4FeeLocker.sol";
import {LaunchFairV4Distributor} from "../../src/v2/v4/LaunchFairV4Distributor.sol";
import {MockVRFCoordinator} from "./MockVRF.sol";
import {IV3SwapRouter, IUniswapV3Factory} from "../../src/interfaces/IUniswapV3.sol";

contract MockWethT is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice Minimal V3 factory stand-in: records which (tokenA, tokenB, fee) pools
/// "exist" so the launchpad's reward-pool validation can pass.
contract MockV3FactoryT {
    mapping(bytes32 => address) internal _pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        _pools[_k(a, b, fee)] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return _pools[_k(a, b, fee)];
    }

    function _k(address a, address b, uint24 fee) internal pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(x, y, fee));
    }
}

/// @notice Minimal SwapRouter02 stand-in: pulls WETH and mints 2x the reward token
/// (a mintable MockWethT) to the recipient.
contract MockV3RouterT {
    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p) external returns (uint256 out) {
        MockWethT(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * 2;
        require(out >= p.amountOutMinimum, "slip");
        MockWethT(p.tokenOut).mint(p.recipient, out);
    }
}

/// @notice Capstone: launch a Redistribute token through LaunchFairV4, trade to
/// generate fees, claim, process, and confirm a holder is auto-rewarded — the
/// whole V4 pipeline behind one entry point.
contract LaunchFairV4Test is Test, Deployers {
    MockWethT weth;
    MockV3FactoryT v3factory;
    MockV3RouterT v3router;
    TokenDeployerV2 tokenDeployer;
    LaunchFairV4FeeLocker locker;
    LaunchFairV4Distributor dist;
    MockVRFCoordinator vrf;
    LaunchFairV4 pad;

    address constant TREASURY = address(0x7EA);
    address constant HOLDER = address(0xB0B);
    uint128 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockWethT();
        v3factory = new MockV3FactoryT();
        v3router = new MockV3RouterT();

        tokenDeployer = new TokenDeployerV2();
        locker = new LaunchFairV4FeeLocker(address(this), manager, IERC20(address(weth)), TREASURY);
        // registrar placeholder = this; repointed to the launchpad below.
        dist = new LaunchFairV4Distributor(
            address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this)
        );
        pad = new LaunchFairV4(
            address(this), manager, IUniswapV3Factory(address(v3factory)), locker, address(dist), tokenDeployer,
            address(weth), SUPPLY, 1491146318, int24(200), int24(-203200), int24(-143400), 0, 0, "https://hood.launchfair.app"
        );

        vrf = new MockVRFCoordinator();
        locker.setLaunchpad(address(pad));
        locker.setDistributor(address(dist));
        dist.setLocker(address(locker));
        dist.setRegistrar(address(pad));
        dist.setVrf(address(vrf));

        vm.deal(address(this), 1 ether);
    }

    function _createRedistribute() internal returns (address token, PoolKey memory key) {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Red",
                symbol: "RED",
                metadata: meta,
                salt: bytes32(0),
                mode: LaunchTokenV2.Mode.Increasing, // Redistribute
                fee: 30_000,
                rewards: _noRewards(),
                prizeToken: address(0),
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );
        key = pad.getLaunch(token).key;
    }

    // Sorted holder set for settleDraw when the test contract is the sole ticket-holder.
    function _self() internal view returns (address[] memory h) {
        h = new address[](1);
        h[0] = address(this);
    }

    // No external reward assets (Redistribute / WETH-pot Lottery).
    function _noRewards() internal pure returns (LaunchFairV4.RewardVenue[] memory r) {
        r = new LaunchFairV4.RewardVenue[](0);
    }

    // A single reward asset taking the full fee weight, on a V3 (or V4) venue.
    function _oneReward(address asset, bool isV3, uint24 v3Fee)
        internal
        pure
        returns (LaunchFairV4.RewardVenue[] memory r)
    {
        PoolKey memory none;
        r = new LaunchFairV4.RewardVenue[](1);
        r[0] = LaunchFairV4.RewardVenue({token: asset, weightBps: 10_000, isV3: isV3, v3Fee: v3Fee, v4Key: none});
    }

    // minOuts array of `n` zeros (no slippage floor) for process().
    function _zeros(uint256 n) internal pure returns (uint256[] memory m) {
        m = new uint256[](n);
    }

    function _buy(PoolKey memory key, address token, uint256 wethIn) internal {
        weth.mint(address(this), wethIn);
        weth.approve(address(swapRouter), wethIn);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(weth);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(wethIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_endToEnd_launch_trade_claim_process_reward() public {
        (address token, PoolKey memory key) = _createRedistribute();

        // Pool exists + liquidity locked (the locker holds the position).
        assertTrue(pad.getLaunch(token).exists, "launched");
        assertEq(pad.creatorOf(token), address(this), "creator recorded");

        // A buyer becomes a holder (buys token, receives it here) + generates WETH fee.
        _buy(key, token, 0.1 ether);
        // Move the freshly-bought tokens to HOLDER so there's a real dividend holder.
        uint256 bought = IERC20(token).balanceOf(address(this));
        assertGt(bought, 0, "bought token");
        IERC20(token).transfer(HOLDER, bought);
        assertEq(LaunchTokenV2(token).totalShares(), bought, "HOLDER is the holder");

        // Claim the buy-side WETH fee -> split -> mechanism to the distributor.
        locker.claim(token);
        uint256 pending = dist.pendingWeth(token);
        assertGt(pending, 0, "mechanism WETH pending");

        // Process -> buy back the token -> auto-compound into HOLDER's balance.
        // Redistribute is auto-compounding: the balance grows on the buyback itself,
        // no claim and no push.
        uint256 beforeProcess = IERC20(token).balanceOf(HOLDER);
        dist.process(token, _zeros(1)); // Redistribute has one reward asset (the token itself)
        assertGt(IERC20(token).balanceOf(HOLDER), beforeProcess, "balance auto-grew on the buyback");
        assertGt(LaunchTokenV2(token).totalWithdrawableOf(HOLDER), 0, "reflection accrued");

        // A manual realize only folds the reflection into the raw balance — the
        // displayed balanceOf is unchanged (it already reflected the growth).
        uint256 grown = IERC20(token).balanceOf(HOLDER);
        address[] memory who = new address[](1);
        who[0] = HOLDER;
        LaunchTokenV2(token).processAccounts(who);
        assertApproxEqAbs(IERC20(token).balanceOf(HOLDER), grown, 100, "realize doesn't change balanceOf");
        assertEq(LaunchTokenV2(token).totalWithdrawableOf(HOLDER), 0, "reflection realized");
    }

    // A Reward token whose reward asset trades on Uniswap V3 (not an exclusive V4
    // pool): the dev picks it, the launchpad validates the V3 pool exists and wires
    // a V3 buyback, and process() routes the swap through SwapRouter02.
    function test_endToEnd_reward_v3RewardToken() public {
        MockWethT reward = new MockWethT();
        v3factory.setPool(address(weth), address(reward), 10_000, address(0xBEEF)); // pool exists

        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "RewV3",
                symbol: "RV3",
                metadata: meta,
                salt: bytes32(uint256(2)),
                mode: LaunchTokenV2.Mode.Reward,
                fee: 30_000,
                rewards: _oneReward(address(reward), true, 10_000),
                prizeToken: address(0),
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );
        assertEq(dist.buybackVenue(token, address(reward)), 1, "wired to a V3 buyback");

        PoolKey memory key = pad.getLaunch(token).key;
        _buy(key, token, 0.1 ether);
        IERC20(token).transfer(HOLDER, IERC20(token).balanceOf(address(this)));

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "mechanism WETH pending");

        dist.process(token, _zeros(1));
        assertGt(LaunchTokenV2(token).withdrawableDividendOf(address(reward), HOLDER), 0, "HOLDER accrued the reward");

        vm.prank(HOLDER);
        LaunchTokenV2(token).claim();
        assertGt(reward.balanceOf(HOLDER), 0, "HOLDER received the V3-bought reward token");
    }

    // Multi-reward: two dev-chosen reward assets distributed in parallel, each with
    // its own fee weight (60/40) + V3 venue. process() splits the fee batch by weight
    // and buys both assets in a single call; holders accrue in each asset separately.
    function test_endToEnd_reward_multiAsset_parallel() public {
        MockWethT rewardA = new MockWethT();
        MockWethT rewardB = new MockWethT();
        v3factory.setPool(address(weth), address(rewardA), 10_000, address(0xBEE1));
        v3factory.setPool(address(weth), address(rewardB), 10_000, address(0xBEE2));

        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](2);
        rewards[0] =
            LaunchFairV4.RewardVenue({token: address(rewardA), weightBps: 6_000, isV3: true, v3Fee: 10_000, v4Key: none});
        rewards[1] =
            LaunchFairV4.RewardVenue({token: address(rewardB), weightBps: 4_000, isV3: true, v3Fee: 10_000, v4Key: none});

        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Multi",
                symbol: "MULTI",
                metadata: meta,
                salt: bytes32(uint256(5)),
                mode: LaunchTokenV2.Mode.Reward,
                fee: 30_000,
                rewards: rewards,
                prizeToken: address(0),
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );

        // Both assets registered as reward buckets, in order, with their weights + venues.
        address[] memory list = LaunchTokenV2(token).rewardTokensList();
        assertEq(list.length, 2, "two reward assets");
        assertEq(list[0], address(rewardA), "asset0 = A");
        assertEq(list[1], address(rewardB), "asset1 = B");
        assertEq(LaunchTokenV2(token).rewardWeightBps(address(rewardA)), 6_000, "A weight 60%");
        assertEq(LaunchTokenV2(token).rewardWeightBps(address(rewardB)), 4_000, "B weight 40%");
        assertEq(dist.buybackVenue(token, address(rewardA)), 1, "A on V3");
        assertEq(dist.buybackVenue(token, address(rewardB)), 1, "B on V3");

        PoolKey memory key = pad.getLaunch(token).key;
        _buy(key, token, 0.1 ether);
        IERC20(token).transfer(HOLDER, IERC20(token).balanceOf(address(this)));

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "fee pending");

        dist.process(token, _zeros(2)); // buys both assets in one call

        uint256 wdA = LaunchTokenV2(token).withdrawableDividendOf(address(rewardA), HOLDER);
        uint256 wdB = LaunchTokenV2(token).withdrawableDividendOf(address(rewardB), HOLDER);
        assertGt(wdA, 0, "accrued asset A");
        assertGt(wdB, 0, "accrued asset B");
        // Split follows the weights: A = 60%, B = 40% -> wdA/wdB == 60/40 == 1.5.
        assertApproxEqRel(wdA * 4_000, wdB * 6_000, 1e15, "60/40 fee split honored");

        // Claiming pays out every reward asset in one call.
        vm.prank(HOLDER);
        LaunchTokenV2(token).claim();
        assertGt(rewardA.balanceOf(HOLDER), 0, "HOLDER got asset A");
        assertGt(rewardB.balanceOf(HOLDER), 0, "HOLDER got asset B");
    }

    // Reward weights must sum to exactly 10000.
    function test_reward_rejectsBadWeights() public {
        MockWethT a = new MockWethT();
        MockWethT b = new MockWethT();
        v3factory.setPool(address(weth), address(a), 10_000, address(0xBEE1));
        v3factory.setPool(address(weth), address(b), 10_000, address(0xBEE2));
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](2);
        rewards[0] = LaunchFairV4.RewardVenue({token: address(a), weightBps: 6_000, isV3: true, v3Fee: 10_000, v4Key: none});
        rewards[1] = LaunchFairV4.RewardVenue({token: address(b), weightBps: 3_000, isV3: true, v3Fee: 10_000, v4Key: none}); // 9000
        vm.expectRevert(LaunchFairV4.BadRewardConfig.selector);
        pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Bad", symbol: "BAD", metadata: meta, salt: bytes32(uint256(6)),
                mode: LaunchTokenV2.Mode.Reward, fee: 30_000, rewards: rewards,
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
                minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );
    }

    // A duplicate reward asset is rejected (one dividend bucket per asset).
    function test_reward_rejectsDuplicateAsset() public {
        MockWethT a = new MockWethT();
        v3factory.setPool(address(weth), address(a), 10_000, address(0xBEE1));
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](2);
        rewards[0] = LaunchFairV4.RewardVenue({token: address(a), weightBps: 5_000, isV3: true, v3Fee: 10_000, v4Key: none});
        rewards[1] = LaunchFairV4.RewardVenue({token: address(a), weightBps: 5_000, isV3: true, v3Fee: 10_000, v4Key: none});
        vm.expectRevert(LaunchFairV4.BadRewardConfig.selector);
        pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Dup", symbol: "DUP", metadata: meta, salt: bytes32(uint256(7)),
                mode: LaunchTokenV2.Mode.Reward, fee: 30_000, rewards: rewards,
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
                minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );
    }

    // More than MAX_REWARDS (5) assets is rejected.
    function test_reward_rejectsTooMany() public {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](6);
        for (uint256 i; i < 6; i++) {
            MockWethT a = new MockWethT();
            v3factory.setPool(address(weth), address(a), 10_000, address(uint160(0xBE00 + i)));
            rewards[i] =
                LaunchFairV4.RewardVenue({token: address(a), weightBps: 2_000, isV3: true, v3Fee: 10_000, v4Key: none});
        }
        vm.expectRevert(LaunchFairV4.BadRewardConfig.selector);
        pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Six", symbol: "SIX", metadata: meta, salt: bytes32(uint256(8)),
                mode: LaunchTokenV2.Mode.Reward, fee: 30_000, rewards: rewards,
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
                minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );
    }

    // A V3 reward whose pool doesn't exist is rejected at creation (no un-routable
    // buyback can be locked in).
    function test_reward_v3_rejectsMissingPool() public {
        MockWethT reward = new MockWethT(); // factory has no pool registered for it
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        vm.expectRevert(LaunchFairV4.InvalidRewardPool.selector);
        pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Bad",
                symbol: "BAD",
                metadata: meta,
                salt: bytes32(uint256(3)),
                mode: LaunchTokenV2.Mode.Reward,
                fee: 30_000,
                rewards: _oneReward(address(reward), true, 10_000),
                prizeToken: address(0),
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );
    }

    function _createLottery() internal returns (address token, PoolKey memory key) {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Lotto",
                symbol: "LOTTO",
                metadata: meta,
                salt: bytes32(uint256(1)),
                mode: LaunchTokenV2.Mode.Lottery,
                fee: 100_000, // 10% fee -> a beefy pot
                rewards: _noRewards(),
                prizeToken: address(0), // WETH pot
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );
        key = pad.getLaunch(token).key;
    }

    // Full lottery pipeline through the launchpad: launch -> buy (earns tickets)
    // -> claim (funds the pot) -> commit to a future drand round -> settle (pays
    // the verifiable winner + records the draw).
    function test_endToEnd_lottery_launch_buy_draw() public {
        (address token, PoolKey memory key) = _createLottery();
        dist.setDrawOperator(address(this)); // this session acts as the keeper

        // Launchpad wired the lottery: distributor is the draw operator.
        assertEq(LaunchTokenV2(token).lotteryOperator(), address(dist), "distributor is operator");

        // Holdings are tickets: buying gives this buyer a balance -> proportional tickets.
        _buy(key, token, 0.1 ether);
        uint256 epoch = LaunchTokenV2(token).lotteryEpoch();
        uint256 myTickets = LaunchTokenV2(token).balanceOf(address(this));
        assertGt(myTickets, 0, "holdings earn tickets");
        assertEq(LaunchTokenV2(token).totalEligibleSupply(), myTickets, "sole eligible holder");

        // Claim the buy-side fee -> mechanism WETH becomes the pot.
        locker.claim(token);
        uint256 pot = dist.pendingWeth(token);
        assertGt(pot, 0, "pot funded");

        // Commit snapshots holdings at this block. The pot is NOT reserved (it rolls) and
        // the cycle advances only when a draw actually wins.
        uint256 round = 9_999_999;
        dist.commitDraw(token, round);
        assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch, "session unchanged at commit");
        assertEq(dist.pendingWeth(token), pot, "pot live at commit (not reserved)");
        (,,, uint256 snapBlk,,,) = dist.pendingDraw(token);

        // …the keeper posts the beacon to the coordinator (which pushes it to the
        // distributor), then settles — the randomness comes from the coordinator.
        bytes32 rnd = keccak256("drand-beacon");
        uint256 wt = uint256(keccak256(abi.encode(rnd, token, round))) % LaunchTokenV2(token).totalEligibleAt(snapBlk);
        assertLt(wt, myTickets, "winning ticket falls in our range");
        vrf.deliver(round, rnd);

        uint256 balBefore = weth.balanceOf(address(this));
        dist.settleDraw(token, _self(), 0);

        assertEq(weth.balanceOf(address(this)) - balBefore, pot, "winner paid the whole pot");
        assertEq(dist.drawCount(token), 1, "draw recorded in history");
        assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch + 1, "cycle advances on the winning draw");
    }

    // A lottery whose prize is a dev-chosen token that trades on V3: the launchpad
    // wires the prize's V3 buyback venue, and at settle the pot is swapped to the
    // prize token and paid to the winner.
    function test_endToEnd_lottery_v3PrizeToken() public {
        MockWethT prize = new MockWethT();
        v3factory.setPool(address(weth), address(prize), 10_000, address(0xBEEF));

        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "LottoTok",
                symbol: "LTK",
                metadata: meta,
                salt: bytes32(uint256(4)),
                mode: LaunchTokenV2.Mode.Lottery,
                fee: 100_000,
                rewards: _noRewards(),
                prizeToken: address(prize), // token prize (not WETH)
                prizeIsV3: true,
                prizeV3Fee: 10_000,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, jackpotChanceBps: 10000
            })
        );
        assertEq(dist.buybackVenue(token, address(prize)), 1, "prize bought on V3");
        assertEq(LaunchTokenV2(token).prizeToken(), address(prize), "prize token recorded");

        PoolKey memory key = pad.getLaunch(token).key;
        dist.setDrawOperator(address(this));
        _buy(key, token, 0.1 ether); // this session earns all tickets
        uint256 epoch = LaunchTokenV2(token).lotteryEpoch();

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "pot funded");

        dist.commitDraw(token, 42);
        vrf.deliver(42, keccak256("beacon"));
        dist.settleDraw(token, _self(), 0);

        assertGt(prize.balanceOf(address(this)), 0, "winner paid in the V3 prize token");
        assertEq(dist.drawCount(token), 1, "draw recorded");
        assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch + 1, "session advanced");
    }
}
