// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchFairV4} from "../src/v2/v4/LaunchFairV4.sol";
import {LaunchTokenV2} from "../src/v2/LaunchTokenV2.sol";

interface IHookDistribute {
    function distribute(address token) external returns (uint256);
    function accrued(address token) external view returns (uint256);
}

/// Proves the re-weighted split feeds the flywheel: launch a Base token, buy it (accruing the WETH
/// fee), then distribute and confirm the buyback VAULT balance rises by ~40% of the fee (a Base
/// token's mechanism folds into the buyback, so buyback = flagship 10% + mechanism 30% = 40%).
/// Env: PAD, HOOK, VAULT, TREASURY [required]; PRIVATE_KEY/TESTER_DEPLOYER_PKEY.
contract E2EFlywheelFeed is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) pk = vm.envUint("TESTER_DEPLOYER_PKEY");
        LaunchFairV4 pad = LaunchFairV4(payable(vm.envAddress("PAD")));
        IHookDistribute hook = IHookDistribute(vm.envAddress("HOOK"));
        address vault = vm.envAddress("VAULT");
        address treasury = vm.envAddress("TREASURY");

        LaunchFairV4.CreateParams memory p;
        p.name = "Flywheel Feed";
        p.symbol = "FEED";
        p.salt = keccak256(abi.encode(block.number, "flywheel-feed-v1"));
        p.mode = LaunchTokenV2.Mode.Base;
        p.fee = 30000; // 3% tier

        uint256 buyWei = 0.002 ether;
        uint256 vaultBefore = vault.balance;
        uint256 treBefore = treasury.balance;

        vm.startBroadcast(pk);
        address token = pad.createAndBuy{value: pad.creationFeeWei() + buyWei}(p, 0);
        uint256 fee = hook.accrued(token);
        hook.distribute(token);
        vm.stopBroadcast();

        uint256 vaultGain = vault.balance - vaultBefore;
        uint256 treGain = treasury.balance - treBefore;
        console2.log("token:           ", token);
        console2.log("fee accrued (wei):", fee);
        console2.log("vault gain (wei): ", vaultGain, "  ~40% expected");
        console2.log("treasury gain:    ", treGain, "   ~10% expected");
        // Base token: buyback (vault) = 40% of the fee; treasury = 10% of the fee PLUS the flat
        // creation fee (which is forwarded to treasury on every launch).
        require(vaultGain == (fee * 4000) / 10_000, "vault did NOT get 40% of the fee");
        require(treGain == (fee * 1000) / 10_000 + pad.creationFeeWei(), "treasury != 10% + creation fee");
        console2.log("");
        console2.log("OK: every Base token now feeds the flywheel vault 40% of its fee.");
    }
}
