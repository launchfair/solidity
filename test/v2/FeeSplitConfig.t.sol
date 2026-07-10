// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeSplitConfig} from "../../src/v2/v4/FeeSplitConfig.sol";

contract Harness is FeeSplitConfig {
    function setSideBps(uint24 fee, uint16 side) external {
        _setSideBps(fee, side);
    }
}

contract FeeSplitConfigTest is Test {
    Harness h;

    function setUp() public {
        h = new Harness();
    }

    // treasury == dev at every tier, and the absolute cut matches the spec when
    // the collected fee equals the pool's fee on a 100-unit trade.
    function test_defaults_absoluteCutsMatchSpec() public view {
        // 3% pool: fee on a 100 trade = 3 → treasury/dev 0.5 each, rewards 2.
        (uint256 t, uint256 d, uint256 m) = h.splitOf(h.FEE_3PCT(), 3 ether);
        assertApproxEqAbs(t, 0.5 ether, 1e15, "3%: treasury 0.5");
        assertEq(d, t, "treasury == dev");
        assertApproxEqAbs(m, 2 ether, 1e15, "3%: rewards 2.0");

        // 5% pool: fee = 5 → 0.75 / 0.75 / 3.5.
        (t, d, m) = h.splitOf(h.FEE_5PCT(), 5 ether);
        assertApproxEqAbs(t, 0.75 ether, 1e15, "5%: treasury 0.75");
        assertEq(d, t, "treasury == dev");
        assertApproxEqAbs(m, 3.5 ether, 1e15, "5%: rewards 3.5");

        // 10% pool: fee = 10 → 1 / 1 / 8.
        (t, d, m) = h.splitOf(h.FEE_10PCT(), 10 ether);
        assertApproxEqAbs(t, 1 ether, 1e15, "10%: treasury 1.0");
        assertEq(d, t, "treasury == dev");
        assertApproxEqAbs(m, 8 ether, 1e15, "10%: rewards 8.0");
    }

    function test_splitConservesTotal() public view {
        (uint256 t, uint256 d, uint256 m) = h.splitOf(h.FEE_5PCT(), 123456789);
        assertEq(t + d + m, 123456789, "no wei lost");
    }

    function test_ownerAdjustable() public {
        h.setSideBps(h.FEE_3PCT(), 2_000); // bump each side to 20% of the fee
        (uint256 t, uint256 d, uint256 m) = h.splitOf(h.FEE_3PCT(), 10 ether);
        assertEq(t, 2 ether);
        assertEq(d, 2 ether);
        assertEq(m, 6 ether);
    }

    function test_rejectsUnsupportedFee() public {
        vm.expectRevert(FeeSplitConfig.UnsupportedFee.selector);
        h.splitOf(10_000, 1 ether); // 1% is not a V4 mode-token tier
        vm.expectRevert(FeeSplitConfig.UnsupportedFee.selector);
        h.setSideBps(10_000, 100);
    }

    function test_rejectsMechanismStarvation() public {
        // 2*side must leave the mechanism >= 20% → side <= 4000.
        uint24 fee = h.FEE_3PCT();
        vm.expectRevert(FeeSplitConfig.InvalidSplit.selector);
        h.setSideBps(fee, 4_001);
    }
}
