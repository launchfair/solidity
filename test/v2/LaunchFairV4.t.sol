// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {TokenDeployerV2} from "../../src/v2/TokenDeployerV2.sol";
import {LaunchFairV4} from "../../src/v2/v4/LaunchFairV4.sol";
import {LaunchFairV4FeeLocker} from "../../src/v2/v4/LaunchFairV4FeeLocker.sol";
import {LaunchFairV4Distributor} from "../../src/v2/v4/LaunchFairV4Distributor.sol";

contract MockWethT is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice Capstone: launch a Redistribute token through LaunchFairV4, trade to
/// generate fees, claim, process, and confirm a holder is auto-rewarded — the
/// whole V4 pipeline behind one entry point.
contract LaunchFairV4Test is Test, Deployers {
    MockWethT weth;
    TokenDeployerV2 tokenDeployer;
    LaunchFairV4FeeLocker locker;
    LaunchFairV4Distributor dist;
    LaunchFairV4 pad;

    address constant TREASURY = address(0x7EA);
    address constant HOLDER = address(0xB0B);
    uint128 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockWethT();

        tokenDeployer = new TokenDeployerV2();
        locker = new LaunchFairV4FeeLocker(address(this), manager, IERC20(address(weth)), TREASURY);
        // registrar placeholder = this; repointed to the launchpad below.
        dist = new LaunchFairV4Distributor(address(this), manager, IERC20(address(weth)), address(this));
        pad = new LaunchFairV4(
            address(this), manager, locker, address(dist), tokenDeployer, address(weth),
            SUPPLY, 1e18, int24(200), int24(200), int24(60_000), 0, 0, "https://hood.launchfair.app"
        );

        locker.setLaunchpad(address(pad));
        locker.setDistributor(address(dist));
        dist.setLocker(address(locker));
        dist.setRegistrar(address(pad));

        vm.deal(address(this), 1 ether);
    }

    function _createRedistribute() internal returns (address token, PoolKey memory key) {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Red",
                symbol: "RED",
                metadata: meta,
                salt: bytes32(0),
                mode: LaunchTokenV2.Mode.Increasing, // Redistribute
                fee: 30_000,
                rewardToken: address(0),
                rewardPoolKey: none,
                minHold: 0,
                payoutThreshold: 0
            })
        );
        key = pad.getLaunch(token).key;
    }

    function _buy(PoolKey memory key, address token, uint256 wethIn) internal {
        weth.mint(address(this), wethIn);
        weth.approve(address(swapRouter), wethIn);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(weth);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(wethIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_endToEnd_launch_trade_claim_process_reward() public {
        (address token, PoolKey memory key) = _createRedistribute();

        // Pool exists + liquidity locked (the locker holds the position).
        assertTrue(pad.getLaunch(token).exists, "launched");
        assertEq(pad.creatorOf(token), address(this), "creator recorded");

        // A buyer becomes a holder (buys token, receives it here) + generates WETH fee.
        _buy(key, token, 50_000 ether);
        // Move the freshly-bought tokens to HOLDER so there's a real dividend holder.
        uint256 bought = IERC20(token).balanceOf(address(this));
        assertGt(bought, 0, "bought token");
        IERC20(token).transfer(HOLDER, bought);
        assertEq(LaunchTokenV2(token).totalShares(), bought, "HOLDER is the holder");

        // Claim the buy-side WETH fee -> split -> mechanism to the distributor.
        locker.claim(token);
        uint256 pending = dist.pendingWeth(token);
        assertGt(pending, 0, "mechanism WETH pending");

        // Process -> buy back the token -> distribute to HOLDER.
        uint256 out = dist.process(token, 0);
        assertGt(out, 0, "bought back for rewards");
        assertGt(LaunchTokenV2(token).withdrawableDividendOf(HOLDER), 0, "HOLDER accrued");

        // Auto-push -> reward lands in HOLDER's wallet (no claim).
        uint256 before = IERC20(token).balanceOf(HOLDER);
        address[] memory who = new address[](1);
        who[0] = HOLDER;
        LaunchTokenV2(token).processAccounts(who);
        assertGt(IERC20(token).balanceOf(HOLDER), before, "reward auto-pushed to wallet");
    }
}
