// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SeasonMerkleDistributor} from "../../src/flywheel/SeasonMerkleDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFlagship is ERC20 {
    constructor() ERC20("Flagship", "FLAG") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// A 1%-fee-on-transfer token: recipient receives 99% of every transfer.
contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function _fee(uint256 a) internal pure returns (uint256) {
        return a / 100;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 f = _fee(amount);
        _transfer(msg.sender, address(0xdead), f);
        _transfer(msg.sender, to, amount - f);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 f = _fee(amount);
        _transfer(from, address(0xdead), f);
        _transfer(from, to, amount - f);
        return true;
    }
}

contract SeasonMerkleDistributorTest is Test {
    SeasonMerkleDistributor dist;
    MockFlagship flag;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address publisher = makeAddr("publisher");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant SEASON = 2949;
    uint256 aliceAmt = 30 ether;
    uint256 bobAmt = 70 ether;

    bytes32 leafA;
    bytes32 leafB;
    bytes32 root;

    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function setUp() public {
        vm.prank(owner);
        flag = new MockFlagship(); // owner holds the supply
        dist = new SeasonMerkleDistributor(owner, IERC20(address(flag)), treasury, publisher);
        // Most tests exercise the happy path — disable the claim veto delay here; the dedicated
        // veto tests below set it back on.
        vm.prank(owner);
        dist.setClaimDelay(0);

        leafA = _leaf(0, alice, aliceAmt);
        leafB = _leaf(1, bob, bobAmt);
        root = _hashPair(leafA, leafB);

        // Fund + publish the season atomically as the keeper would.
        vm.startPrank(owner);
        flag.transfer(publisher, 1_000 ether); // give the publisher inventory
        vm.stopPrank();
        vm.startPrank(publisher);
        flag.approve(address(dist), type(uint256).max);
        dist.fundAndPublish(SEASON, 100 ether, root, 100 ether);
        vm.stopPrank();
    }

    /* ── claim veto window (a leaked keeper can't drain: owner overrides before claims open) ── */

    function test_claimVetoWindow_blocksUntilDelay_ownerCanOverride() public {
        // Fresh distributor WITH the default 1-day delay, publisher publishes a self-serving root.
        SeasonMerkleDistributor d = new SeasonMerkleDistributor(owner, IERC20(address(flag)), treasury, publisher);
        vm.prank(owner);
        flag.transfer(publisher, 1_000 ether);
        vm.startPrank(publisher);
        flag.approve(address(d), type(uint256).max);
        // A malicious keeper publishes a one-leaf tree paying `attacker` the whole pot.
        bytes32 evil = _leaf(0, address(0xEBAD), 100 ether);
        d.fundAndPublish(SEASON, 100 ether, evil, 100 ether);
        vm.stopPrank();

        // Claims are NOT open yet — the attacker cannot pull the pot inside the veto window.
        vm.expectRevert(SeasonMerkleDistributor.ClaimWindowNotOpen.selector);
        d.claim(SEASON, 0, address(0xEBAD), 100 ether, new bytes32[](0));

        // The cold owner spots it and overrides with the correct root while claimed == 0.
        bytes32 goodRoot = _hashPair(leafA, leafB);
        vm.prank(owner);
        d.adminSetRoot(SEASON, goodRoot, 100 ether);

        // The attacker's leaf no longer verifies; the honest allocation does (after the delay).
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(SeasonMerkleDistributor.InvalidProof.selector);
        d.claim(SEASON, 0, address(0xEBAD), 100 ether, new bytes32[](0));
        d.claim(SEASON, 0, alice, aliceAmt, _proof(leafB));
        assertEq(flag.balanceOf(alice), aliceAmt, "honest claimant paid after the override");
    }

    function test_setClaimDelay_ownerOnly_andCapped() public {
        vm.expectRevert();
        dist.setClaimDelay(1 hours); // not owner
        vm.prank(owner);
        vm.expectRevert(SeasonMerkleDistributor.DelayTooLong.selector);
        dist.setClaimDelay(8 days);
        vm.prank(owner);
        dist.setClaimDelay(2 days);
        assertEq(dist.claimDelay(), 2 days);
    }

    /* ── claim ── */

    function test_claim_transfersAndBlocksDouble() public {
        dist.claim(SEASON, 0, alice, aliceAmt, _proof(leafB));
        assertEq(flag.balanceOf(alice), aliceAmt, "alice paid");
        assertTrue(dist.isClaimed(SEASON, 0));
        assertEq(dist.claimed(SEASON), aliceAmt);

        vm.expectRevert(SeasonMerkleDistributor.AlreadyClaimed.selector);
        dist.claim(SEASON, 0, alice, aliceAmt, _proof(leafB));

        dist.claim(SEASON, 1, bob, bobAmt, _proof(leafA));
        assertEq(flag.balanceOf(bob), bobAmt, "bob paid");
        assertEq(dist.claimed(SEASON), aliceAmt + bobAmt);
    }

    function test_badProofReverts() public {
        vm.expectRevert(SeasonMerkleDistributor.InvalidProof.selector);
        dist.claim(SEASON, 0, alice, aliceAmt + 1, _proof(leafB));
    }

    /* ── fund + publish ── */

    function test_fundAndPublish_setOnce_blocksDoubleFund() public {
        // A retry of the SAME season reverts on set-once — so no double-funding.
        vm.prank(publisher);
        vm.expectRevert(SeasonMerkleDistributor.RootAlreadySet.selector);
        dist.fundAndPublish(SEASON, 100 ether, root, 100 ether);
        assertEq(dist.deposited(SEASON), 100 ether, "deposited not doubled");
    }

    function test_onlyPublisherPublishes() public {
        vm.expectRevert(SeasonMerkleDistributor.NotPublisher.selector);
        dist.fundAndPublish(999, 0, root, 0);
        vm.expectRevert(SeasonMerkleDistributor.NotPublisher.selector);
        dist.setSeasonRoot(999, root, 0);
    }

    function test_rootCappedAtDeposit() public {
        vm.prank(publisher);
        vm.expectRevert(SeasonMerkleDistributor.ExceedsDeposit.selector);
        dist.fundAndPublish(3000, 1 ether, root, 2 ether); // total > deposited
    }

    function test_zeroRootRejected() public {
        // A 0 root would leave the season re-publishable (set-once relies on root != 0).
        vm.prank(publisher);
        vm.expectRevert(SeasonMerkleDistributor.ZeroRoot.selector);
        dist.fundAndPublish(7000, 0, bytes32(0), 0);
    }

    function test_zeroAmountClaimRejected() public {
        // A 0-amount leaf must not be claimable (it would set a bitmap bit without moving
        // `claimed`, defeating the adminSetRoot claim-guard).
        bytes32 zeroLeaf = _leaf(0, alice, 0);
        vm.prank(publisher);
        dist.fundAndPublish(7001, 1 ether, zeroLeaf, 0);
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(SeasonMerkleDistributor.ZeroAmount.selector);
        dist.claim(7001, 0, alice, 0, empty);
    }

    function test_fundSeason_onlyPublisher() public {
        vm.expectRevert(SeasonMerkleDistributor.NotPublisher.selector);
        dist.fundSeason(8000, 1 ether); // caller = test contract, not publisher
    }

    /* ── seasonTotal cap (M3): a bad root can't pay beyond the published total ── */

    function test_perClaimCapBoundsPayoutAtSeasonTotal() public {
        // Season 4000: deposited 100 (dust/over-funded), but published total is only 40.
        // A single leaf claiming 60 must be rejected even though deposited covers it.
        bytes32 soloLeaf = _leaf(0, alice, 60 ether);
        vm.prank(publisher);
        dist.fundAndPublish(4000, 100 ether, soloLeaf, 40 ether);
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(SeasonMerkleDistributor.ExceedsTotal.selector);
        dist.claim(4000, 0, alice, 60 ether, empty);
    }

    /* ── adminSetRoot (H2): only before any claim ── */

    function test_adminSetRoot_blockedAfterClaim() public {
        dist.claim(SEASON, 0, alice, aliceAmt, _proof(leafB)); // a claim happens
        vm.prank(owner);
        vm.expectRevert(SeasonMerkleDistributor.ClaimsStarted.selector);
        dist.adminSetRoot(SEASON, root, 100 ether);
    }

    function test_adminSetRoot_worksBeforeClaim() public {
        // Fund a fresh season without a root, then override before any claim.
        vm.prank(publisher);
        dist.fundSeason(5000, 10 ether);
        bytes32 soloLeaf = _leaf(0, alice, 10 ether);
        vm.prank(owner);
        dist.adminSetRoot(5000, soloLeaf, 10 ether);
        bytes32[] memory empty = new bytes32[](0);
        dist.claim(5000, 0, alice, 10 ether, empty);
        assertEq(flag.balanceOf(alice), 10 ether);
    }

    /* ── rescue: immutable treasury only (M2) ── */

    function test_rescue_onlyOwner_toImmutableTreasury() public {
        vm.expectRevert(); // non-owner
        dist.rescueTokens(address(flag), 1 ether);
        vm.prank(owner);
        dist.rescueTokens(address(flag), 1 ether);
        assertEq(flag.balanceOf(treasury), 1 ether, "rescue always lands at the immutable treasury");
    }

    /* ── rollUnclaimed guards + redistribution (M4) ── */

    function test_rollUnclaimed_guards() public {
        vm.startPrank(owner);
        vm.expectRevert(SeasonMerkleDistributor.SameSeason.selector);
        dist.rollUnclaimed(SEASON, SEASON);
        // dest already published (SEASON has a root) → reverts
        vm.expectRevert(SeasonMerkleDistributor.RootAlreadySet.selector);
        dist.rollUnclaimed(6000, SEASON);
        vm.stopPrank();
    }

    function test_rollUnclaimed_freezesAndRedistributes() public {
        // Alice claims 30; 70 remains in SEASON.
        dist.claim(SEASON, 0, alice, aliceAmt, _proof(leafB));

        uint256 toSeason = SEASON + 5; // unpublished
        vm.prank(owner);
        dist.rollUnclaimed(SEASON, toSeason);
        assertTrue(dist.frozen(SEASON));
        assertEq(dist.deposited(toSeason), 70 ether, "remaining moved to dest");

        // Frozen source can't be claimed.
        vm.expectRevert(SeasonMerkleDistributor.SeasonFrozen.selector);
        dist.claim(SEASON, 1, bob, bobAmt, _proof(leafA));

        // The keeper publishes the dest against its (now 70) deposited — bob gets the roll.
        bytes32 soloLeaf = _leaf(0, bob, 70 ether);
        vm.prank(publisher);
        dist.setSeasonRoot(toSeason, soloLeaf, 70 ether); // fund already present from the roll
        bytes32[] memory empty = new bytes32[](0);
        dist.claim(toSeason, 0, bob, 70 ether, empty);
        assertEq(flag.balanceOf(bob), 70 ether, "rolled funds redistributed, not stranded");
    }

    /* ── fee-on-transfer flagship: deposited credits the real delta (M5) ── */

    function test_feeOnTransfer_creditsMeasuredDelta() public {
        FeeToken fee = new FeeToken();
        SeasonMerkleDistributor d2 = new SeasonMerkleDistributor(owner, IERC20(address(fee)), treasury, publisher);
        vm.prank(owner);
        d2.setClaimDelay(0); // happy-path test, no veto window
        fee.transfer(publisher, 1_000 ether);

        vm.startPrank(publisher);
        fee.approve(address(d2), type(uint256).max);
        // Fund 100 → contract actually receives 99 (1% fee). deposited must be 99, not 100.
        bytes32 soloLeaf = _leaf(0, alice, 99 ether);
        d2.fundAndPublish(1, 100 ether, soloLeaf, 99 ether);
        vm.stopPrank();
        assertEq(d2.deposited(1), 99 ether, "credited the measured delta");

        // The full 99 is claimable (would revert if deposited had recorded a phantom 100).
        bytes32[] memory empty = new bytes32[](0);
        d2.claim(1, 0, alice, 99 ether, empty);
        // alice receives 99 minus the 1% transfer fee out.
        assertEq(fee.balanceOf(alice), 99 ether - (99 ether / 100));
    }
}
