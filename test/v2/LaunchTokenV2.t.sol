// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Unit tests for the LaunchTokenV2 dividend tracker — the novel, most
/// bug-prone part. The test contract acts as the launchpad (deployer), so it's
/// excluded from dividends and holds the initial supply (mirroring how the real
/// launchpad holds supply momentarily before it enters the pool).
contract LaunchTokenV2Test is Test {
    address constant POOL = address(0x1111);
    address constant A = address(0xAA);
    address constant B = address(0xBB);

    uint256 constant SUPPLY = 1_000_000 ether;

    function _meta() internal pure returns (LaunchTokenV2.Metadata memory m) {
        m; // all-empty metadata
    }

    function _deploy(LaunchTokenV2.Mode mode, address reward) internal returns (LaunchTokenV2 t) {
        t = _deployMin(mode, reward, 0);
    }

    function _deployMin(LaunchTokenV2.Mode mode, address reward, uint256 minHold) internal returns (LaunchTokenV2 t) {
        t = new LaunchTokenV2(
            "Tok", "TOK", SUPPLY, "https://hood.launchfair.app", _meta(), 0, 0, mode, reward, address(0), minHold, address(this)
        );
        t.excludeFromDividends(POOL, true); // simulate excluding the pool
    }

    // ── Reward mode ──────────────────────────────────────────────────────────
    function test_reward_proRataAndClaim() public {
        MockERC20 reward = new MockERC20("Reward", "RWD");
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Reward, address(reward));

        // Simulate two buyers pulling from the (excluded) pool: A holds 3x B.
        t.transfer(POOL, SUPPLY);
        vm.prank(POOL);
        t.transfer(A, 300_000 ether);
        vm.prank(POOL);
        t.transfer(B, 100_000 ether);
        assertEq(t.totalShares(), 400_000 ether, "shares = real holders only");

        // Fund 1000 RWD of rewards.
        reward.mint(address(this), 1_000 ether);
        reward.approve(address(t), 1_000 ether);
        t.fundRewards(1_000 ether);

        // 3:1 split.
        assertApproxEqAbs(t.withdrawableDividendOf(A), 750 ether, 100, "A gets 3/4");
        assertApproxEqAbs(t.withdrawableDividendOf(B), 250 ether, 100, "B gets 1/4");
        assertEq(t.totalDistributed(), 1_000 ether);

        // A claims the reward token.
        vm.prank(A);
        t.claim();
        assertApproxEqAbs(reward.balanceOf(A), 750 ether, 100, "A received reward token");
        assertEq(t.withdrawableDividendOf(A), 0, "nothing left after claim");
    }

    function test_reward_autoPushNoClaim() public {
        MockERC20 reward = new MockERC20("Reward", "RWD");
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Reward, address(reward));
        t.transfer(POOL, SUPPLY);
        vm.prank(POOL);
        t.transfer(A, 300_000 ether);
        vm.prank(POOL);
        t.transfer(B, 100_000 ether);

        reward.mint(address(this), 1_000 ether);
        reward.approve(address(t), 1_000 ether);
        t.fundRewards(1_000 ether);

        // Keeper pushes payouts — holders never call claim themselves.
        t.processAccounts(_two(A, B));
        assertApproxEqAbs(reward.balanceOf(A), 750 ether, 100, "A auto-received");
        assertApproxEqAbs(reward.balanceOf(B), 250 ether, 100, "B auto-received");
        assertEq(t.withdrawableDividendOf(A), 0, "A settled");
        assertEq(t.withdrawableDividendOf(B), 0, "B settled");

        // Idempotent: re-pushing with nothing owed does nothing.
        t.processAccounts(_two(A, B));
        assertApproxEqAbs(reward.balanceOf(A), 750 ether, 100, "no double-pay");
    }

    function _two(address x, address y) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = x;
        a[1] = y;
    }

    function test_reward_transferPreservesAccrued() public {
        MockERC20 reward = new MockERC20("Reward", "RWD");
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Reward, address(reward));
        t.transfer(POOL, SUPPLY);
        vm.prank(POOL);
        t.transfer(A, 300_000 ether);
        vm.prank(POOL);
        t.transfer(B, 100_000 ether);

        reward.mint(address(this), 1_000 ether);
        reward.approve(address(t), 1_000 ether);
        t.fundRewards(1_000 ether);

        // A moves all tokens to B AFTER accruing — A keeps its 750 accrued.
        vm.prank(A);
        t.transfer(B, 300_000 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(A), 750 ether, 100, "already-accrued survives transfer");
        assertApproxEqAbs(t.withdrawableDividendOf(B), 250 ether, 100, "B unchanged on prior round");

        // Next round: now B holds everything, so B gets all of it.
        reward.mint(address(this), 400 ether);
        reward.approve(address(t), 400 ether);
        t.fundRewards(400 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(A), 750 ether, 100, "A gains nothing (0 balance)");
        assertApproxEqAbs(t.withdrawableDividendOf(B), 650 ether, 100, "B: 250 + 400");
    }

    function test_reward_minimumHold() public {
        MockERC20 reward = new MockERC20("Reward", "RWD");
        LaunchTokenV2 t = _deployMin(LaunchTokenV2.Mode.Reward, address(reward), 200_000 ether);
        t.transfer(POOL, SUPPLY);
        vm.prank(POOL);
        t.transfer(A, 300_000 ether); // >= min → eligible
        vm.prank(POOL);
        t.transfer(B, 100_000 ether); // < min → NOT eligible
        assertEq(t.totalShares(), 300_000 ether, "only A counts");

        reward.mint(address(this), 1_000 ether);
        reward.approve(address(t), 1_000 ether);
        t.fundRewards(1_000 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(A), 1_000 ether, 100, "A gets all (B below min)");
        assertEq(t.withdrawableDividendOf(B), 0, "B earns nothing below min");

        // B tops up above the minimum → eligible for FUTURE rewards only.
        vm.prank(POOL);
        t.transfer(B, 150_000 ether); // B now 250k
        assertEq(t.totalShares(), 550_000 ether, "B now counts");
        reward.mint(address(this), 550 ether);
        reward.approve(address(t), 550 ether);
        t.fundRewards(550 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(B), 250 ether, 100, "B earns on the new round");
        assertEq(t.withdrawableDividendOf(B) < 251 ether, true, "no retroactive earnings");
    }

    function test_excludedAccountDoesNotAccrue() public {
        MockERC20 reward = new MockERC20("Reward", "RWD");
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Reward, address(reward));
        t.transfer(POOL, 600_000 ether); // pool excluded, holds tokens
        t.transfer(A, 400_000 ether); // A is the only real holder
        assertEq(t.totalShares(), 400_000 ether, "pool not counted");

        reward.mint(address(this), 1_000 ether);
        reward.approve(address(t), 1_000 ether);
        t.fundRewards(1_000 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(A), 1_000 ether, 100, "A gets 100%");
        assertEq(t.withdrawableDividendOf(POOL), 0, "excluded pool accrues nothing");
    }

    // ── Increasing mode (asset == this token) ────────────────────────────────
    function test_increasing_distributesOwnToken() public {
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Increasing, address(0));
        // Keep some supply on the launchpad (this) to fund the buyback with.
        t.transfer(A, 300_000 ether);
        t.transfer(B, 100_000 ether);
        assertEq(t.totalShares(), 400_000 ether);

        // Fund 1000 of THIS token (simulating a buyback).
        t.approve(address(t), 1_000 ether);
        t.fundRewards(1_000 ether);

        assertApproxEqAbs(t.withdrawableDividendOf(A), 750 ether, 100);
        assertApproxEqAbs(t.withdrawableDividendOf(B), 250 ether, 100);

        uint256 before = t.balanceOf(A);
        vm.prank(A);
        t.claim();
        assertApproxEqAbs(t.balanceOf(A), before + 750 ether, 100, "claimed tokens compound into balance");
    }

    function test_lottery_ticketsFromBuys_resetOnDraw() public {
        LaunchTokenV2 t = new LaunchTokenV2(
            "Lotto", "LOT", SUPPLY, "https://hood.launchfair.app", _meta(), 0, 0, LaunchTokenV2.Mode.Lottery, address(0), address(0), 0, address(this)
        );
        t.setBuySource(POOL);
        t.setLotteryOperator(address(this)); // test acts as the lottery distributor
        t.excludeFromDividends(POOL, true);
        t.transfer(POOL, SUPPLY); // seed the "pool"

        // Buys = transfers FROM the pool → earn tickets proportional to size.
        vm.prank(POOL);
        t.transfer(A, 300 ether);
        vm.prank(POOL);
        t.transfer(B, 100 ether);
        uint256 e = t.lotteryEpoch();
        assertEq(t.ticketsOf(e, A), 300 ether, "A tickets == buy size");
        assertEq(t.ticketsOf(e, B), 100 ether, "B tickets");
        assertEq(t.totalTickets(e), 400 ether, "session total");

        // Draw advances the epoch → tickets reset; old session preserved.
        uint256 closed = t.advanceLotteryEpoch();
        assertEq(closed, e, "closed the old session");
        uint256 e2 = t.lotteryEpoch();
        assertEq(e2, e + 1, "new session started");
        assertEq(t.totalTickets(e2), 0, "fresh session, zero tickets");
        assertEq(t.ticketsOf(e, A), 300 ether, "old session tickets preserved");

        // New buys count only toward the new session.
        vm.prank(POOL);
        t.transfer(A, 200 ether);
        assertEq(t.ticketsOf(e2, A), 200 ether, "new session buy");
        assertEq(t.ticketsOf(e, A), 300 ether, "old session unchanged");
    }

    // Selling (or transferring out) removes tickets: your odds track tokens bought
    // this session and STILL held. A buy→sell round-trip nets zero.
    function test_lottery_sellRemovesTickets() public {
        LaunchTokenV2 t = new LaunchTokenV2(
            "Lotto", "LOT", SUPPLY, "https://hood.launchfair.app", _meta(), 0, 0, LaunchTokenV2.Mode.Lottery, address(0), address(0), 0, address(this)
        );
        t.setBuySource(POOL);
        t.setLotteryOperator(address(this));
        t.excludeFromDividends(POOL, true);
        t.transfer(POOL, SUPPLY);
        uint256 e = t.lotteryEpoch();

        vm.prank(POOL);
        t.transfer(A, 300 ether); // A buys 300
        vm.prank(POOL);
        t.transfer(B, 100 ether); // B buys 100
        assertEq(t.totalTickets(e), 400 ether, "start");

        // A sells 100 back to the pool → tickets drop by 100.
        vm.prank(A);
        t.transfer(POOL, 100 ether);
        assertEq(t.ticketsOf(e, A), 200 ether, "sell removed tickets");
        assertEq(t.totalTickets(e), 300 ether, "pool total shrank");

        // A transfers 50 to B → A loses those tickets; B (a receiver) gains none.
        vm.prank(A);
        t.transfer(B, 50 ether);
        assertEq(t.ticketsOf(e, A), 150 ether, "transfer out removed tickets");
        assertEq(t.ticketsOf(e, B), 100 ether, "receiver earns no tickets");
        assertEq(t.totalTickets(e), 250 ether, "total tracks net held");

        // Wash trade: B buys 200 more then dumps it all → nets zero tickets.
        vm.prank(POOL);
        t.transfer(B, 200 ether); // B tickets 300
        vm.prank(B);
        t.transfer(POOL, 300 ether); // dump 300
        assertEq(t.ticketsOf(e, B), 0, "wash trade nets zero");

        // A dumps the rest → fully out, zero odds.
        vm.prank(A);
        t.transfer(POOL, 150 ether);
        assertEq(t.ticketsOf(e, A), 0, "full seller has no tickets");
        assertEq(t.totalTickets(e), 0, "nobody eligible after everyone sold");
    }

    function test_lottery_onlyOperatorAdvances() public {
        LaunchTokenV2 t = new LaunchTokenV2(
            "Lotto", "LOT", SUPPLY, "https://hood.launchfair.app", _meta(), 0, 0, LaunchTokenV2.Mode.Lottery, address(0), address(0), 0, address(this)
        );
        t.setLotteryOperator(address(0xABCD));
        vm.expectRevert(LaunchTokenV2.NotAuthorized.selector);
        t.advanceLotteryEpoch();
    }

    function test_wrongModeReverts() public {
        LaunchTokenV2 base = _deploy(LaunchTokenV2.Mode.Base, address(0));
        vm.expectRevert(LaunchTokenV2.WrongMode.selector);
        base.fundRewards(1); // only Reward / Increasing accept rewards
    }

    function test_metadataAndBranding() public {
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Base, address(0));
        assertEq(t.VERSION(), "LaunchFair V2");
        assertEq(t.url(), "https://hood.launchfair.app");
        assertEq(t.platformSite(), "https://hood.launchfair.app");
        assertEq(t.owner(), address(0), "renounced");

        // contractURI is now a PLAIN, bot-readable https URL (not base64).
        string memory uri = t.contractURI();
        assertTrue(_startsWith(uri, "https://hood.launchfair.app/token/0x"), "plain URL");
        assertFalse(_startsWith(uri, "data:"), "no base64 data URI");
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(p);
        if (sb.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; i++) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }
}
