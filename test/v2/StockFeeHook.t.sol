// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StockFeeHook} from "../../src/v2/v4/StockFeeHook.sol";
import {IV3SwapRouter, IUniswapV3Factory} from "../../src/interfaces/IUniswapV3.sol";
import {HookMockToken} from "./WethFeeHook.t.sol";

/// Launchpad view mock: one allowed stock quote, a direct-hop fee tier, a token creator.
contract MockStockLaunchpad {
    mapping(address => bool) public allowedQuote;
    mapping(address => uint24) public quoteV3Fee;
    mapping(address => address) public creatorOf;

    function setQuote(address stock, bool ok, uint24 fee) external {
        allowedQuote[stock] = ok;
        quoteV3Fee[stock] = fee;
    }

    function setCreator(address token, address dev) external {
        creatorOf[token] = dev;
    }
}

/// StockPairRouter view mock: just the sell path the hook reuses.
contract MockStockRoutes {
    mapping(address => bytes) public sellPathOf;

    function setSellPath(address stock, bytes calldata path) external {
        sellPathOf[stock] = path;
    }
}

/// V3 SwapRouter02 mock: converts at `rateBps` (default 1:1), honors amountOutMinimum.
contract MockV3ConvRouter {
    error Slippage();

    uint256 public rateBps = 10_000; // out = in × rateBps / 10000

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p) external payable returns (uint256) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256 out = (p.amountIn * rateBps) / 10_000;
        if (out < p.amountOutMinimum) revert Slippage();
        IERC20(p.tokenOut).transfer(p.recipient, out);
        return out;
    }

    function exactInput(IV3SwapRouter.ExactInputParams calldata p) external payable returns (uint256) {
        // path = tokenIn(20) ++ fee(3) ++ ... ++ tokenOut(last 20)
        address tokenIn = address(bytes20(p.path[0:20]));
        address tokenOut = address(bytes20(p.path[p.path.length - 20:]));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256 out = (p.amountIn * rateBps) / 10_000;
        if (out < p.amountOutMinimum) revert Slippage();
        IERC20(tokenOut).transfer(p.recipient, out);
        return out;
    }
}

/// Minimal V3 factory + pool pair for the claimFees floor: slot0 at a fixed sqrtPriceX96.
contract MockSpotPool {
    uint160 public sqrtP;

    constructor(uint160 s) {
        sqrtP = s;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtP, 0, 0, 0, 0, 0, true);
    }
}

