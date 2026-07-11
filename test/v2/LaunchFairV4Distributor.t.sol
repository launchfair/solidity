// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {LaunchFairV4Distributor} from "../../src/v2/v4/LaunchFairV4Distributor.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice End-to-end V4 test of the reward/redistribute/burn buyback: a real
/// PoolManager + token/WETH pool with liquidity, funded WETH -> process() ->
/// swap -> fund/burn. The test contract acts as launchpad (holds supply) + locker.
contract V4DistributorTest is Test, Deployers {
    LaunchFairV4Distributor dist;
    MockToken weth;
    address constant A = address(0xA1);
    address constant B = address(0xB2);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function _deployToken(LaunchTokenV2.Mode mode, address rewardToken, address rewardPool)
        internal
        returns (LaunchTokenV2 t)
    {
        LaunchTokenV2.Metadata memory meta;
        t = new LaunchTokenV2(
            "Tok", "TOK", SUPPLY, "https://hood.launchfair.app", meta, 0, 0, mode, rewardToken, rewardPool, 0, address(this)
        );
    }

    function _pool(address token) internal view returns (PoolKey memory key) {
        (Currency c0, Currency c1) = address(token) < address(weth)
            ? (Currency.wrap(address(token)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(token)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 30_000, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    // Create the token/WETH pool at 1:1, add deep two-sided liquidity, and wire
    // the distributor. Returns the pool key.
    function _setupPoolAndDistributor(LaunchTokenV2 token) internal returns (PoolKey memory key) {
        key = _pool(address(token));
        manager.initialize(key, SQRT_PRICE_1_1);

        weth.mint(address(this), 10_000_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        dist = new LaunchFairV4Distributor(address(this), manager, IERC20(address(weth)), address(this));
        dist.setLocker(address(this));
        dist.registerBuyback(address(token), key);

        // Exclude V4 plumbing so only real holders accrue.
        token.excludeFromDividends(address(manager), true);
        token.excludeFromDividends(address(modifyLiquidityRouter), true);
        token.excludeFromDividends(address(swapRouter), true);
        token.excludeFromDividends(address(dist), true);
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockToken("WETH", "WETH");
    }

    function test_redistribute_buysBackAndDistributes() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Increasing, address(0), address(0));
        _setupPoolAndDistributor(token);
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);
        assertEq(token.totalShares(), 400_000 ether);

        uint256 wethIn = 10 ether;
        weth.mint(address(dist), wethIn);
        dist.notify(address(token), wethIn);

        uint256 out = dist.process(address(token), 0);
        assertGt(out, 0, "bought back token");
        assertEq(token.totalDistributed(), out, "distributed == bought back");

        uint256 wa = token.withdrawableDividendOf(A);
        uint256 wb = token.withdrawableDividendOf(B);
        assertGt(wa, 0, "A accrued");
        assertApproxEqRel(wa, wb * 3, 0.01e18, "A ~3x B");
        assertApproxEqAbs(wa + wb, out, 1000, "all distributed to holders");
    }

    function test_reward_buysExternalTokenAndDistributes() public {
        MockToken reward = new MockToken("Reward", "RWD");
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Reward, address(reward), address(0));

        // reward/WETH V4 pool with liquidity (where the buyback happens).
        PoolKey memory rkey = _pool(address(reward));
        manager.initialize(rkey, SQRT_PRICE_1_1);
        reward.mint(address(this), 1_000_000 ether);
        weth.mint(address(this), 10_000_000 ether);
        reward.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            rkey,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        dist = new LaunchFairV4Distributor(address(this), manager, IERC20(address(weth)), address(this));
        dist.setLocker(address(this));
        dist.registerBuyback(address(token), rkey); // buy the REWARD token here

        token.excludeFromDividends(address(manager), true);
        token.excludeFromDividends(address(modifyLiquidityRouter), true);
        token.excludeFromDividends(address(dist), true);
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);

        uint256 wethIn = 10 ether;
        weth.mint(address(dist), wethIn);
        dist.notify(address(token), wethIn);
        uint256 out = dist.process(address(token), 0);
        assertGt(out, 0, "bought reward token");

        // Holders accrue the REWARD token pro-rata; claim delivers it.
        assertApproxEqRel(token.withdrawableDividendOf(A), token.withdrawableDividendOf(B) * 3, 0.01e18, "A ~3x B");
        vm.prank(A);
        token.claim();
        assertGt(reward.balanceOf(A), 0, "A received the reward token");
        assertEq(reward.balanceOf(address(token)), out - reward.balanceOf(A), "rest still claimable in token");
    }

    function test_burn_buysBackAndBurns() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Burn, address(0), address(0));
        _setupPoolAndDistributor(token);
        token.transfer(A, 300_000 ether);

        uint256 supplyBefore = token.totalSupply();
        uint256 wethIn = 10 ether;
        weth.mint(address(dist), wethIn);
        dist.notify(address(token), wethIn);

        uint256 out = dist.process(address(token), 0);
        assertGt(out, 0, "bought back token");
        assertEq(token.totalBurned(), out, "burned == bought back");
        assertEq(token.totalSupply(), supplyBefore - out, "supply reduced");
    }

    function test_payoutThreshold_gatesProcess() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Burn, address(0), address(0));
        _setupPoolAndDistributor(token);
        dist.setPayoutThreshold(address(token), 5 ether); // registrar (this) sets it

        // Below threshold → not ready, process reverts.
        weth.mint(address(dist), 3 ether);
        dist.notify(address(token), 3 ether);
        assertFalse(dist.readyToProcess(address(token)), "below threshold");
        vm.expectRevert(LaunchFairV4Distributor.BelowThreshold.selector);
        dist.process(address(token), 0);

        // Cross the threshold → ready, process fires.
        weth.mint(address(dist), 3 ether);
        dist.notify(address(token), 3 ether); // 6 >= 5
        assertTrue(dist.readyToProcess(address(token)), "threshold crossed");
        assertGt(dist.process(address(token), 0), 0, "payout fired");
    }

    // ── lottery (Mode.Lottery) ──────────────────────────────────────────────────
    // Wire a Lottery token: distributor is its epoch operator + the draw keeper.
    // "Buys" are transfers from buySource (this) so holders earn tickets ∝ amount.
    function _setupLottery() internal returns (LaunchTokenV2 token) {
        token = _deployToken(LaunchTokenV2.Mode.Lottery, address(0), address(0));
        dist = new LaunchFairV4Distributor(address(this), manager, IERC20(address(weth)), address(this));
        dist.setLocker(address(this));      // this feeds the pot via notify
        dist.setDrawOperator(address(this)); // this is the keeper (commits/settles)
        token.setBuySource(address(this));   // "buys" originate here → earn tickets
        token.setLotteryOperator(address(dist)); // distributor advances the session
    }

    // Canonical ticket order = the order holders first appear: A gets [0, aTix),
    // then B gets [aTix, aTix+bTix). Given a winning ticket, resolve (winner,start).
    function _resolveWinner(LaunchTokenV2 token, uint256 winningTicket)
        internal
        view
        returns (address winner, uint256 start)
    {
        uint256 aTix = token.ticketsOf(token.lotteryEpoch(), A);
        return winningTicket < aTix ? (A, uint256(0)) : (B, aTix);
    }

    function test_lottery_drawPaysVerifiableWinner() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 300_000 ether); // A: tickets [0, 300_000e18)
        token.transfer(B, 100_000 ether); // B: tickets [300_000e18, 400_000e18)
        uint256 total = token.totalTickets(0);
        assertEq(total, 400_000 ether, "ticket pool == bought amount");

        uint256 pot = 10 ether;
        weth.mint(address(dist), pot);
        dist.notify(address(token), pot);

        uint256 round = 4_000_123; // a future drand round (committed before it exists)
        dist.commitDraw(address(token), round);

        // The keeper fetches the drand beacon for `round` and derives the winner the
        // same way the contract does — anyone can recompute this from on-chain data.
        bytes32 rnd = keccak256("drand-beacon-value-for-round");
        uint256 winningTicket = uint256(keccak256(abi.encode(rnd, address(token), round))) % total;
        (address winner, uint256 start) = _resolveWinner(token, winningTicket);

        uint256 balBefore = weth.balanceOf(winner);
        dist.settleDraw(address(token), rnd, winner, start);

        assertEq(weth.balanceOf(winner) - balBefore, pot, "winner paid the whole pot");
        assertEq(dist.pendingWeth(address(token)), 0, "pot cleared");
        assertEq(token.lotteryEpoch(), 1, "session advanced; old tickets no longer count");
        assertEq(dist.drawCount(address(token)), 1, "draw recorded in history");

        (
            uint256 epoch,
            uint256 rRound,
            bytes32 storedRnd,
            address wWinner,
            uint256 prize,
            uint256 tot,
            uint256 wt,
        ) = dist.draws(address(token), 0);
        assertEq(epoch, 0, "drawn from epoch 0");
        assertEq(rRound, round, "committed round stored");
        assertEq(storedRnd, rnd, "randomness stored for re-verification");
        assertEq(wWinner, winner, "winner stored");
        assertEq(prize, pot, "prize stored");
        assertEq(tot, total, "total tickets stored");
        assertEq(wt, winningTicket, "winning ticket derived on-chain matches");
    }

    function test_lottery_badProofReverts() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);
        weth.mint(address(dist), 5 ether);
        dist.notify(address(token), 5 ether);
        dist.commitDraw(address(token), 1);

        bytes32 rnd = keccak256("x");
        uint256 wt = uint256(keccak256(abi.encode(rnd, address(token), uint256(1)))) % token.totalTickets(0);
        (address winner,) = _resolveWinner(token, wt);
        // Lie about the winner's offset → the drawn ticket falls outside their range.
        uint256 wrongStart = winner == A ? uint256(300_000 ether) : uint256(0);
        vm.expectRevert(LaunchFairV4Distributor.BadProof.selector);
        dist.settleDraw(address(token), rnd, winner, wrongStart);
    }

    function test_lottery_wrongWinnerReverts() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 400_000 ether); // A owns EVERY ticket
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        dist.commitDraw(address(token), 7);
        // B has zero tickets → can never be a valid winner.
        vm.expectRevert(LaunchFairV4Distributor.BadProof.selector);
        dist.settleDraw(address(token), keccak256("y"), B, 0);
    }

    function test_lottery_noTicketsReverts() public {
        LaunchTokenV2 token = _setupLottery(); // nobody bought → no tickets
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        dist.commitDraw(address(token), 9);
        vm.expectRevert(LaunchFairV4Distributor.NoTickets.selector);
        dist.settleDraw(address(token), keccak256("z"), A, 0);
    }

    function test_lottery_onlyOperator() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        vm.prank(A);
        vm.expectRevert(LaunchFairV4Distributor.OnlyDrawOperator.selector);
        dist.commitDraw(address(token), 1);

        dist.commitDraw(address(token), 1);
        vm.prank(A);
        vm.expectRevert(LaunchFairV4Distributor.OnlyDrawOperator.selector);
        dist.settleDraw(address(token), keccak256("q"), A, 0);
    }

    function test_lottery_doubleCommitReverts() public {
        LaunchTokenV2 token = _setupLottery();
        dist.commitDraw(address(token), 1);
        vm.expectRevert(LaunchFairV4Distributor.DrawActive.selector);
        dist.commitDraw(address(token), 2);
    }

    function test_lottery_settleWithoutCommitReverts() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        vm.expectRevert(LaunchFairV4Distributor.NoDraw.selector);
        dist.settleDraw(address(token), keccak256("q"), A, 0);
    }

    function test_lottery_commitRejectsNonLottery() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Burn, address(0), address(0));
        dist = new LaunchFairV4Distributor(address(this), manager, IERC20(address(weth)), address(this));
        dist.setDrawOperator(address(this));
        vm.expectRevert(LaunchFairV4Distributor.NotLottery.selector);
        dist.commitDraw(address(token), 1);
    }

    function test_lottery_processRevertsForLottery() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        dist.registerBuyback(address(token), _pool(address(token))); // even if registered…
        vm.expectRevert(LaunchFairV4Distributor.WrongMode.selector); // …process is not the lottery path
        dist.process(address(token), 0);
    }

    // A second session only counts buys made after the previous draw settled.
    function test_lottery_nextSessionIsFresh() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);
        weth.mint(address(dist), 4 ether);
        dist.notify(address(token), 4 ether);
        dist.commitDraw(address(token), 1);
        uint256 wt = uint256(keccak256(abi.encode(keccak256("r1"), address(token), uint256(1)))) % token.totalTickets(0);
        (address w1, uint256 s1) = _resolveWinner(token, wt);
        dist.settleDraw(address(token), keccak256("r1"), w1, s1);

        // Epoch 1: only A buys again. Old (epoch 0) tickets are gone.
        assertEq(token.lotteryEpoch(), 1);
        assertEq(token.totalTickets(1), 0, "fresh session starts empty");
        token.transfer(A, 50_000 ether);
        assertEq(token.totalTickets(1), 50_000 ether, "only new buys count");

        weth.mint(address(dist), 2 ether);
        dist.notify(address(token), 2 ether);
        dist.commitDraw(address(token), 2);
        uint256 balBefore = weth.balanceOf(A);
        // A owns the whole epoch-1 pool → A wins regardless of randomness.
        dist.settleDraw(address(token), keccak256("r2"), A, 0);
        assertEq(weth.balanceOf(A) - balBefore, 2 ether, "epoch-1 winner paid");
        assertEq(dist.drawCount(address(token)), 2, "two draws in history");
    }
}
