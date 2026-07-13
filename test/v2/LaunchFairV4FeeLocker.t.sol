// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {LaunchFairV4FeeLocker} from "../../src/v2/v4/LaunchFairV4FeeLocker.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockDistributor {
    mapping(address => uint256) public pendingWeth;

    function notify(address token, uint256 amount) external {
        pendingWeth[token] += amount;
    }
}

/// @notice End-to-end V4 fee-locker test: lock single-sided liquidity, generate
/// real buy (WETH) + sell (token) fees via swaps, claim, and verify the buy-WETH
/// split (treasury == dev + mechanism) and the sell-token burn. The test contract
/// is the launchpad (holds supply + implements creatorOf).
contract V4FeeLockerTest is Test, Deployers {
    LaunchFairV4FeeLocker locker;
    MockDistributor dist;
    MockToken weth;
    LaunchTokenV2 token;
    PoolKey poolKey;
    bool tokenIsCurrency0;

    address constant TREASURY = address(0x7EA);
    address constant DEV = address(0xDE7);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function creatorOf(address) external pure returns (address) {
        return DEV;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockToken("WETH", "WETH");

        LaunchTokenV2.Metadata memory meta;
        token = new LaunchTokenV2(
            "Tok", "TOK", SUPPLY, "https://hood.launchfair.app", meta, 0, 0, LaunchTokenV2.Mode.Increasing, new address[](0), new uint16[](0), address(0), 0, address(this)
        );

        tokenIsCurrency0 = address(token) < address(weth);
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(token)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 30_000, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(poolKey, SQRT_PRICE_1_1); // tick 0

        locker = new LaunchFairV4FeeLocker(address(this), manager, IERC20(address(weth)), TREASURY);
        dist = new MockDistributor();
        locker.setLaunchpad(address(this));
        locker.setDistributor(address(dist));

        // Single-sided token position just off tick 0; send the locker the supply
        // it settles from (keep the rest here to sell later).
        (int24 tl, int24 tu) = tokenIsCurrency0 ? (int24(60), int24(60_000)) : (int24(-60_000), int24(-60));
        token.transfer(address(locker), 100_000_000 ether);
        locker.lockLiquidity(address(token), poolKey, tl, tu, 1_000_000 ether, tokenIsCurrency0);
    }

    function _buy(uint256 wethIn) internal {
        weth.mint(address(this), wethIn);
        weth.approve(address(swapRouter), wethIn);
        bool zeroForOne = !tokenIsCurrency0; // WETH is input
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(wethIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(uint256 tokenIn) internal {
        token.approve(address(swapRouter), tokenIn);
        bool zeroForOne = tokenIsCurrency0; // token is input
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_claim_splitsBuyWeth_burnsSellToken() public {
        _buy(50_000 ether); // large buy → deep into the range, WETH fee accrues
        _sell(500 ether); // sell pulls WETH back, token fee accrues

        uint256 supplyBefore = token.totalSupply();
        (uint256 burned, uint256 t, uint256 d, uint256 mech) = locker.claim(address(token));

        // Buy-side WETH split (3% tier): treasury == dev, mechanism ~4x each side.
        assertGt(t, 0, "treasury got WETH");
        assertEq(t, d, "treasury == dev");
        assertEq(weth.balanceOf(TREASURY), t, "treasury paid in WETH");
        assertEq(weth.balanceOf(DEV), d, "dev paid in WETH");
        assertApproxEqRel(mech, t * 4, 0.02e18, "mechanism ~4x each side (66.66/16.67)");
        assertEq(dist.pendingWeth(address(token)), mech, "mechanism routed to distributor");

        // Sell-side token fee burned.
        assertGt(burned, 0, "sell-side token fee burned");
        assertEq(token.totalSupply(), supplyBefore - burned, "supply reduced by the burn");
    }
}
