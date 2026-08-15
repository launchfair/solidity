// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FlagshipSink} from "../../src/flywheel/FlagshipSink.sol";

contract Rejector {
    receive() external payable {
        revert("no");
    }
}

contract FlagshipSinkTest is Test {
    FlagshipSink sink;
    address constant OWNER = address(0x0001);
    address constant KEEPER = address(0x0002);
    address constant CORETGE = address(0xC0DE);
    address constant VAULT = address(0x7A017);

    function setUp() public {
        sink = new FlagshipSink(OWNER);
    }

    // The core property: fees hoard while there's no target (no CoreTGE yet), never reverting.
    function test_hoardsWithoutTarget() public {
        (bool ok,) = address(sink).call{value: 3 ether}("");
        assertTrue(ok, "receive accepts fees");
        assertEq(address(sink).balance, 3 ether, "fees hoard");
        // A sweep with no target set is refused (nothing to sweep to yet).
        vm.prank(OWNER);
        vm.expectRevert(FlagshipSink.TargetUnset.selector);
        sink.sweep();
    }

    // Lifecycle: hoard -> target = CoreTGE, sweep the seed -> target = vault, sweep ongoing.
    function test_lifecycle_coretgeThenVault() public {
        vm.deal(address(sink), 5 ether); // accumulated hoard

        vm.prank(OWNER);
        sink.setTarget(CORETGE);
        vm.prank(OWNER);
        uint256 swept = sink.sweep();
        assertEq(swept, 5 ether, "swept the whole hoard");
        assertEq(CORETGE.balance, 5 ether, "CoreTGE got the seed");
        assertEq(address(sink).balance, 0, "sink drained");

        // More fees arrive, now routed to the vault.
        vm.deal(address(sink), 2 ether);
        vm.prank(OWNER);
        sink.setTarget(VAULT);
        vm.prank(OWNER);
        sink.sweep();
        assertEq(VAULT.balance, 2 ether, "vault got the ongoing fees");
    }

    // The keeper can sweep (to the fixed target only), a stranger cannot.
    function test_keeperCanSweep_strangerCannot() public {
        vm.deal(address(sink), 1 ether);
        vm.prank(OWNER);
        sink.setTarget(VAULT);
        vm.prank(OWNER);
        sink.setKeeper(KEEPER, true);

        vm.prank(address(0xBAD));
        vm.expectRevert(FlagshipSink.NotAuthorized.selector);
        sink.sweep();

        vm.prank(KEEPER);
        sink.sweep();
        assertEq(VAULT.balance, 1 ether, "keeper swept to the fixed target");
    }

    function test_onlyOwnerConfig() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        sink.setTarget(VAULT);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        sink.setKeeper(KEEPER, true);
    }

    // Escape hatch: even if the target rejects ETH, the owner can recover the hoard.
    function test_withdrawEscapeHatch() public {
        Rejector bad = new Rejector();
        vm.deal(address(sink), 4 ether);
        vm.prank(OWNER);
        sink.setTarget(address(bad));
        vm.prank(OWNER);
        vm.expectRevert(FlagshipSink.EthTransferFailed.selector);
        sink.sweep(); // target rejects -> reverts, funds stay

        vm.prank(OWNER);
        sink.withdraw(OWNER, 4 ether);
        assertEq(OWNER.balance, 4 ether, "owner recovered the hoard");
    }
}
