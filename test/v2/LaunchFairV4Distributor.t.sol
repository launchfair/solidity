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
import {MockVRFCoordinator} from "./MockVRF.sol";
import {IV3SwapRouter} from "../../src/interfaces/IUniswapV3.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Stand-in for SwapRouter02: pulls WETH from the caller and mints a fixed
/// multiple of the reward token to the recipient — enough to exercise the
/// distributor's V3 buyback path (approve -> swap -> receive) without a real V3
/// pool. tokenOut must be a MockToken (mintable).
contract MockV3Router {
    uint256 public rate = 2; // reward out per WETH in

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p) external returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * rate;
        require(out >= p.amountOutMinimum, "slippage");
        MockToken(p.tokenOut).mint(p.recipient, out);
    }
}

/// @notice End-to-end V4 test of the reward/redistribute buyback: a real
/// PoolManager + token/WETH pool with liquidity, funded WETH -> process() ->
/// swap -> fund. The test contract acts as launchpad (holds supply) + locker.
contract V4DistributorTest is Test, Deployers {
    LaunchFairV4Distributor dist;
    MockVRFCoordinator vrf;
    MockToken weth;
    MockV3Router v3router;
    address constant A = address(0xA1);
    address constant B = address(0xB2);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function _deployToken(LaunchTokenV2.Mode mode, address rewardToken, address /*rewardPool*/)
        internal
        returns (LaunchTokenV2 t)
    {
        LaunchTokenV2.Metadata memory meta;
        // Multi-reward API: Reward passes [rewardToken] @ 100% weight; Lottery passes the
        // prize token (0 = WETH pot); Increasing/Base pass empty arrays (the constructor
        // auto-registers THIS token as the sole Increasing reward asset).
        address[] memory rewardTokens = new address[](0);
        uint16[] memory rewardWeights = new uint16[](0);
        address prizeToken = address(0);
        if (mode == LaunchTokenV2.Mode.Reward) {
            rewardTokens = _arr1(rewardToken);
            rewardWeights = _w1(10_000);
        } else if (mode == LaunchTokenV2.Mode.Lottery) {
            prizeToken = rewardToken; // 0 = WETH pot; otherwise a dev-chosen prize token
        }
        t = new LaunchTokenV2(
            "Tok", "TOK", SUPPLY, "https://hood.launchfair.app", meta, 0, 0, mode,
            rewardTokens, rewardWeights, prizeToken, 0, address(this)
        );
    }

    // ── multi-reward API array-literal helpers ───────────────────────────────────
    function _arr1(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    function _w1(uint16 w) internal pure returns (uint16[] memory x) {
        x = new uint16[](1);
        x[0] = w;
    }

    // A zero-filled minOuts array for process(); `n` == the token's reward-asset count.
    function _zeros(uint256 n) internal pure returns (uint256[] memory m) {
        m = new uint256[](n);
    }

    // A single-element minOuts array carrying `v`.
    function _u1(uint256 v) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = v;
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

        dist = new LaunchFairV4Distributor(address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this));
        dist.setLocker(address(this));
        // Increasing distributes THIS token back to holders → the reward asset is the token itself.
        dist.registerBuyback(address(token), address(token), key);

        // Exclude V4 plumbing so only real holders accrue.
        token.excludeFromDividends(address(manager), true);
        token.excludeFromDividends(address(modifyLiquidityRouter), true);
        token.excludeFromDividends(address(swapRouter), true);
        token.excludeFromDividends(address(dist), true);
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockToken("WETH", "WETH");
        v3router = new MockV3Router();
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

        // process() no longer returns the bought-back amount; for Redistribute the sole
        // reward asset is the token itself, so read it from the tracker.
        dist.process(address(token), _zeros(1));
        uint256 out = token.totalDistributedOf(address(token));
        assertGt(out, 0, "bought back token");
        assertEq(token.totalDistributedOf(address(token)), out, "distributed == bought back");

        uint256 wa = token.withdrawableDividendOf(address(token), A);
        uint256 wb = token.withdrawableDividendOf(address(token), B);
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

        dist = new LaunchFairV4Distributor(address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this));
        dist.setLocker(address(this));
        dist.registerBuyback(address(token), address(reward), rkey); // buy the REWARD token here

        token.excludeFromDividends(address(manager), true);
        token.excludeFromDividends(address(modifyLiquidityRouter), true);
        token.excludeFromDividends(address(dist), true);
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);

        uint256 wethIn = 10 ether;
        weth.mint(address(dist), wethIn);
        dist.notify(address(token), wethIn);
        dist.process(address(token), _zeros(1));
        uint256 out = token.totalDistributedOf(address(reward)); // reward bought & funded
        assertGt(out, 0, "bought reward token");

        // Holders accrue the REWARD token pro-rata; claim delivers it.
        assertApproxEqRel(token.withdrawableDividendOf(address(reward), A), token.withdrawableDividendOf(address(reward), B) * 3, 0.01e18, "A ~3x B");
        vm.prank(A);
        token.claim();
        assertGt(reward.balanceOf(A), 0, "A received the reward token");
        assertEq(reward.balanceOf(address(token)), out - reward.balanceOf(A), "rest still claimable in token");
    }

    // A Reward token whose reward asset lives on a Uniswap V3 pool: the buyback
    // routes through SwapRouter02 instead of the V4 PoolManager.
    function test_reward_v3_buysExternalTokenOnV3AndDistributes() public {
        MockToken reward = new MockToken("RewardV3", "RV3");
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Reward, address(reward), address(0));

        dist = new LaunchFairV4Distributor(address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this));
        dist.setLocker(address(this));
        dist.registerBuybackV3(address(token), address(reward), 10_000); // buy the reward on a V3 pool
        assertEq(dist.buybackVenue(address(token), address(reward)), 1, "venue = V3");

        token.excludeFromDividends(address(dist), true);
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);

        uint256 wethIn = 10 ether;
        weth.mint(address(dist), wethIn);
        dist.notify(address(token), wethIn);
        dist.process(address(token), _zeros(1));
        uint256 out = token.totalDistributedOf(address(reward)); // reward bought & funded

        assertEq(out, wethIn * v3router.rate(), "bought reward via the V3 router");
        assertEq(weth.balanceOf(address(dist)), 0, "all pending WETH swapped");
        assertApproxEqRel(token.withdrawableDividendOf(address(reward), A), token.withdrawableDividendOf(address(reward), B) * 3, 0.01e18, "A ~3x B");
        vm.prank(A);
        token.claim();
        assertGt(reward.balanceOf(A), 0, "A received the V3-bought reward token");
    }

    function test_reward_v3_slippageGuards() public {
        MockToken reward = new MockToken("RewardV3", "RV3");
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Reward, address(reward), address(0));
        dist = new LaunchFairV4Distributor(address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this));
        dist.setLocker(address(this));
        dist.registerBuybackV3(address(token), address(reward), 10_000);
        token.excludeFromDividends(address(dist), true);
        token.transfer(A, 100_000 ether);

        weth.mint(address(dist), 5 ether);
        dist.notify(address(token), 5 ether); // out would be 10 ether
        vm.expectRevert(LaunchFairV4Distributor.Slippage.selector);
        dist.process(address(token), _u1(100 ether)); // demand more than the swap yields
        assertEq(dist.pendingWeth(address(token)), 5 ether, "revert rolled back the pending debit");
    }

    function test_payoutThreshold_gatesProcess() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Increasing, address(0), address(0));
        _setupPoolAndDistributor(token);
        token.transfer(A, 300_000 ether); // a holder so the buyback has shares to fund
        dist.setPayoutThreshold(address(token), 5 ether); // registrar (this) sets it

        // Below threshold → not ready, process reverts.
        weth.mint(address(dist), 3 ether);
        dist.notify(address(token), 3 ether);
        assertFalse(dist.readyToProcess(address(token)), "below threshold");
        vm.expectRevert(LaunchFairV4Distributor.BelowThreshold.selector);
        dist.process(address(token), _zeros(1));

        // Cross the threshold → ready, process fires.
        weth.mint(address(dist), 3 ether);
        dist.notify(address(token), 3 ether); // 6 >= 5
        assertTrue(dist.readyToProcess(address(token)), "threshold crossed");
        dist.process(address(token), _zeros(1));
        assertGt(token.totalDistributedOf(address(token)), 0, "payout fired");
    }

    // The dev's block timer gates the buyback cadence.
    function test_payoutInterval_gatesByBlockTimer() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Increasing, address(0), address(0));
        _setupPoolAndDistributor(token);
        token.transfer(A, 300_000 ether);
        dist.setPayoutInterval(address(token), 100); // at most once per 100 blocks

        weth.mint(address(dist), 5 ether);
        dist.notify(address(token), 5 ether);

        assertFalse(dist.readyToProcess(address(token)), "timer not elapsed yet");
        vm.expectRevert(LaunchFairV4Distributor.TimerNotElapsed.selector);
        dist.process(address(token), _zeros(1));

        vm.roll(block.number + 100);
        assertTrue(dist.readyToProcess(address(token)), "timer elapsed");
        dist.process(address(token), _zeros(1));
        assertEq(dist.lastPayoutBlock(address(token)), block.number, "timer reset to now");

        // The next payout must wait another full interval.
        weth.mint(address(dist), 5 ether);
        dist.notify(address(token), 5 ether);
        assertFalse(dist.readyToProcess(address(token)), "must wait the interval again");
    }

    // process() is gated to the owner or an allowlisted keeper (M-02): an untrusted
    // caller can't force the buyback through at minOut = 0 to sandwich it.
    function test_process_restrictedToOwnerOrProcessor() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Increasing, address(0), address(0));
        _setupPoolAndDistributor(token);
        token.transfer(A, 300_000 ether);
        weth.mint(address(dist), 5 ether);
        dist.notify(address(token), 5 ether);

        // A random caller is rejected…
        vm.prank(A);
        vm.expectRevert(LaunchFairV4Distributor.NotProcessor.selector);
        dist.process(address(token), _zeros(1));

        // …once allowlisted, the keeper can process.
        dist.setProcessor(A, true);
        vm.prank(A);
        dist.process(address(token), _zeros(1));
        assertGt(token.totalDistributedOf(address(token)), 0, "allowlisted keeper processed");
    }

    // The registrar is set-once and a token's venue is frozen after launch (L-03),
    // so the owner can't re-point the registrar to hijack an existing token's buyback.
    function test_registrar_and_venue_areFrozen() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Increasing, address(0), address(0));
        _setupPoolAndDistributor(token); // registers the token's V4 venue once

        // Re-registering the same token is rejected.
        vm.expectRevert(LaunchFairV4Distributor.AlreadyRegistered.selector);
        dist.registerBuyback(address(token), address(token), _pool(address(token)));

        // setRegistrar locks after the first call.
        dist.setRegistrar(address(0xCAFE));
        vm.expectRevert(LaunchFairV4Distributor.RegistrarLocked.selector);
        dist.setRegistrar(address(0xBEEF));
    }

    // ── lottery (Mode.Lottery) ──────────────────────────────────────────────────
    // Wire a Lottery token: distributor is its epoch operator + the draw keeper.
    // Holdings-weighted: a holder's tickets are simply their held balance, so any
    // `token.transfer(addr, X)` enters `addr` with X tickets — no buySource needed.
    function _setupLottery() internal returns (LaunchTokenV2 token) {
        token = _deployToken(LaunchTokenV2.Mode.Lottery, address(0), address(0));
        dist = new LaunchFairV4Distributor(address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this));
        vrf = new MockVRFCoordinator();
        dist.setLocker(address(this));      // this feeds the pot via notify
        dist.setDrawOperator(address(this)); // this is the keeper (commits/settles)
        dist.setVrf(address(vrf));           // randomness source
        token.setLotteryOperator(address(dist)); // distributor advances the session
    }

    // Deliver the drand beacon for a round via the coordinator (it pushes to the
    // distributor), then settle with the sorted holder set. Mirrors the keeper.
    function _settle(LaunchTokenV2 token, uint256 round, bytes32 rnd, address[] memory holders) internal {
        vrf.deliver(round, rnd);
        dist.settleDraw(address(token), holders, 0);
    }

    // Sorted holder sets. A (0xA1) < B (0xB2), so [A, B] is strictly ascending.
    function _set1(address a) internal pure returns (address[] memory h) {
        h = new address[](1);
        h[0] = a;
    }

    function _set2(address a, address b) internal pure returns (address[] memory h) {
        h = new address[](2);
        h[0] = a;
        h[1] = b;
    }

    // Canonical ticket order is by ADDRESS: A gets [0, aTix), then B gets [aTix, ...).
    // (Here first-appearance == address order since A < B.) Tickets are holdings-weighted,
    // so A's ticket span is just A's held balance (== its snapshot when nothing rolled
    // between transfer and settle). The winner the CONTRACT derives — recompute to assert.
    function _resolveWinner(LaunchTokenV2 token, uint256 /* epoch */, uint256 winningTicket)
        internal
        view
        returns (address winner)
    {
        uint256 aTix = token.balanceOf(A);
        return winningTicket < aTix ? A : B;
    }

    function _ticketFor(address token, bytes32 rnd, uint256 round, uint256 total) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(rnd, token, round))) % total;
    }

    function test_lottery_drawPaysVerifiableWinner() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 300_000 ether); // A holds 300k → tickets [0, 300_000e18)
        token.transfer(B, 100_000 ether); // B holds 100k → tickets [300_000e18, 400_000e18)
        uint256 total = token.totalEligibleSupply();
        assertEq(total, 400_000 ether, "ticket pool == total held (holdings-weighted)");

        uint256 pot = 10 ether;
        weth.mint(address(dist), pot);
        dist.notify(address(token), pot);

        // Commit closes session 0: epoch advances now, the pot is reserved.
        uint256 round = 4_000_123; // a future drand round (committed before it exists)
        dist.commitDraw(address(token), round);
        assertEq(token.lotteryEpoch(), 1, "ticket sales closed at commit");
        assertEq(dist.pendingWeth(address(token)), 0, "pot reserved for the draw");

        // The keeper fetches the drand beacon for `round` and derives the winner the
        // same way the contract does — anyone can recompute this from on-chain data.
        bytes32 rnd = keccak256("drand-beacon-value-for-round");
        uint256 winningTicket = _ticketFor(address(token), rnd, round, total);
        address winner = _resolveWinner(token, 0, winningTicket); // the contract derives the same

        uint256 balBefore = weth.balanceOf(winner);
        _settle(token, round, rnd, _set2(A, B));

        assertEq(weth.balanceOf(winner) - balBefore, pot, "winner paid the whole pot");
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

    // The holder set must be sorted-distinct — the operator can't steer the winner by
    // feeding a doctored (out-of-order) set; a bad chunk reverts and settles nothing.
    function test_lottery_rejectsBadHolderSet() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);
        weth.mint(address(dist), 5 ether);
        dist.notify(address(token), 5 ether);
        dist.commitDraw(address(token), 1);
        vrf.deliver(1, keccak256("x"));

        // Unsorted / non-distinct (descending) → rejected.
        vm.expectRevert(LaunchFairV4Distributor.BadHolderSet.selector);
        dist.settleDraw(address(token), _set2(B, A), 0);
        assertEq(dist.drawCount(address(token)), 0, "nothing settled");
    }

    // The sorted holder set can be fed across multiple transactions; the draw only
    // finalizes once the running total reaches totalTickets (so an arbitrarily large
    // lottery is always settleable within block limits).
    function test_lottery_paginatedSettle() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 300_000 ether); // A holds 300k → [0, 300k)
        token.transfer(B, 100_000 ether); // B holds 100k → [300k, 400k)
        uint256 total = token.totalEligibleSupply();
        uint256 pot = 8 ether;
        weth.mint(address(dist), pot);
        dist.notify(address(token), pot);

        uint256 round = 123;
        dist.commitDraw(address(token), round);
        bytes32 rnd = keccak256("beacon");
        vrf.deliver(round, rnd);
        address expected = _resolveWinner(token, 0, _ticketFor(address(token), rnd, round, total));

        // Chunk 1: just A → not complete, so no draw yet but progress is recorded.
        dist.settleDraw(address(token), _set1(A), 0);
        assertEq(dist.drawCount(address(token)), 0, "not finalized after chunk 1");
        (bool active,,, uint256 cum,,) = dist.settlement(address(token));
        assertTrue(active, "settlement in progress");
        assertEq(cum, 300_000 ether, "chunk 1 counted A");

        // Chunk 2: B → cumulative == total, finalize + pay the derived winner.
        uint256 balBefore = weth.balanceOf(expected);
        dist.settleDraw(address(token), _set1(B), 0);
        assertEq(dist.drawCount(address(token)), 1, "finalized after chunk 2");
        assertEq(weth.balanceOf(expected) - balBefore, pot, "winner paid the whole pot");
        (bool stillActive,,,,,) = dist.settlement(address(token));
        assertFalse(stillActive, "settlement cleared on finalize");
    }

    // A botched paginated settle (out-of-order chunk that skipped a holder) can be reset
    // and restarted cleanly.
    function test_lottery_resetSettlement() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);
        weth.mint(address(dist), 4 ether);
        dist.notify(address(token), 4 ether);
        dist.commitDraw(address(token), 1);
        vrf.deliver(1, keccak256("r"));

        dist.settleDraw(address(token), _set1(A), 0); // partial progress
        (bool active,,, uint256 cum,,) = dist.settlement(address(token));
        assertTrue(active);
        assertEq(cum, 300_000 ether);

        dist.resetSettlement(address(token));
        (bool active2,,, uint256 cum2,,) = dist.settlement(address(token));
        assertFalse(active2, "settlement cleared");
        assertEq(cum2, 0);

        // Restart from the full set in one go → settles.
        dist.settleDraw(address(token), _set2(A, B), 0);
        assertEq(dist.drawCount(address(token)), 1, "settled after reset");
    }

    function test_lottery_rejectsZeroTicketHolder() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 400_000 ether); // A owns EVERY ticket
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        dist.commitDraw(address(token), 7);
        vrf.deliver(7, keccak256("y"));

        // B has zero tickets → not a real holder; the set is rejected.
        vm.expectRevert(LaunchFairV4Distributor.BadHolderSet.selector);
        dist.settleDraw(address(token), _set1(B), 0);

        // The correct singleton set settles to A (who owns every ticket).
        dist.settleDraw(address(token), _set1(A), 0);
        assertEq(dist.drawCount(address(token)), 1, "settled to the sole holder");
        (,,, address winner,,,,) = dist.draws(address(token), 0);
        assertEq(winner, A, "A derived as winner");
    }

    // An empty session can't be committed — nothing to draw.
    function test_lottery_noTicketsReverts() public {
        LaunchTokenV2 token = _setupLottery(); // nobody holds → zero eligible supply
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        vm.expectRevert(LaunchFairV4Distributor.NoTickets.selector);
        dist.commitDraw(address(token), 9);
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
        dist.settleDraw(address(token), _set1(A), 0);
    }

    function test_lottery_doubleCommitReverts() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        dist.commitDraw(address(token), 1);
        vm.expectRevert(LaunchFairV4Distributor.DrawActive.selector);
        dist.commitDraw(address(token), 2);
    }

    function test_lottery_settleWithoutCommitReverts() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        vm.expectRevert(LaunchFairV4Distributor.NoDraw.selector);
        dist.settleDraw(address(token), _set1(A), 0);
    }

    function test_lottery_commitRejectsNonLottery() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Increasing, address(0), address(0));
        dist = new LaunchFairV4Distributor(address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this));
        dist.setDrawOperator(address(this));
        vm.expectRevert(LaunchFairV4Distributor.NotLottery.selector);
        dist.commitDraw(address(token), 1);
    }

    function test_lottery_processRevertsForLottery() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        dist.registerBuyback(address(token), address(token), _pool(address(token))); // even if registered…
        vm.expectRevert(LaunchFairV4Distributor.WrongMode.selector); // …process is not the lottery path
        dist.process(address(token), _zeros(1));
    }

    // Recovery: a stuck committed draw can be canceled, rolling its reserved pot
    // back into the next draw (the closed session stays closed).
    function test_lottery_cancelReturnsPot() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        weth.mint(address(dist), 3 ether);
        dist.notify(address(token), 3 ether);
        dist.commitDraw(address(token), 1);
        assertEq(dist.pendingWeth(address(token)), 0, "pot reserved");

        dist.cancelDraw(address(token));
        assertEq(dist.pendingWeth(address(token)), 3 ether, "pot rolled back");
        assertEq(dist.drawCount(address(token)), 0, "no draw recorded");
        // Nothing pending now → settle reverts.
        vm.expectRevert(LaunchFairV4Distributor.NoDraw.selector);
        dist.settleDraw(address(token), _set1(A), 0);
    }

    // Holdings-weighted: a holder's tickets ARE their held balance, so they PERSIST
    // across draws — nothing "resets" per session. After a draw settles, the same
    // (still-holding) accounts stay fully entered in the next draw at the same odds;
    // only the POT is per-cycle (pendingWeth restarts from newly-accrued fees).
    function test_lottery_holdingsPersistAcrossDraws() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);
        assertEq(token.totalEligibleSupply(), 400_000 ether, "A + B entered by their holdings");
        weth.mint(address(dist), 4 ether);
        dist.notify(address(token), 4 ether);

        dist.commitDraw(address(token), 1); // closes epoch 0 → now epoch 1
        assertEq(token.lotteryEpoch(), 1, "session advanced at commit");
        assertEq(dist.pendingWeth(address(token)), 0, "pot reserved for the draw");

        _settle(token, 1, keccak256("r1"), _set2(A, B)); // epoch 0: A + B are the holders
        assertEq(dist.drawCount(address(token)), 1, "first draw settled");

        // No new transfers: holdings (== tickets) PERSIST. Both A and B stay fully entered
        // in the next draw at the same odds — nothing was reset to zero at the draw.
        assertEq(token.balanceOf(A), 300_000 ether, "A still holds its tickets");
        assertEq(token.balanceOf(B), 100_000 ether, "B still holds its tickets");
        assertEq(token.totalEligibleSupply(), 400_000 ether, "same total eligible into the next draw");

        // The POT is the only thing that restarts: it re-accrues from newly-notified fees
        // (the 4 ETH pot was already paid out to the winner).
        uint256 pot2 = 2 ether;
        weth.mint(address(dist), pot2);
        dist.notify(address(token), pot2);
        assertEq(dist.pendingWeth(address(token)), pot2, "next pot restarts from new fees only");

        dist.commitDraw(address(token), 2); // closes epoch 1 → now epoch 2
        assertEq(token.lotteryEpoch(), 2, "second session advanced");

        // The second draw's odds pool == the CURRENT total eligible (holders unchanged),
        // frozen at this commit's snapshot block.
        (, , , uint256 snapBlk, , , ) = dist.pendingDraw(address(token));
        assertEq(token.totalEligibleAt(snapBlk), 400_000 ether, "second draw uses the persisted holdings");

        bytes32 rnd = keccak256("r2");
        address expected = _resolveWinner(token, 1, _ticketFor(address(token), rnd, 2, 400_000 ether));
        uint256 balBefore = weth.balanceOf(expected);
        _settle(token, 2, rnd, _set2(A, B)); // both are still holders in the second draw
        assertEq(weth.balanceOf(expected) - balBefore, pot2, "second draw pays the fresh pot to the derived winner");
        assertEq(dist.drawCount(address(token)), 2, "two draws in history");
    }

    // Front-run-proof: the draw snapshots holdings at the COMMIT block, so selling AFTER
    // commit (even before the beacon is public) can't dodge or steer the draw. A dumps its
    // whole balance post-commit, yet the draw still counts A at its pre-sell (snapshot)
    // balance and settles off the original total.
    function test_lottery_snapshotFrozenAtCommit() public {
        LaunchTokenV2 token = _setupLottery();
        // Use literal block numbers (via_ir re-reads `block.number` across vm.roll, so
        // `vm.roll(block.number + N)` twice can reuse a stale value — use literals).
        vm.roll(100);
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);
        uint256 originalTotal = token.totalEligibleSupply();
        assertEq(originalTotal, 400_000 ether, "A + B entered by their holdings");

        uint256 pot = 5 ether;
        weth.mint(address(dist), pot);
        dist.notify(address(token), pot);

        // Advance to a distinct block, then commit — records snapshotBlock = commit block.
        vm.roll(200);
        uint256 round = 3;
        dist.commitDraw(address(token), round);
        (, , , uint256 snapBlk, , , ) = dist.pendingDraw(address(token));
        assertEq(snapBlk, 200, "snapshot frozen at the commit block");

        // Roll forward again and have A DUMP its entire balance after the commit.
        // (Read A's balance BEFORE vm.prank — an inner view call would consume the prank.)
        vm.roll(300);
        uint256 aBal = token.balanceOf(A);
        vm.prank(A);
        token.transfer(B, aBal); // A sells everything (to B) post-commit
        assertEq(token.balanceOf(A), 0, "A now holds nothing (current balance)");

        // …but the draw is frozen at the snapshot: A still counts for its pre-sell balance
        // and the total is unchanged. Selling after commit cannot dodge/steer the draw.
        assertEq(token.balanceOfAt(A, snapBlk), 300_000 ether, "A's SNAPSHOT balance, not its now-zero current one");
        assertEq(token.balanceOfAt(B, snapBlk), 100_000 ether, "B's snapshot balance unaffected by the incoming transfer");
        assertEq(token.totalEligibleAt(snapBlk), originalTotal, "odds denominator frozen at commit");

        // Settle against the SNAPSHOT holder set {A, B}: succeeds using the original total,
        // and A (despite selling) remains a valid, snapshot-weighted participant.
        _settle(token, round, keccak256("frozen"), _set2(A, B));
        assertEq(dist.drawCount(address(token)), 1, "draw settled off the frozen snapshot");
        (,,,,, uint256 recordedTotal,,) = dist.draws(address(token), 0);
        assertEq(recordedTotal, originalTotal, "draw recorded the pre-sell total");
    }

    // A lottery whose prize is a dev-chosen token (bought with the pot on V3),
    // rather than WETH: the winner is paid in that token.
    function _setupLotteryWithPrize(address prize) internal returns (LaunchTokenV2 token) {
        token = _deployToken(LaunchTokenV2.Mode.Lottery, prize, address(0)); // prize == the lottery prize token
        dist = new LaunchFairV4Distributor(address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this));
        vrf = new MockVRFCoordinator();
        dist.setLocker(address(this));
        dist.setDrawOperator(address(this));
        dist.setVrf(address(vrf));
        token.setLotteryOperator(address(dist));
        dist.registerBuybackV3(address(token), prize, 10_000); // prize bought on a V3 pool
    }

    function test_lottery_tokenPrize_boughtAndPaidToWinner() public {
        MockToken prize = new MockToken("Prize", "PRZ");
        LaunchTokenV2 token = _setupLotteryWithPrize(address(prize));
        token.transfer(A, 200_000 ether); // A owns every ticket

        uint256 pot = 3 ether;
        weth.mint(address(dist), pot);
        dist.notify(address(token), pot);
        dist.commitDraw(address(token), 1);
        // settleDraw returns the amount paid — the keeper eth_calls this with
        // minPrizeOut=0 to quote the prize swap, then re-sends with a real bound (M-03).
        vrf.deliver(1, keccak256("r"));
        uint256 paid = dist.settleDraw(address(token), _set1(A), 0);
        assertEq(paid, pot * v3router.rate(), "settleDraw returns the bought prize amount");

        // Pot swapped to the prize token (mock rate 2x) and paid to the winner.
        assertEq(prize.balanceOf(A), pot * v3router.rate(), "winner paid in the prize token");
        assertEq(weth.balanceOf(A), 0, "not paid in WETH");
        assertEq(weth.balanceOf(address(dist)), 0, "pot fully swapped");
        (,,,, uint256 recordedPrize,,,) = dist.draws(address(token), 0);
        assertEq(recordedPrize, pot, "draw records the WETH pot value");
    }

    // Token-prize slippage: if the swap can't meet minPrizeOut (or the venue/winner is
    // broken), settle falls back to paying the WETH pot rather than wedging the now
    // un-cancelable draw (audit L-03). The winner still gets full pot value; a sandwicher
    // gains nothing (the swap rolls back).
    function test_lottery_tokenPrize_slippageFallsBackToWeth() public {
        MockToken prize = new MockToken("Prize", "PRZ");
        LaunchTokenV2 token = _setupLotteryWithPrize(address(prize));
        token.transfer(A, 100_000 ether);
        uint256 pot = 2 ether;
        weth.mint(address(dist), pot);
        dist.notify(address(token), pot);
        dist.commitDraw(address(token), 1);
        vrf.deliver(1, keccak256("r"));

        uint256 balBefore = weth.balanceOf(A);
        // out would be 4 (2 * rate); demanding 100 exceeds it → WETH fallback, no revert.
        uint256 paid = dist.settleDraw(address(token), _set1(A), 100 ether);
        assertEq(paid, pot, "paid the WETH pot on fallback");
        assertEq(weth.balanceOf(A) - balBefore, pot, "winner got the WETH pot");
        assertEq(prize.balanceOf(A), 0, "not paid in the prize token");
        assertEq(dist.drawCount(address(token)), 1, "draw finalized (not wedged)");
    }

    // Randomness must be delivered before a draw can settle.
    function test_lottery_settleBeforeRandomnessReverts() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        dist.commitDraw(address(token), 5); // committed, but the beacon isn't posted
        vm.expectRevert(LaunchFairV4Distributor.RandomnessNotReady.selector);
        dist.settleDraw(address(token), _set1(A), 0);
    }

    // commitDraw without a wired coordinator reverts.
    function test_lottery_commitRequiresVrf() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Lottery, address(0), address(0));
        dist = new LaunchFairV4Distributor(address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this));
        dist.setDrawOperator(address(this));
        token.setLotteryOperator(address(dist));
        token.transfer(A, 100_000 ether);
        vm.expectRevert(LaunchFairV4Distributor.VrfNotSet.selector);
        dist.commitDraw(address(token), 1);
    }

    // The dev's block timer also gates how often draws can be committed.
    function test_lottery_intervalGatesCommit() public {
        LaunchTokenV2 token = _setupLottery();
        dist.setPayoutInterval(address(token), 50);
        token.transfer(A, 100_000 ether);
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);

        vm.expectRevert(LaunchFairV4Distributor.TimerNotElapsed.selector);
        dist.commitDraw(address(token), 1);

        vm.roll(block.number + 50);
        dist.commitDraw(address(token), 1); // now allowed
        assertEq(dist.lastPayoutBlock(address(token)), block.number, "timer reset on commit");
    }

    // ── audit regression tests ───────────────────────────────────────────────────
    uint256 constant DRAND_GENESIS = 1_692_803_367;

    // C-01: committing to an already-produced (past/current) round is rejected, so the
    // operator can't grind a public beacon to choose the winner.
    function test_lottery_commitRejectsPastRound() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        vm.warp(DRAND_GENESIS + 1000 * 3); // round ~1001 is being produced now

        vm.expectRevert(LaunchFairV4Distributor.RoundNotFuture.selector);
        dist.commitDraw(address(token), 500); // past round
        vm.expectRevert(LaunchFairV4Distributor.RoundNotFuture.selector);
        dist.commitDraw(address(token), 1001); // current round (beacon imminent)

        dist.commitDraw(address(token), 2000); // genuinely future → allowed
        assertEq(token.lotteryEpoch(), 1, "committed to a future round");
    }

    // M-02: once the committed round's beacon time has passed, the operator can no longer
    // cancel to veto an unfavorable revealed outcome — it must settle.
    function test_lottery_cancelRejectedAfterBeacon() public {
        LaunchTokenV2 token = _setupLottery();
        token.transfer(A, 100_000 ether);
        weth.mint(address(dist), 1 ether);
        dist.notify(address(token), 1 ether);
        vm.warp(DRAND_GENESIS + 1000 * 3);
        uint256 round = 2000;
        dist.commitDraw(address(token), round);

        // Warp past the round's beacon production time.
        vm.warp(DRAND_GENESIS + (round - 1) * 3 + 1);
        vm.expectRevert(LaunchFairV4Distributor.BeaconAlreadyProduced.selector);
        dist.cancelDraw(address(token));
    }

    // M-01: the randomness source is set-once — the owner can't swap it to rig draws.
    function test_setVrf_setOnce() public {
        LaunchFairV4Distributor d = new LaunchFairV4Distributor(
            address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this)
        );
        d.setVrf(address(0x1111));
        vm.expectRevert(LaunchFairV4Distributor.VrfAlreadySet.selector);
        d.setVrf(address(0x2222));
    }
}
