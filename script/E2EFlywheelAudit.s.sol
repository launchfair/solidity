// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultE2E {
    function carveTeamCut(uint256 amount) external;
    function publishSeason(uint256 season, uint256 amount, bytes32 root, uint256 total) external;
    function teamWallet() external view returns (address);
}

interface IDistE2E {
    function claim(uint256 season, uint256 index, address account, uint256 amount, bytes32[] calldata proof) external;
    function setClaimDelay(uint256 d) external;
    function claimDelay() external view returns (uint256);
}

/// Proves the two audited flywheel HIGH fixes ON CHAIN:
///   1. carveTeamCut pays ONLY the fixed teamWallet (keeper-callable, no destination arg).
///   2. the claim VETO WINDOW blocks a published root until the delay — the cold owner's window to
///      override a keeper's self-serving root — then a claim works once the delay is lifted.
/// Env: VAULT, DIST, CORE [required]; PRIVATE_KEY/TESTER_DEPLOYER_PKEY (owner + keeper).
contract E2EFlywheelAudit is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        address me = vm.addr(pk);
        IVaultE2E vault = IVaultE2E(vm.envAddress("VAULT"));
        IDistE2E dist = IDistE2E(vm.envAddress("DIST"));
        IERC20 core = IERC20(vm.envAddress("CORE"));

        vm.startBroadcast(pk);

        // ── 1. carveTeamCut pays the fixed team wallet ──
        address team = vault.teamWallet();
        uint256 teamBefore = core.balanceOf(team);
        core.transfer(address(vault), 1_000 ether); // fund the vault with test core
        vault.carveTeamCut(50 ether); // keeper carves (<= 20% of 1000)
        require(core.balanceOf(team) - teamBefore == 50 ether, "carveTeamCut did NOT pay the fixed team wallet");
        console2.log("OK carveTeamCut: team wallet received exactly 50e18 (fixed destination)");

        // ── 2. veto window blocks a published root, owner can override ──
        uint256 season = block.timestamp; // unique test season
        uint256 amount = 10 ether;
        core.transfer(address(vault), amount); // fund the season
        // Single-leaf tree paying `me`: root == leaf, proof == [].
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256(0), me, amount))));
        vault.publishSeason(season, amount, leaf, amount);
        console2.log("published season", season, "with claimDelay", dist.claimDelay());

        // Claim must be BLOCKED inside the veto window.
        bytes32[] memory proof = new bytes32[](0);
        bool blocked;
        try dist.claim(season, 0, me, amount, proof) { blocked = false; }
        catch { blocked = true; }
        require(blocked, "VETO WINDOW FAILED: claim succeeded before the delay");
        console2.log("OK veto window: claim BLOCKED inside the delay");

        // The cold owner lifts the delay (in production: adminSetRoot to override a bad root).
        dist.setClaimDelay(0);
        uint256 balBefore = core.balanceOf(me);
        dist.claim(season, 0, me, amount, proof);
        require(core.balanceOf(me) - balBefore == amount, "claim did not pay after the window opened");
        console2.log("OK claim pays once the window is open");

        vm.stopBroadcast();
        console2.log("");
        console2.log("FLYWHEEL AUDIT E2E PASSED: fixed-destination cut + claim veto window, live on chain.");
    }
}
