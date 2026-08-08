// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReferenceStockPerpVenue} from "../../src/v2/v4/ReferenceStockPerpVenue.sol";
import {PerpPositionToken} from "../../src/v2/v4/PerpPositionToken.sol";

contract MintWETH is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract ReferenceStockPerpVenueTest is Test {
    ReferenceStockPerpVenue venue;
    MintWETH weth;

    bytes32 constant AAPL = keccak256("AAPL");
    bytes32 constant TSLA = keccak256("TSLA");
    address alice = address(0xA11CE);

    function setUp() public {
        weth = new MintWETH();
        venue = new ReferenceStockPerpVenue(address(this), address(weth));
        venue.listMarket(AAPL, "AAPL", 200 ether, true);
        venue.listMarket(TSLA, "TSLA", 100 ether, true);
        venue.setOpener(alice, true); // alice stands in for the fee distributor (only openers can open)
        // House liquidity so positive-PnL redemptions can pay out.
        weth.mint(address(this), 100 ether);
        weth.approve(address(venue), type(uint256).max);
        venue.fundLiquidity(50 ether);
        // Fund alice as the depositor (stands in for the distributor).
        weth.mint(alice, 100 ether);
        vm.prank(alice);
        weth.approve(address(venue), type(uint256).max);
    }

    function test_open_mintsSharesOneToOneAndTakesMargin() public {
        uint256 balBefore = weth.balanceOf(address(venue));
        vm.prank(alice);
        (address tok, uint256 shares) = venue.open(AAPL, true, 30000, 1 ether); // 3x long, 1 WETH
        assertEq(shares, 1 ether, "first deposit mints shares 1:1 with margin");
        assertEq(PerpPositionToken(tok).balanceOf(alice), 1 ether, "alice holds the position token");
        assertEq(weth.balanceOf(address(venue)) - balBefore, 1 ether, "venue took the margin");
        assertEq(venue.shareValue(tok, 1 ether), 1 ether, "at entry, NAV == margin");
    }

    function test_priceUp_growsNAV_andRedeemPaysLeveragedProfit() public {
        vm.prank(alice);
        (address tok,) = venue.open(AAPL, true, 30000, 1 ether); // 3x long
        venue.setMarkPrice(AAPL, 220 ether); // +10% underlying
        // 3x * +10% = +30% -> NAV 1.3
        assertEq(venue.shareValue(tok, 1 ether), 1.3 ether, "3x on +10% = +30% NAV");

        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 out = venue.redeem(tok, 1 ether, 1.29 ether);
        assertEq(out, 1.3 ether, "redeemed at NAV");
        assertEq(weth.balanceOf(alice) - before, 1.3 ether, "alice paid the leveraged profit in WETH");
        assertEq(PerpPositionToken(tok).totalSupply(), 0, "shares burned");
    }

    function test_short_profitsOnPriceDown() public {
        vm.prank(alice);
        (address tok,) = venue.open(TSLA, false, 20000, 1 ether); // 2x short, 1 WETH
        venue.setMarkPrice(TSLA, 90 ether); // -10% underlying
        assertEq(venue.shareValue(tok, 1 ether), 1.2 ether, "2x short on -10% = +20% NAV");
    }

    function test_liquidation_wipesShares_andReopenReverts() public {
        vm.prank(alice);
        (address tok,) = venue.open(AAPL, true, 30000, 1 ether); // 3x long
        venue.setMarkPrice(AAPL, 133 ether); // ~ -33.5% -> 3x wipes the margin
        assertEq(venue.shareValue(tok, 1 ether), 0, "liquidated pool: shares worth 0");

        // With shares still outstanding (supply > 0) but value 0, a fresh deposit reverts — the
        // reference venue refuses to dilution-re-seed a liquidated pool.
        vm.prank(alice);
        vm.expectRevert(ReferenceStockPerpVenue.PoolLiquidated.selector);
        venue.open(AAPL, true, 30000, 1 ether);

        // Redeeming the wiped position burns shares and pays nothing (principal-safe: only fees
        // were ever the margin — no holder principal at stake).
        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 out = venue.redeem(tok, 1 ether, 0);
        assertEq(out, 0, "nothing to redeem from a wiped pool");
        assertEq(weth.balanceOf(alice), before, "no payout");
    }

    function test_marketClosed_blocksOpen() public {
        venue.setMarketOpen(AAPL, false);
        vm.prank(alice);
        vm.expectRevert(ReferenceStockPerpVenue.MarketClosed.selector);
        venue.open(AAPL, true, 30000, 1 ether);
        assertFalse(venue.marketOpen(AAPL));
    }

    function test_positionTokenFor_isIdempotent() public {
        address a = venue.positionTokenFor(AAPL, true, 30000);
        address b = venue.positionTokenFor(AAPL, true, 30000);
        assertEq(a, b, "same (market,side,leverage) -> same token");
        address c = venue.positionTokenFor(AAPL, false, 30000);
        assertTrue(c != a, "different side -> different token");
    }

    // ── audit fixes ────────────────────────────────────────────────────────────────
    // HIGH-1: open is gated to authorized depositors (blocks MEV farming the oracle latency).
    function test_open_onlyAuthorizedOpener() public {
        address bob = address(0xB0B);
        weth.mint(bob, 1 ether);
        vm.startPrank(bob);
        weth.approve(address(venue), type(uint256).max);
        vm.expectRevert(ReferenceStockPerpVenue.NotOpener.selector);
        venue.open(AAPL, true, 30000, 1 ether);
        vm.stopPrank();
    }

    // LOW-1: a sub-NAV-per-share dust deposit is rejected instead of keeping the margin for 0 shares.
    function test_open_rejectsSubNavDust() public {
        vm.prank(alice);
        venue.open(AAPL, true, 30000, 1 ether);
        venue.setMarkPrice(AAPL, 400 ether); // NAV/share now ~4
        vm.prank(alice);
        vm.expectRevert(ReferenceStockPerpVenue.ZeroShares.selector);
        venue.open(AAPL, true, 30000, 3); // 3 wei < NAV/share → would mint 0
    }

    // HIGH-2: a profitable redeem can never be paid out of another pool's collateral — it reverts
    // when the segregated house can't cover the PnL.
    function test_redeem_cannotDrainOtherPoolsCollateral() public {
        venue.withdrawHouse(50 ether, address(this)); // remove all house liquidity
        vm.startPrank(alice);
        (address tokA,) = venue.open(AAPL, true, 30000, 10 ether); // pool A collateral 10
        venue.open(TSLA, false, 20000, 10 ether); // pool B collateral 10; venue holds 20, house 0
        vm.stopPrank();
        venue.setMarkPrice(AAPL, 220 ether); // +10% → 3x → pool A NAV 13; redeem needs 3 from house
        uint256 shares = PerpPositionToken(tokA).balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(ReferenceStockPerpVenue.InsufficientHouse.selector);
        venue.redeem(tokA, shares, 0); // must NOT drain pool B's 10 WETH
    }

    // LOW-7: owner can withdraw the house surplus but never dips into pool collateral.
    function test_withdrawHouse_boundedByHouse() public {
        vm.prank(alice);
        venue.open(AAPL, true, 30000, 5 ether); // 5 WETH pool collateral; house still 50
        venue.withdrawHouse(50 ether, address(this));
        assertEq(venue.houseBalance(), 0);
        vm.expectRevert(); // underflow — can't pull the pool's 5 WETH collateral
        venue.withdrawHouse(1, address(this));
    }
}