contract MockSpotFactory {
    mapping(bytes32 => address) internal _pools;

    function set(address a, address b, uint24 fee, address pool) external {
        (address x, address y) = a < b ? (a, b) : (b, a);
        _pools[keccak256(abi.encode(x, y, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return _pools[keccak256(abi.encode(x, y, fee))];
    }
}

contract StockFeeHookTest is Test, Deployers {
    StockFeeHook hook;
    HookMockToken weth;
    HookMockToken stock; // the quote (e.g. NVDA)
    HookMockToken token; // the launch token
    MockStockLaunchpad pad;
    MockStockRoutes routes;
    MockV3ConvRouter conv;
    PoolKey poolKey;
    bool tokenIsCurrency0;

    address constant TREASURY = address(0x7EA);
    address constant FLAGSHIP = address(0xF1A);
    address constant DEV = address(0xDE4);
    uint16 constant FEE_BPS = 100; // 1% of the stock leg

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new HookMockToken("WETH", "WETH");
        vm.deal(address(weth), 10_000 ether);
        stock = new HookMockToken("NVDA", "NVDA");
        token = new HookMockToken("TOK", "TOK");
        token.mint(address(this), 1_000_000_000 ether);
        stock.mint(address(this), 10_000_000 ether);

        pad = new MockStockLaunchpad();
        pad.setQuote(address(stock), true, 3000);
        pad.setCreator(address(token), DEV);
        routes = new MockStockRoutes();
        conv = new MockV3ConvRouter();
        weth.mint(address(conv), 1_000_000 ether); // 1:1 conversion inventory

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x5555) << 144));
        deployCodeTo(
            "StockFeeHook.sol:StockFeeHook",
            abi.encode(address(this), manager, address(weth), address(conv), address(pad), address(routes), FEE_BPS),
            hookAddr
        );
        hook = StockFeeHook(payable(hookAddr));
        hook.setDestinations(TREASURY, FLAGSHIP);

        tokenIsCurrency0 = address(token) < address(stock);
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(token)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddr)});
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        stock.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ""
        );
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ── the point of the change: ANY router can swap (the PoolSwapTest router is not ours) ──
    function test_openAccess_anyRouterCanBuy_feeTakenInStock() public {
        uint256 stockIn = 100 ether;
        stock.approve(address(swapRouter), stockIn);
        _swap(!tokenIsCurrency0, stockIn); // stock in -> token out, via a foreign router
        assertEq(hook.accrued(address(token)), (stockIn * FEE_BPS) / 10_000, "1% of the stock input accrued");
        assertEq(hook.quoteOf(address(token)), address(stock), "quote side cached");
    }

    function test_sell_takesStockFeeFromOutput_noTokenTaken() public {
        uint256 tokenIn = 10_000 ether;
        token.approve(address(swapRouter), tokenIn);
        uint256 hookTokBefore = token.balanceOf(address(hook));
        _swap(tokenIsCurrency0, tokenIn); // token in -> stock out
        assertGt(hook.accrued(address(token)), 0, "stock fee accrued on the sell");
        assertEq(token.balanceOf(address(hook)), hookTokBefore, "hook took NO launch token");
    }

    function test_exactOutputSell_swapperGetsExactStock() public {
        uint256 stockOut = 1 ether;
        token.approve(address(swapRouter), type(uint256).max);
        uint256 myStockBefore = stock.balanceOf(address(this));
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: tokenIsCurrency0,
                amountSpecified: int256(stockOut),
                sqrtPriceLimitX96: tokenIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(stock.balanceOf(address(this)) - myStockBefore, stockOut, "got EXACTLY the requested stock");
        assertEq(hook.accrued(address(token)), (stockOut * FEE_BPS) / 10_000, "fee = feeBps of the stock out");
    }

    function test_nonStockPool_swapsFreely_noFee() public {
        // A pool where neither side is an allowed quote: swap proceeds, nothing accrues.
        HookMockToken other = new HookMockToken("OTH", "OTH");
        other.mint(address(this), 1_000_000 ether);
        (Currency c0, Currency c1) = address(token) < address(other)
            ? (Currency.wrap(address(token)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(token)));
        PoolKey memory k = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: poolKey.hooks});
        manager.initialize(k, SQRT_PRICE_1_1);
        other.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000 ether, salt: bytes32(0)}),
            ""
        );
        other.approve(address(swapRouter), 1 ether);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: Currency.unwrap(c0) == address(other),
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: Currency.unwrap(c0) == address(other) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.accrued(address(token)), 0, "no fee on a non-stock pool");
    }

    function test_quoteCache_survivesAllowListFlip() public {
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 1 ether); // first swap resolves + caches the quote
        uint256 first = hook.accrued(address(token));
        pad.setQuote(address(stock), false, 0); // un-allow the stock afterwards
        _swap(!tokenIsCurrency0, 1 ether);
        assertEq(hook.accrued(address(token)) - first, first, "fee STILL charged from the cache");
    }

    function test_distribute_directHop_splitsEth() public {
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 100 ether);
        uint256 acc = hook.accrued(address(token));
        assertGt(acc, 0);

        uint256 out = hook.distribute(address(token), acc); // 1:1 mock ⇒ minOut == out is fine
        assertEq(out, acc, "1:1 conversion");
        assertEq(hook.accrued(address(token)), 0, "accrual cleared");
        // 25/25/40/10: dev is the token creator; mechanism folds into flagship (Base-only).
        assertEq(TREASURY.balance, (acc * 2500) / 10_000, "treasury 25%");
        assertEq(DEV.balance, (acc * 2500) / 10_000, "creator dev 25%");
        assertEq(FLAGSHIP.balance, acc - (acc * 2500) / 10_000 * 2, "flagship 50% (mechanism folded)");
    }

    function test_distribute_multiHopPath() public {
        HookMockToken usdg = new HookMockToken("USDG", "USDG");
        routes.setSellPath(
            address(stock), abi.encodePacked(address(stock), uint24(3000), address(usdg), uint24(100), address(weth))
        );
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 10 ether);
        uint256 acc = hook.accrued(address(token));
        uint256 out = hook.distribute(address(token), 0);
        assertEq(out, acc, "converted along the router's multi-hop path");
    }

    function test_distribute_minOutGuardsSandwich() public {
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 10 ether);
        uint256 acc = hook.accrued(address(token));
        vm.expectRevert(MockV3ConvRouter.Slippage.selector);
        hook.distribute(address(token), acc + 1); // demands more than the conversion yields
        assertEq(hook.accrued(address(token)), acc, "revert unwound the accrual too");
    }

    function test_distribute_strictlyOwnerOrTreasury_neverCreator() public {
        vm.prank(address(0xbad));
        vm.expectRevert(StockFeeHook.NotAuthorized.selector);
        hook.distribute(address(token), 0);

        // Platform policy: the token's CREATOR can NEVER trigger/pull a distribution —
        // their share is pushed when the platform (owner/treasury) distributes.
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 10 ether);
        vm.prank(DEV); // creatorOf(token) == DEV in the mock launchpad
        vm.expectRevert(StockFeeHook.NotAuthorized.selector);
        hook.distribute(address(token), 0);

        // Owner distributes → the creator's share arrives without them doing anything.
        uint256 out = hook.distribute(address(token), 0);
        assertGt(out, 0);
        assertGt(DEV.balance, 0, "creator share was PUSHED on platform distribution");
    }

    /// A second pool pairing the SAME token against a DIFFERENT stock must not repoint the
    /// token's redemption currency — the accrual is a scalar but the fees are that pool's claims,
    /// so repointing would strand them or burn another token's claims.
    function test_quoteIsWriteOnce_secondPoolCannotRepoint() public {
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 10 ether);
        assertEq(hook.quoteOf(address(token)), address(stock), "first pool set the quote");
        uint256 accBefore = hook.accrued(address(token));

        // A second allowed quote, and an attacker-made pool for the same token.
        HookMockToken other = new HookMockToken("TSLA", "TSLA");
        other.mint(address(this), 1_000_000 ether);
        pad.setQuote(address(other), true, 3000);
        (Currency a0, Currency a1) = address(token) < address(other)
            ? (Currency.wrap(address(token)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(token)));
        PoolKey memory k2 = PoolKey({currency0: a0, currency1: a1, fee: 0, tickSpacing: 60, hooks: poolKey.hooks});
        manager.initialize(k2, SQRT_PRICE_1_1);
        other.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            k2,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 10_000 ether, salt: bytes32(0)}),
            ""
        );
        other.approve(address(swapRouter), type(uint256).max);
        bool otherIsC0 = Currency.unwrap(k2.currency0) == address(other);
        swapRouter.swap(
            k2,
            IPoolManager.SwapParams({
                zeroForOne: otherIsC0,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: otherIsC0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(hook.quoteOf(address(token)), address(stock), "quote NOT repointed by the second pool");
        assertEq(hook.accrued(address(token)), accBefore, "second pool accrued nothing");
    }

    /// Pools for tokens this launchpad never created must not enter the fee books at all.
    function test_foreignTokenPoolAccruesNothing() public {
        HookMockToken foreign = new HookMockToken("FRGN", "FRGN");
        foreign.mint(address(this), 1_000_000 ether);
        // pad.creatorOf(foreign) == 0 (never launched here)
        (Currency c0, Currency c1) = address(foreign) < address(stock)
            ? (Currency.wrap(address(foreign)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(foreign)));
        PoolKey memory k = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: poolKey.hooks});
        manager.initialize(k, SQRT_PRICE_1_1);
        foreign.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 10_000 ether, salt: bytes32(0)}),
            ""
        );
        stock.approve(address(swapRouter), type(uint256).max);
        bool stockIsC0 = Currency.unwrap(k.currency0) == address(stock);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: stockIsC0,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: stockIsC0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.accrued(address(foreign)), 0, "no accrual for a token we did not launch");
        assertEq(hook.quoteOf(address(foreign)), address(0), "no quote recorded");
    }

    /// A creator that rejects ETH must not freeze the treasury's and flagship's shares too.
    function test_creatorRejectingEth_reroutesInsteadOfStranding() public {
        RejectsEth badDev = new RejectsEth();
        HookMockToken t2 = new HookMockToken("BAD", "BAD");
        t2.mint(address(this), 1_000_000_000 ether);
        pad.setCreator(address(t2), address(badDev));
        (Currency c0, Currency c1) = address(t2) < address(stock)
            ? (Currency.wrap(address(t2)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(t2)));
        PoolKey memory k = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: poolKey.hooks});
        manager.initialize(k, SQRT_PRICE_1_1);
        t2.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ""
        );
        stock.approve(address(swapRouter), type(uint256).max);
        bool stockIsC0 = Currency.unwrap(k.currency0) == address(stock);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: stockIsC0,
                amountSpecified: -int256(50 ether),
                sqrtPriceLimitX96: stockIsC0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(hook.accrued(address(t2)), 0);
        uint256 treasBefore = TREASURY.balance;
        uint256 out = hook.distribute(address(t2), 0); // must NOT revert
        assertGt(out, 0, "distribution completed despite the creator rejecting ETH");
        assertGt(TREASURY.balance - treasBefore, (out * 2500) / 10_000, "dev share rerouted to treasury");
    }

    function test_feeCap_andSplitSum() public {
        uint16 cap = hook.MAX_FEE_BPS();
        vm.expectRevert(StockFeeHook.InvalidFeeBps.selector);
        hook.setFeeBps(cap + 1);
        vm.expectRevert(StockFeeHook.InvalidSplit.selector);
        hook.setSplit(3000, 3000, 3000, 3000);
    }

    /// The permissionless claim: ANYONE (the creator pressing the site's button) can trigger the
    /// conversion + split — shares always land at their fixed recipients, and the on-chain floor
    /// (chained pool spots × (1 − slippage)) makes the open access sandwich-proof.
    function test_claimFees_permissionless_paysDevHisShare() public {
        MockSpotFactory f = new MockSpotFactory();
        f.set(address(stock), address(weth), 3000, address(new MockSpotPool(uint160(1) << 96))); // 1:1 raw spot
        hook.setClaimConfig(IUniswapV3Factory(address(f)), 300);

        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 100 ether);
        uint256 acc = hook.accrued(address(token));
        assertGt(acc, 0);

        vm.prank(DEV); // the creator himself — no owner/treasury involved
        uint256 out = hook.claimFees(address(token));
        assertEq(out, acc, "1:1 conversion cleared the self-quoted floor");
        assertEq(DEV.balance, (acc * 2500) / 10_000, "creator share PAID on his own claim");
        assertEq(TREASURY.balance, (acc * 2500) / 10_000, "treasury share paid too");
        assertEq(hook.accrued(address(token)), 0, "accrual cleared");
    }

    /// A rigged conversion (sandwich) must revert against the self-quoted floor.
    function test_claimFees_floorBlocksRiggedConversion() public {
        MockSpotFactory f = new MockSpotFactory();
        f.set(address(stock), address(weth), 3000, address(new MockSpotPool(uint160(1) << 96)));
        hook.setClaimConfig(IUniswapV3Factory(address(f)), 300);

        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 10 ether);
        conv.setRate(9_000); // conversion suddenly pays 10% under spot — sandwich territory
        vm.prank(DEV);
        vm.expectRevert(MockV3ConvRouter.Slippage.selector);
        hook.claimFees(address(token));
        assertGt(hook.accrued(address(token)), 0, "revert unwound, nothing lost");
    }

    function test_claimFees_disabledUntilConfigured() public {
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 1 ether);
        vm.expectRevert(StockFeeHook.NotConfigured.selector);
        hook.claimFees(address(token));
    }

    /// MODE stock tokens (Reward/Lottery): the mechanism slice must reach the DISTRIBUTOR in
    /// WETH with a notify() credit (like the V4 locker's WETH-pair flow), NOT fold to flagship.
    /// Base tokens (mode 0 / no mode getter) keep the fold — asserted by every test above, which
    /// runs on a mode-less HookMockToken with the distributor unset.
    function test_distribute_modeToken_mechanismToDistributor() public {
        MockModeToken mtok = new MockModeToken("RWD", "RWD");
        mtok.mint(address(this), 1_000_000_000 ether);
        pad.setCreator(address(mtok), DEV);
        MockDistNotify mdist = new MockDistNotify();
        hook.setDistributor(address(mdist));

        (Currency c0, Currency c1) = address(mtok) < address(stock)
            ? (Currency.wrap(address(mtok)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(mtok)));
        PoolKey memory k = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: poolKey.hooks});
        manager.initialize(k, SQRT_PRICE_1_1);
        mtok.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ""
        );

        stock.approve(address(swapRouter), type(uint256).max);
        bool stockIsC0 = Currency.unwrap(k.currency0) == address(stock);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: stockIsC0,
                amountSpecified: -int256(100 ether),
                sqrtPriceLimitX96: stockIsC0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 acc = hook.accrued(address(mtok));
        assertGt(acc, 0);

        uint256 flagshipBefore = FLAGSHIP.balance;
        uint256 out = hook.distribute(address(mtok), 0);
        uint256 mech = (out * 4000) / 10_000;
        assertEq(weth.balanceOf(address(mdist)), mech, "mechanism 40% arrived at the distributor IN WETH");
        assertEq(mdist.notifiedToken(), address(mtok), "notify() credited the right token");
        assertEq(mdist.notifiedAmount(), mech, "notify() amount matches the WETH sent");
        assertEq(FLAGSHIP.balance - flagshipBefore, out - (out * 2500) / 10_000 * 2 - mech, "flagship keeps only its own 10% + dust");
    }
}

/// Refuses every incoming ETH transfer — stands in for a creator address that can't receive.
contract RejectsEth {
    receive() external payable {
        revert("nope");
    }
}

/// A launch token that reports a non-Base mode (1 = Reward).
contract MockModeToken is HookMockToken {
    constructor(string memory n, string memory s) HookMockToken(n, s) {}
    function mode() external pure returns (uint8) {
        return 1;
    }
}

/// Distributor stand-in: records the notify() credit; WETH arrives via plain transfer.
contract MockDistNotify {
    address public notifiedToken;
    uint256 public notifiedAmount;
    function notify(address token, uint256 amount) external {
        notifiedToken = token;
        notifiedAmount = amount;
    }
}
