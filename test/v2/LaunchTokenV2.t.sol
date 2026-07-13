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
        // A single external reward token becomes a one-asset Reward config (weight
        // 10000); Increasing/Base pass empty arrays (Increasing auto-registers THIS
        // token as its sole reward asset). No prize token in these helpers.
        address[] memory rewardTokens = new address[](0);
        uint16[] memory rewardWeights = new uint16[](0);
        if (reward != address(0)) {
            rewardTokens = _arr1(reward);
            rewardWeights = _w1(10_000);
        }
        t = new LaunchTokenV2(
            "Tok", "TOK", SUPPLY, "https://hood.launchfair.app", _meta(), 0, 0, mode, rewardTokens, rewardWeights, address(0), minHold, address(this)
        );
        t.excludeFromDividends(POOL, true); // simulate excluding the pool
    }

    function _arr1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _w1(uint16 w) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](1);
        arr[0] = w;
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
        t.fundRewards(address(reward), 1_000 ether);

        // 3:1 split.
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), A), 750 ether, 100, "A gets 3/4");
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), B), 250 ether, 100, "B gets 1/4");
        assertEq(t.totalDistributedOf(address(reward)), 1_000 ether);

        // A claims the reward token.
        vm.prank(A);
        t.claim();
        assertApproxEqAbs(reward.balanceOf(A), 750 ether, 100, "A received reward token");
        assertEq(t.withdrawableDividendOf(address(reward), A), 0, "nothing left after claim");
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
        t.fundRewards(address(reward), 1_000 ether);

        // Keeper pushes payouts — holders never call claim themselves.
        t.processAccounts(_two(A, B));
        assertApproxEqAbs(reward.balanceOf(A), 750 ether, 100, "A auto-received");
        assertApproxEqAbs(reward.balanceOf(B), 250 ether, 100, "B auto-received");
        assertEq(t.withdrawableDividendOf(address(reward), A), 0, "A settled");
        assertEq(t.withdrawableDividendOf(address(reward), B), 0, "B settled");

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
        t.fundRewards(address(reward), 1_000 ether);

        // A moves all tokens to B AFTER accruing — A keeps its 750 accrued.
        vm.prank(A);
        t.transfer(B, 300_000 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), A), 750 ether, 100, "already-accrued survives transfer");
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), B), 250 ether, 100, "B unchanged on prior round");

        // Next round: now B holds everything, so B gets all of it.
        reward.mint(address(this), 400 ether);
        reward.approve(address(t), 400 ether);
        t.fundRewards(address(reward), 400 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), A), 750 ether, 100, "A gains nothing (0 balance)");
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), B), 650 ether, 100, "B: 250 + 400");
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
        t.fundRewards(address(reward), 1_000 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), A), 1_000 ether, 100, "A gets all (B below min)");
        assertEq(t.withdrawableDividendOf(address(reward), B), 0, "B earns nothing below min");

        // B tops up above the minimum → eligible for FUTURE rewards only.
        vm.prank(POOL);
        t.transfer(B, 150_000 ether); // B now 250k
        assertEq(t.totalShares(), 550_000 ether, "B now counts");
        reward.mint(address(this), 550 ether);
        reward.approve(address(t), 550 ether);
        t.fundRewards(address(reward), 550 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), B), 250 ether, 100, "B earns on the new round");
        assertEq(t.withdrawableDividendOf(address(reward), B) < 251 ether, true, "no retroactive earnings");
    }

    function test_excludedAccountDoesNotAccrue() public {
        MockERC20 reward = new MockERC20("Reward", "RWD");
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Reward, address(reward));
        t.transfer(POOL, 600_000 ether); // pool excluded, holds tokens
        t.transfer(A, 400_000 ether); // A is the only real holder
        assertEq(t.totalShares(), 400_000 ether, "pool not counted");

        reward.mint(address(this), 1_000 ether);
        reward.approve(address(t), 1_000 ether);
        t.fundRewards(address(reward), 1_000 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(address(reward), A), 1_000 ether, 100, "A gets 100%");
        assertEq(t.withdrawableDividendOf(address(reward), POOL), 0, "excluded pool accrues nothing");
    }

    // ── Increasing mode (asset == this token) ────────────────────────────────
    // Sum of every account's balanceOf must always equal totalSupply — the
    // reflection must not double-count the accrued-but-unrealized pool.
    function _assertSupplyInvariant(LaunchTokenV2 t) internal view {
        uint256 sum = t.balanceOf(address(this)) + t.balanceOf(A) + t.balanceOf(B) + t.balanceOf(POOL)
            + t.balanceOf(address(t));
        assertApproxEqAbs(sum, t.totalSupply(), 100, "sum of balanceOf == totalSupply");
    }

    function test_increasing_autoCompoundsIntoBalance() public {
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Increasing, address(0));
        t.transfer(A, 300_000 ether);
        t.transfer(B, 100_000 ether);
        assertEq(t.totalShares(), 400_000 ether);

        uint256 aBefore = t.balanceOf(A);
        uint256 bBefore = t.balanceOf(B);

        // Fund 1000 THIS-token (a buyback). Balances grow IMMEDIATELY — no claim,
        // no keeper push.
        t.approve(address(t), 1_000 ether);
        t.fundRewards(address(t), 1_000 ether);

        assertApproxEqAbs(t.balanceOf(A), aBefore + 750 ether, 100, "A auto-grew 3/4 with no claim");
        assertApproxEqAbs(t.balanceOf(B), bBefore + 250 ether, 100, "B auto-grew 1/4 with no claim");
        assertEq(t.balanceOf(address(t)), 0, "reflection pool netted out of the contract's balance");
        _assertSupplyInvariant(t);

        // A transfer realizes A's reflection into its real balance and preserves value.
        uint256 aBal = t.balanceOf(A);
        vm.prank(A);
        t.transfer(B, 50_000 ether);
        assertApproxEqAbs(t.balanceOf(A), aBal - 50_000 ether, 100, "A down exactly by the transfer");
        _assertSupplyInvariant(t);

        // A second buyback compounds on the already-grown balances.
        t.approve(address(t), 500 ether);
        t.fundRewards(address(t), 500 ether);
        _assertSupplyInvariant(t);
    }

    // The V4 pool (excluded) must NOT rebase — its balance stays exact so trading
    // isn't corrupted.
    function test_increasing_excludedPoolBalanceStaysExact() public {
        LaunchTokenV2 t = _deploy(LaunchTokenV2.Mode.Increasing, address(0));
        t.transfer(A, 200_000 ether);
        t.transfer(POOL, 500_000 ether); // the "pool" holds liquidity (excluded)
        uint256 poolBal = t.balanceOf(POOL);

        t.approve(address(t), 1_000 ether);
        t.fundRewards(address(t), 1_000 ether); // only A has a share

        assertEq(t.balanceOf(POOL), poolBal, "pool balance unchanged by reflection");
        assertApproxEqAbs(t.balanceOf(A), 200_000 ether + 1_000 ether, 100, "A got the whole reflection");
        _assertSupplyInvariant(t);
    }

    // ── Lottery mode (holdings-weighted, powerball/$BALL style) ─────────────────
    // Tickets are your ELIGIBLE HELD balance — any non-excluded holder is entered,
    // weighted by balance. The test contract is the launchpad (excluded, holds no
    // tickets); the pool is excluded too. Tickets go to fresh holders (A, B) via
    // transfer. Checkpoints are keyed by block.number, so vm.roll separates them.
    function _deployLottery() internal returns (LaunchTokenV2 t) {
        t = new LaunchTokenV2(
            "Lotto", "LOT", SUPPLY, "https://hood.launchfair.app", _meta(), 0, 0, LaunchTokenV2.Mode.Lottery, new address[](0), new uint16[](0), address(0), 0, address(this)
        );
        t.setLotteryOperator(address(this)); // test acts as the lottery distributor
        t.excludeFromDividends(POOL, true); // the pool holds no tickets
    }

    // Tickets == eligible held balance: holding enters you, weighted by balance, and
    // a plain-transfer RECEIVER now GAINS tickets (the old "receiver earns nothing"
    // is false). Past-block reads are frozen at that block's checkpoint.
    function test_lottery_ticketsAreHoldings() public {
        LaunchTokenV2 t = _deployLottery();

        uint256 X = 300 ether;
        uint256 Y = 100 ether;
        // Use explicit block numbers (via_ir re-reads `block.number` across vm.roll, so
        // never capture it into a var before a roll — use literals for checkpoint keys).
        vm.roll(100);
        // Simply HOLDING tokens enters A and B — no buySource needed.
        t.transfer(A, X);
        t.transfer(B, Y);

        assertEq(t.balanceOf(A), X, "A holds X");
        assertEq(t.balanceOf(B), Y, "B holds Y");
        assertEq(t.balanceOfAt(A, 100), X, "A's tickets == held balance");
        // Test contract (launchpad) and POOL are excluded → 0 eligible; A and B are
        // the only entrants, so the odds denominator is exactly their held total.
        assertEq(t.totalEligibleSupply(), X + Y, "total eligible = A + B holdings");

        // Roll to a DISTINCT block so the next change lands on a new checkpoint.
        vm.roll(200);

        // B sends half its holdings to A: the receiver A gains those tickets.
        vm.prank(B);
        t.transfer(A, Y / 2);

        assertEq(t.balanceOfAt(A, 200), X + Y / 2, "receiver A GAINED tickets");
        assertEq(t.balanceOfAt(B, 200), Y / 2, "sender B's tickets dropped");
        // Internal transfer between two eligible holders conserves the held total.
        assertEq(t.totalEligibleSupply(), X + Y, "eligible total unchanged by internal transfer");

        // Checkpoint freeze: A's eligible AT block 100 is still its old value.
        assertEq(t.balanceOfAt(A, 100), X, "past checkpoint frozen at A's earlier balance");
    }

    // Selling reduces tickets: moving tokens to an EXCLUDED holder (the pool) or
    // burning them removes those tickets from A and from the odds denominator.
    function test_lottery_sellingReducesTickets() public {
        LaunchTokenV2 t = _deployLottery();

        uint256 X = 300 ether;
        vm.roll(100);
        t.transfer(A, X);
        assertEq(t.balanceOfAt(A, 100), X, "A's tickets == held");
        assertEq(t.totalEligibleSupply(), X, "A is the only entrant");

        // Selling to the pool == transferring to an EXCLUDED address → tickets leave.
        uint256 sold = 100 ether;
        vm.roll(200);
        vm.prank(A);
        t.transfer(POOL, sold);
        assertEq(t.balanceOf(A), X - sold, "A's balance dropped by the sale");
        assertEq(t.balanceOfAt(A, 200), X - sold, "A's tickets dropped by the sale");
        assertEq(t.totalEligibleSupply(), X - sold, "excluded pool holds no tickets, total drops");

        // Burning (ERC20Burnable) also removes tickets from A and the total.
        uint256 burned = 50 ether;
        vm.roll(300);
        vm.prank(A);
        t.burn(burned);
        assertEq(t.balanceOfAt(A, 300), X - sold - burned, "burn dropped A's tickets");
        assertEq(t.totalEligibleSupply(), X - sold - burned, "burn removed those tickets from the total");

        // The pre-sale checkpoint (block 100) stays frozen at A's full holdings.
        assertEq(t.balanceOfAt(A, 100), X, "pre-sale tickets frozen at full holdings");
    }

    // A draw only advances the cycle counter (and resets the POT); it does NOT reset
    // tickets — holdings persist across draws.
    function test_lottery_holdingsPersistAcrossDraws() public {
        LaunchTokenV2 t = _deployLottery();

        uint256 X = 300 ether;
        t.transfer(A, X);
        uint256 e = t.lotteryEpoch();
        assertEq(t.balanceOfAt(A, block.number), X, "A's tickets == held before the draw");
        assertEq(t.totalEligibleSupply(), X, "total eligible before the draw");

        // Advance the draw cycle as the operator (the test contract).
        uint256 closed = t.advanceLotteryEpoch();
        assertEq(closed, e, "closed the current cycle");
        assertEq(t.lotteryEpoch(), e + 1, "cycle counter incremented");

        // Holdings persist: A STILL has tickets == balance after the draw.
        assertEq(t.balanceOf(A), X, "A still holds X");
        assertEq(t.balanceOfAt(A, block.number), X, "A's tickets unchanged by the draw");
        assertEq(t.totalEligibleSupply(), X, "total eligible unchanged by the draw");
    }

    function test_lottery_onlyOperatorAdvances() public {
        LaunchTokenV2 t = new LaunchTokenV2(
            "Lotto", "LOT", SUPPLY, "https://hood.launchfair.app", _meta(), 0, 0, LaunchTokenV2.Mode.Lottery, new address[](0), new uint16[](0), address(0), 0, address(this)
        );
        t.setLotteryOperator(address(0xABCD));
        vm.expectRevert(LaunchTokenV2.NotAuthorized.selector);
        t.advanceLotteryEpoch();
    }

    function test_wrongModeReverts() public {
        LaunchTokenV2 base = _deploy(LaunchTokenV2.Mode.Base, address(0));
        // Base registers no reward assets, so funding any asset reverts NotRewardAsset.
        vm.expectRevert(LaunchTokenV2.NotRewardAsset.selector);
        base.fundRewards(address(0), 1); // only Reward / Increasing accept rewards
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
