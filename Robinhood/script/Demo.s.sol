// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {V3Launchpad} from "../src/V3Launchpad.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IUniswapV3Factory, INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockV3Factory, MockV3Pool, MockPositionManager} from "../test/mocks/MockUniswapV3.sol";

/// Self-contained lifecycle demo for a local node (anvil): deploy (with V3
/// mocks) -> launch a token into its pool -> simulate accrued swap fees ->
/// claim (WETH split 50/50, token fees burned) -> graduation milestone.
contract Demo is Script {
    uint256 constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", ANVIL_KEY_0);
        address dev = vm.addr(pk);
        vm.startBroadcast(pk);

        MockWETH weth = new MockWETH();
        MockV3Factory factory = new MockV3Factory();
        MockPositionManager pm = new MockPositionManager();
        address treasury = vm.envOr("TREASURY", address(0xdeAD0000000000000000000000000000DEad0001));

        FeeLocker locker = new FeeLocker(dev, INonfungiblePositionManager(address(pm)), IERC20(address(weth)), treasury);
        V3Launchpad pad = new V3Launchpad(
            dev,
            IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(pm)),
            locker,
            address(weth),
            V3Launchpad.PoolConfig({
                feeTier: 10_000,
                tickLower0: -203_200,
                tickUpper0: 887_200,
                tokenTotalSupply: 1_000_000_000 ether,
                initialPriceWethPerToken: 1_491_146_318,
                graduationPriceWethPerToken: 15 * 1_491_146_318,
                maxBuyBps: 200,
                maxBuyBlocks: 360
            }),
            "https://fun.example.xyz"
        );
        locker.setLaunchpad(address(pad));

        address token = pad.createToken{value: 0.000005 ether}(
            "Demo Token",
            "DEMO",
            LaunchToken.Metadata({
                logoURI: "ipfs://QmDemoLogo",
                website: "https://demotoken.xyz",
                telegram: "https://t.me/demotoken",
                discord: "https://discord.gg/demotoken",
                twitter: "https://x.com/demotoken"
            }),
            bytes32(0)
        );
        V3Launchpad.LaunchInfo memory info = pad.getLaunch(token);
        console2.log("Token launched:", token);
        console2.log("  pool (tradeable from block one):", info.pool);
        console2.log("  LP NFT locked in FeeLocker, id:", info.positionTokenId);
        console2.log("  contractURI:", LaunchToken(token).contractURI());

        // Simulate accrued pool fees: 2 WETH from buys + 5M tokens from sells.
        weth.deposit{value: 2 ether}();
        weth.transfer(address(pm), 2 ether);
        pm.setCollectable(
            info.positionTokenId,
            info.tokenIsToken0 ? 5_000_000 ether : 2 ether,
            info.tokenIsToken0 ? 2 ether : 5_000_000 ether
        );
        uint256 supplyBefore = IERC20(token).totalSupply();
        (uint256 toTreasury, uint256 toDev, uint256 burned) = locker.claim(token);
        console2.log("Fees claimed:");
        console2.log("  WETH -> treasury (50%):", toTreasury);
        console2.log("  WETH -> dev      (50%):", toDev);
        console2.log("  token fees burned:", burned / 1e18);
        console2.log("  supply after burn:", IERC20(token).totalSupply() / 1e18);
        require(IERC20(token).totalSupply() == supplyBefore - burned, "burn accounting");

        // Market pumps past the milestone (16x launch) -> anyone can flag graduation.
        console2.log("Curve progress (bps):", pad.curveProgress(token));
        uint256 pumped = 16 * 1_491_146_318;
        uint256 ratioX192 =
            info.tokenIsToken0 ? Math.mulDiv(pumped, 1 << 192, 1e18) : Math.mulDiv(1e18, 1 << 192, pumped);
        MockV3Pool(info.pool).setSqrtPriceX96(uint160(Math.sqrt(ratioX192)));
        console2.log("Curve progress after pump (bps):", pad.curveProgress(token));
        pad.checkGraduation(token);
        console2.log("Graduated (cosmetic milestone):", pad.getLaunch(token).graduated);

        vm.stopBroadcast();
    }
}
