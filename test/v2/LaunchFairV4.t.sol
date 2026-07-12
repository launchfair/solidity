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
import {LaunchFairVRFCoordinator} from "../../src/v2/v4/LaunchFairVRFCoordinator.sol";
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
    LaunchFairVRFCoordinator vrf;
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
            address(weth), SUPPLY, 1e18, int24(200), int24(200), int24(60_000), 0, 0, "https://hood.launchfair.app"
        );

        vrf = new LaunchFairVRFCoordinator(address(this), address(this)); // owner + poster = this
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
                rewardToken: address(0),
                rewardIsV3: false,
                rewardV3Fee: 0,
                rewardPoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0
            })
        );
        key = pad.getLaunch(token).key;
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
        _buy(key, token, 50_000 ether);
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
        uint256 out = dist.process(token, 0);
        assertGt(out, 0, "bought back for rewards");
        assertGt(IERC20(token).balanceOf(HOLDER), beforeProcess, "balance auto-grew on the buyback");
        assertGt(LaunchTokenV2(token).withdrawableDividendOf(HOLDER), 0, "reflection accrued");

        // A manual realize only folds the reflection into the raw balance — the
        // displayed balanceOf is unchanged (it already reflected the growth).
        uint256 grown = IERC20(token).balanceOf(HOLDER);
        address[] memory who = new address[](1);
        who[0] = HOLDER;
        LaunchTokenV2(token).processAccounts(who);
        assertApproxEqAbs(IERC20(token).balanceOf(HOLDER), grown, 100, "realize doesn't change balanceOf");
        assertEq(LaunchTokenV2(token).withdrawableDividendOf(HOLDER), 0, "reflection realized");
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
                rewardToken: address(reward),
                rewardIsV3: true,
                rewardV3Fee: 10_000,
                rewardPoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0
            })
        );
        assertEq(dist.buybackVenue(token), 1, "wired to a V3 buyback");

        PoolKey memory key = pad.getLaunch(token).key;
        _buy(key, token, 50_000 ether);
        IERC20(token).transfer(HOLDER, IERC20(token).balanceOf(address(this)));

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "mechanism WETH pending");

        uint256 out = dist.process(token, 0);
        assertGt(out, 0, "reward bought via V3 router");
        assertGt(LaunchTokenV2(token).withdrawableDividendOf(HOLDER), 0, "HOLDER accrued the reward");

        vm.prank(HOLDER);
        LaunchTokenV2(token).claim();
        assertGt(reward.balanceOf(HOLDER), 0, "HOLDER received the V3-bought reward token");
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
                rewardToken: address(reward),
                rewardIsV3: true,
                rewardV3Fee: 10_000,
                rewardPoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0
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
                rewardToken: address(0), // WETH prize
                rewardIsV3: false,
                rewardV3Fee: 0,
                rewardPoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0
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

        // Launchpad wired the lottery: buys tracked from the pool, distributor draws.
        assertEq(LaunchTokenV2(token).buySource(), address(manager), "buys tracked from pool");
        assertEq(LaunchTokenV2(token).lotteryOperator(), address(dist), "distributor is operator");

        // A buy hands tokens straight from the pool to the buyer -> tickets accrue.
        _buy(key, token, 50_000 ether);
        uint256 epoch = LaunchTokenV2(token).lotteryEpoch();
        uint256 myTickets = LaunchTokenV2(token).ticketsOf(epoch, address(this));
        assertGt(myTickets, 0, "buy earned tickets");
        assertEq(LaunchTokenV2(token).totalTickets(epoch), myTickets, "sole ticket holder");

        // Claim the buy-side fee -> mechanism WETH becomes the pot.
        locker.claim(token);
        uint256 pot = dist.pendingWeth(token);
        assertGt(pot, 0, "pot funded");

        // Commit closes ticket sales (advances the session, reserves the pot)…
        uint256 round = 9_999_999;
        dist.commitDraw(token, round);
        assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch + 1, "session advanced at commit");

        // …the keeper posts the beacon to the coordinator (which pushes it to the
        // distributor), then settles — the randomness comes from the coordinator.
        bytes32 rnd = keccak256("drand-beacon");
        uint256 wt = uint256(keccak256(abi.encode(rnd, token, round))) % LaunchTokenV2(token).totalTickets(epoch);
        assertLt(wt, myTickets, "winning ticket falls in our range");
        vrf.postRandomness(round, rnd);

        uint256 balBefore = weth.balanceOf(address(this));
        dist.settleDraw(token, address(this), 0, 0);

        assertEq(weth.balanceOf(address(this)) - balBefore, pot, "winner paid the whole pot");
        assertEq(dist.drawCount(token), 1, "draw recorded in history");
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
                rewardToken: address(prize), // token prize (not WETH)
                rewardIsV3: true,
                rewardV3Fee: 10_000,
                rewardPoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0
            })
        );
        assertEq(dist.buybackVenue(token), 1, "prize bought on V3");
        assertEq(LaunchTokenV2(token).rewardToken(), address(prize), "prize token recorded");

        PoolKey memory key = pad.getLaunch(token).key;
        dist.setDrawOperator(address(this));
        _buy(key, token, 50_000 ether); // this session earns all tickets
        uint256 epoch = LaunchTokenV2(token).lotteryEpoch();

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "pot funded");

        dist.commitDraw(token, 42);
        vrf.postRandomness(42, keccak256("beacon"));
        dist.settleDraw(token, address(this), 0, 0);

        assertGt(prize.balanceOf(address(this)), 0, "winner paid in the V3 prize token");
        assertEq(dist.drawCount(token), 1, "draw recorded");
        assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch + 1, "session advanced");
    }
}
