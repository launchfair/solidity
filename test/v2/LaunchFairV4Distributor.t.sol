// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {LaunchFairV4Distributor} from "../../src/v2/v4/LaunchFairV4Distributor.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice End-to-end V4 test of the reward/redistribute/burn buyback: a real
/// PoolManager + token/WETH pool with liquidity, funded WETH -> process() ->
/// swap -> fund/burn. The test contract acts as launchpad (holds supply) + locker.
contract V4DistributorTest is Test, Deployers {
    LaunchFairV4Distributor dist;
    MockToken weth;
    address constant A = address(0xA1);
    address constant B = address(0xB2);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function _deployToken(LaunchTokenV2.Mode mode, address rewardToken, address rewardPool)
        internal
        returns (LaunchTokenV2 t)
    {
        LaunchTokenV2.Metadata memory meta;
        t = new LaunchTokenV2(
            "Tok", "TOK", SUPPLY, "https://hood.launchfair.app", meta, 0, 0, mode, rewardToken, rewardPool, 0, address(this)
        );
    }

    function _pool(address token) internal view returns (PoolKey memory key) {
        (Currency c0, Currency c1) = address(token) < address(weth)
            ? (Currency.wrap(address(token)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(token)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 30_000, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    // Create the token/WETH pool at 1:1, add deep two-sided liquidity, and wire
    // the distributor. Returns the pool key.
    function _setupPoolAndDistributor(LaunchTokenV2 token) internal returns (PoolKey memory key) {
        key = _pool(address(token));
        manager.initialize(key, SQRT_PRICE_1_1);

        weth.mint(address(this), 10_000_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        dist = new LaunchFairV4Distributor(address(this), manager, IERC20(address(weth)), address(this));
        dist.setLocker(address(this));
        dist.registerBuyback(address(token), key);

        // Exclude V4 plumbing so only real holders accrue.
        token.excludeFromDividends(address(manager), true);
        token.excludeFromDividends(address(modifyLiquidityRouter), true);
        token.excludeFromDividends(address(swapRouter), true);
        token.excludeFromDividends(address(dist), true);
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockToken("WETH", "WETH");
    }

    function test_redistribute_buysBackAndDistributes() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Increasing, address(0), address(0));
        _setupPoolAndDistributor(token);
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);
        assertEq(token.totalShares(), 400_000 ether);

        uint256 wethIn = 10 ether;
        weth.mint(address(dist), wethIn);
        dist.notify(address(token), wethIn);

        uint256 out = dist.process(address(token), 0);
        assertGt(out, 0, "bought back token");
        assertEq(token.totalDistributed(), out, "distributed == bought back");

        uint256 wa = token.withdrawableDividendOf(A);
        uint256 wb = token.withdrawableDividendOf(B);
        assertGt(wa, 0, "A accrued");
        assertApproxEqRel(wa, wb * 3, 0.01e18, "A ~3x B");
        assertApproxEqAbs(wa + wb, out, 1000, "all distributed to holders");
    }

    function test_reward_buysExternalTokenAndDistributes() public {
        MockToken reward = new MockToken("Reward", "RWD");
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Reward, address(reward), address(0));

        // reward/WETH V4 pool with liquidity (where the buyback happens).
        PoolKey memory rkey = _pool(address(reward));
        manager.initialize(rkey, SQRT_PRICE_1_1);
        reward.mint(address(this), 1_000_000 ether);
        weth.mint(address(this), 10_000_000 ether);
        reward.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            rkey,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        dist = new LaunchFairV4Distributor(address(this), manager, IERC20(address(weth)), address(this));
        dist.setLocker(address(this));
        dist.registerBuyback(address(token), rkey); // buy the REWARD token here

        token.excludeFromDividends(address(manager), true);
        token.excludeFromDividends(address(modifyLiquidityRouter), true);
        token.excludeFromDividends(address(dist), true);
        token.transfer(A, 300_000 ether);
        token.transfer(B, 100_000 ether);

        uint256 wethIn = 10 ether;
        weth.mint(address(dist), wethIn);
        dist.notify(address(token), wethIn);
        uint256 out = dist.process(address(token), 0);
        assertGt(out, 0, "bought reward token");

        // Holders accrue the REWARD token pro-rata; claim delivers it.
        assertApproxEqRel(token.withdrawableDividendOf(A), token.withdrawableDividendOf(B) * 3, 0.01e18, "A ~3x B");
        vm.prank(A);
        token.claim();
        assertGt(reward.balanceOf(A), 0, "A received the reward token");
        assertEq(reward.balanceOf(address(token)), out - reward.balanceOf(A), "rest still claimable in token");
    }

    function test_burn_buysBackAndBurns() public {
        LaunchTokenV2 token = _deployToken(LaunchTokenV2.Mode.Burn, address(0), address(0));
        _setupPoolAndDistributor(token);
        token.transfer(A, 300_000 ether);

        uint256 supplyBefore = token.totalSupply();
        uint256 wethIn = 10 ether;
        weth.mint(address(dist), wethIn);
        dist.notify(address(token), wethIn);

        uint256 out = dist.process(address(token), 0);
        assertGt(out, 0, "bought back token");
        assertEq(token.totalBurned(), out, "burned == bought back");
        assertEq(token.totalSupply(), supplyBefore - out, "supply reduced");
    }
}
