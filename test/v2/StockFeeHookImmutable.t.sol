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
import {StockFeeHookImmutable} from "../../src/v2/v4/StockFeeHookImmutable.sol";
import {IV3SwapRouter, IUniswapV3Factory} from "../../src/interfaces/IUniswapV3.sol";
import {HookMockToken} from "./WethFeeHook.t.sol";
import {
    MockStockLaunchpad,
    MockStockRoutes,
    MockV3ConvRouter,
    MockSpotPool,
    MockSpotFactory,
    MockModeToken,
    MockDistNotify
} from "./StockFeeHook.t.sol";

/// Covers what differs from the mutable StockFeeHook (whose shared swap/convert/gating logic is
/// tested in StockFeeHook.t.sol): the flat 50/30/10/10 split, no admin surface, config baked in at
/// construction, and the permissionless-only claim.
contract StockFeeHookImmutableTest is Test, Deployers {
    StockFeeHookImmutable hook;
    HookMockToken weth;
    HookMockToken stock;
    HookMockToken token;
    MockStockLaunchpad pad;
    MockStockRoutes routes;
    MockV3ConvRouter conv;
    MockSpotFactory floorFactory;
    MockDistNotify dist;
    PoolKey poolKey;
    bool tokenIsCurrency0;

    address constant TREASURY = address(0x7EA);
    address constant FLAGSHIP = address(0xF1A);
    address constant DEV = address(0xDE4);
    uint16 constant FEE_BPS = 100;

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
        dist = new MockDistNotify();
        floorFactory = new MockSpotFactory();
        floorFactory.set(address(stock), address(weth), 3000, address(new MockSpotPool(uint160(1) << 96))); // 1:1 spot

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x6666) << 144));
        // All config baked into the constructor: no setters exist afterward.
        deployCodeTo(
            "StockFeeHookImmutable.sol:StockFeeHookImmutable",
            abi.encode(
                manager,
                address(weth),
                address(conv),
                address(pad),
                address(routes),
                FEE_BPS,
                TREASURY,
                address(dist),
                FLAGSHIP,
                IUniswapV3Factory(address(floorFactory)),
                uint16(300)
            ),
            hookAddr
        );
        hook = StockFeeHookImmutable(payable(hookAddr));

        tokenIsCurrency0 = address(token) < address(stock);
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(token)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddr)});
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        pad.setLaunchPool(address(token), poolKey, address(stock));
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

    function test_configIsImmutable() public view {
        assertEq(hook.feeBps(), FEE_BPS);
        assertEq(hook.treasury(), TREASURY);
        assertEq(hook.flagshipSink(), FLAGSHIP);
        assertEq(hook.distributor(), address(dist));
        assertEq(hook.BASE_FEE_BPS(), 100, "1% base");
        assertEq(hook.DEV_TRADE_BPS(), 40, "dev 0.4% of trade, flat");
        assertEq(hook.BUYBACK_TRADE_BPS(), 20, "buyback 0.2% of trade, flat");
        assertEq(hook.TREASURY_BASE_TRADE_BPS(), 10, "treasury 0.1% base, flat");
        assertEq(hook.TREASURY_NOTCH_BPS(), 200, "+2% of the fee-above-1%");
        assertEq(hook.claimSlippageBps(), 300);
    }

    function test_noAdminSetters() public {
        (bool a,) = address(hook).call(abi.encodeWithSignature("setFeeBps(uint16)", uint16(500)));
        assertFalse(a, "no setFeeBps");
        (bool b,) = address(hook).call(
            abi.encodeWithSignature("setSplit(uint16,uint16,uint16,uint16)", uint16(1000), uint16(5000), uint16(3000), uint16(1000))
        );
        assertFalse(b, "no setSplit");
        (bool c,) = address(hook).call(abi.encodeWithSignature("setDestinations(address,address)", TREASURY, FLAGSHIP));
        assertFalse(c, "no setDestinations");
        (bool d,) = address(hook).call(abi.encodeWithSignature("setDistributor(address)", address(dist)));
        assertFalse(d, "no setDistributor");
        (bool e,) = address(hook).call(abi.encodeWithSignature("setClaimConfig(address,uint16)", address(floorFactory), uint16(300)));
        assertFalse(e, "no setClaimConfig");
        (bool f,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(f, "ownerless");
    }

    function test_buy_takesStockFee() public {
        uint256 stockIn = 100 ether;
        stock.approve(address(swapRouter), stockIn);
        _swap(!tokenIsCurrency0, stockIn);
        assertEq(hook.accrued(address(token)), (stockIn * FEE_BPS) / 10_000, "1% of stock input");
    }

    // Base stock token, flat take at the 1% stock fee: dev 40 / treasury 10 / buyback 20 / protocol
    // 30 (% of out). No mechanism, so protocol folds into the buyback -> buyback gets 50%.
    function test_claimFees_baseFlatSplit_buybackGets50() public {
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 100 ether);
        uint256 acc = hook.accrued(address(token));
        assertGt(acc, 0);

        vm.prank(DEV); // permissionless: the creator triggers it
        uint256 out = hook.claimFees(address(token));
        assertEq(out, acc, "1:1 conversion");
        assertEq(TREASURY.balance, (out * 10) / 100, "treasury 10% of out");
        assertEq(DEV.balance, (out * 40) / 100, "dev 40% of out");
        assertEq(FLAGSHIP.balance, out - (out * 10) / 100 - (out * 40) / 100, "buyback 50% (20 flat + folded 30 protocol)");
        assertEq(hook.accrued(address(token)), 0, "accrual cleared");
    }

    // Mode stock token: the 30% protocol slice goes to the distributor in WETH, buyback keeps 20%.
    function test_claimFees_modeToken_protocol30_buyback20() public {
        MockModeToken mtok = new MockModeToken("RWD", "RWD");
        mtok.mint(address(this), 1_000_000_000 ether);
        pad.setCreator(address(mtok), DEV);

        (Currency c0, Currency c1) = address(mtok) < address(stock)
            ? (Currency.wrap(address(mtok)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(mtok)));
        PoolKey memory k = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: poolKey.hooks});
        manager.initialize(k, SQRT_PRICE_1_1);
        pad.setLaunchPool(address(mtok), k, address(stock));
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

        uint256 flagBefore = FLAGSHIP.balance;
        vm.prank(DEV);
        uint256 out = hook.claimFees(address(mtok));
        uint256 mech = (out * 30) / 100; // the scaling protocol slice (30% of out at the 1% stock fee)
        assertEq(weth.balanceOf(address(dist)), mech, "protocol 30% to distributor in WETH");
        assertEq(dist.notifiedAmount(), mech, "notify amount matches");
        assertEq(FLAGSHIP.balance - flagBefore, (out * 20) / 100, "buyback keeps its flat 20%");
    }

    // The self-quoted floor still blocks a rigged conversion, even with no owner.
    function test_floorBlocksRiggedConversion() public {
        stock.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 10 ether);
        conv.setRate(9_000); // conversion pays 10% under spot
        vm.prank(DEV);
        vm.expectRevert(MockV3ConvRouter.Slippage.selector);
        hook.claimFees(address(token));
        assertGt(hook.accrued(address(token)), 0, "revert unwound, nothing lost");
    }
}
