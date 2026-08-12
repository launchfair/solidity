// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StockPairRouter, ILaunchpadV4, IWETH} from "../../src/v2/v4/StockPairRouter.sol";
import {RouterGateHook} from "../../src/v2/v4/RouterGateHook.sol";
import {IV3SwapRouter, IUniswapV3Factory} from "../../src/interfaces/IUniswapV3.sol";
import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {TokenDeployerV2} from "../../src/v2/TokenDeployerV2.sol";
import {LaunchFairV4} from "../../src/v2/v4/LaunchFairV4.sol";
import {LaunchFairV4FeeLocker} from "../../src/v2/v4/LaunchFairV4FeeLocker.sol";
import {LaunchFairV4Distributor} from "../../src/v2/v4/LaunchFairV4Distributor.sol";

// ── shared mocks ─────────────────────────────────────────────────────────────

/// Mintable WETH9-style token — used for WETH and the "stock" quote token.
contract MockWethT is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
    function withdraw(uint256 a) external {
        _burn(msg.sender, a);
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "weth withdraw");
    }
    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// Minimal SwapRouter02 stand-in: pulls `amountIn` of `tokenIn` and mints `amountIn` of `tokenOut`
/// (1:1) to the recipient. Both tokens are MockWethT (mintable); WETH out is backed by ETH the test
/// pre-funds into the WETH mock.
contract MockV3Router {
    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p) external returns (uint256 out) {
        MockWethT(payable(p.tokenIn)).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn; // 1:1
        require(out >= p.amountOutMinimum, "slip");
        MockWethT(payable(p.tokenOut)).mint(p.recipient, out);
    }
}

/// Minimal V3 factory stand-in for the launchpad constructor.
contract MockV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
    function createPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

/// A launchpad stand-in returning a hand-crafted Launch, so the router can be tested over a clean
/// two-sided TOKEN/stock pool without the real single-sided launch curve.
contract MockLaunchpad {
    mapping(address => ILaunchpadV4.Launch) internal _l;
    mapping(address => uint24) public quoteV3Fee;

    function set(address token, PoolKey memory key, address quote, uint24 v3Fee, address creator) external {
        _l[token] = ILaunchpadV4.Launch({creator: creator, key: key, fee: 0, quoteToken: quote, exists: true});
        quoteV3Fee[quote] = v3Fee;
    }

    function getLaunch(address token) external view returns (ILaunchpadV4.Launch memory) {
        return _l[token];
    }

    function creatorOf(address token) external view returns (address) {
        return _l[token].creator;
    }
}

// ── router mechanics (mock launchpad + clean two-sided pool) ─────────────────

contract StockPairRouterTest is Test, Deployers {
    MockWethT weth;
    MockWethT stock;
    MockWethT token; // the traded launch token (a plain ERC20 for the mechanics test)
    MockV3Router v3router;
    MockLaunchpad padMock;
    StockPairRouter router;
    RouterGateHook gate;
    PoolKey poolKey;

    address constant ALICE = address(0xA11CE);
    address constant TREASURY = address(0x7EA);
    address constant FLAGSHIP = address(0xF1A);
    address constant CREATOR = address(0xDe0);

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockWethT();
        stock = new MockWethT();
        token = new MockWethT();
        v3router = new MockV3Router();
        padMock = new MockLaunchpad();

        // WETH mock must hold ETH to satisfy withdraws of minted WETH (V3 sell hop mints WETH).
        vm.deal(address(weth), 10_000 ether);

        router = new StockPairRouter(
            address(this), manager, IWETH(address(weth)), IV3SwapRouter(address(v3router)),
            ILaunchpadV4(address(padMock)), 100 // 1% fee
        );
        router.setDestinations(TREASURY, FLAGSHIP);

        // Mine + deploy the gate hook bound to this router (low 14 bits == BEFORE_SWAP_FLAG).
        address hookAddr =
            address((uint160(uint256(keccak256("stock-gate"))) & ~uint160(0x3FFF)) | uint160(Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("RouterGateHook.sol:RouterGateHook", abi.encode(address(manager), address(router)), hookAddr);
        gate = RouterGateHook(hookAddr);

        // Two-sided TOKEN/stock pool around 1:1 with the gate hook, seeded with liquidity.
        bool tokenIsC0 = address(token) < address(stock);
        (Currency c0, Currency c1) = tokenIsC0
            ? (Currency.wrap(address(token)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(token)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddr)});
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        token.mint(address(this), 1_000 ether);
        stock.mint(address(this), 1_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        stock.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100 ether, salt: 0}),
            ""
        );

        padMock.set(address(token), poolKey, address(stock), 3000, CREATOR);
    }

    function test_buy_deliversTokens_andAccruesWethFee() public {
        vm.deal(ALICE, 5 ether);
        vm.prank(ALICE);
        uint256 out = router.buy{value: 1 ether}(address(token), 0, ALICE, block.timestamp + 1);

        assertGt(out, 0, "received tokens");
        assertEq(token.balanceOf(ALICE), out, "tokens landed with ALICE");
        // 1% of 1 ETH accrues as WETH; the router holds exactly that.
        assertEq(router.accrued(address(token)), 0.01 ether, "fee accrued");
        assertEq(weth.balanceOf(address(router)), 0.01 ether, "router holds only the accrued WETH");
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(stock.balanceOf(address(router)), 0, "router holds no stock");
    }

    function test_sell_returnsEth_andAccruesWethFee() public {
        // ALICE buys first so she has tokens to sell.
        vm.deal(ALICE, 5 ether);
        vm.prank(ALICE);
        uint256 bought = router.buy{value: 1 ether}(address(token), 0, ALICE, block.timestamp + 1);

        uint256 accruedAfterBuy = router.accrued(address(token));
        uint256 ethBefore = ALICE.balance;
        vm.startPrank(ALICE);
        token.approve(address(router), bought);
        uint256 ethOut = router.sell(address(token), bought, 0, ALICE, block.timestamp + 1);
        vm.stopPrank();

        assertGt(ethOut, 0, "received ETH");
        assertEq(ALICE.balance, ethBefore + ethOut, "ETH landed with ALICE");
        assertEq(token.balanceOf(ALICE), 0, "sold all tokens");
        assertGt(router.accrued(address(token)), accruedAfterBuy, "sell added a WETH fee");
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(stock.balanceOf(address(router)), 0, "router holds no stock");
    }

    function test_distribute_splitsWethExactly() public {
        vm.deal(ALICE, 5 ether);
        vm.prank(ALICE);
        router.buy{value: 1 ether}(address(token), 0, ALICE, block.timestamp + 1);

        uint256 amt = router.accrued(address(token)); // 0.01 ether
        router.distribute(address(token));

        assertEq(router.accrued(address(token)), 0, "accrued zeroed");
        assertEq(weth.balanceOf(TREASURY), amt * 2500 / 10000, "treasury 25%");
        assertEq(weth.balanceOf(CREATOR), amt * 2500 / 10000, "dev 25% to creator");
        // flagship gets its 10% + the folded 40% mechanism = 50% (Base token, no mechanism).
        assertEq(weth.balanceOf(FLAGSHIP), amt - (amt * 2500 / 10000) * 2, "flagship 50%");
        assertEq(weth.balanceOf(address(router)), 0, "router drained");
    }

    function test_buy_slippageReverts() public {
        vm.deal(ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(StockPairRouter.Slippage.selector);
        router.buy{value: 1 ether}(address(token), type(uint256).max, ALICE, block.timestamp + 1);
    }

    function test_buy_expiredReverts() public {
        vm.deal(ALICE, 5 ether);
        vm.warp(1000);
        vm.prank(ALICE);
        vm.expectRevert(StockPairRouter.Expired.selector);
        router.buy{value: 1 ether}(address(token), 0, ALICE, 999);
    }

    function test_buy_unknownTokenReverts() public {
        vm.deal(ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(StockPairRouter.NotStockToken.selector);
        router.buy{value: 1 ether}(address(0xBEEF), 0, ALICE, block.timestamp + 1);
    }

    function test_gate_blocksDirectSwap() public {
        // A direct swap through the v4-core test router (sender != stock router) must be rejected.
        stock.mint(address(this), 1 ether);
        stock.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(stock);
        vm.expectRevert(); // hook reverts NotRouter (bubbled through the PoolManager)
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(0.1 ether),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

// ── full-stack launchpad wiring (real createStockToken) ──────────────────────

contract LaunchFairV4StockTest is Test, Deployers {
    MockWethT weth;
    MockWethT stock;
    MockV3Router v3router;
    MockV3Factory v3factory;
    TokenDeployerV2 tokenDeployer;
    LaunchFairV4FeeLocker locker;
    LaunchFairV4Distributor dist;
    StockPairRouter router;
    RouterGateHook gate;
    LaunchFairV4 pad;

    address constant TREASURY = address(0x7EA);
    address constant FLAGSHIP = address(0xF1A);
    uint128 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockWethT();
        stock = new MockWethT();
        v3router = new MockV3Router();
        v3factory = new MockV3Factory();
        vm.deal(address(weth), 10_000 ether);

        tokenDeployer = new TokenDeployerV2();
        locker = new LaunchFairV4FeeLocker(address(this), manager, IERC20(address(weth)), TREASURY);
        dist = new LaunchFairV4Distributor(
            address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this)
        );
        pad = new LaunchFairV4(
            address(this), manager, IUniswapV3Factory(address(v3factory)), locker, address(dist), tokenDeployer,
            address(weth), SUPPLY, 1491146318, int24(200), int24(-203200), int24(-143400), 0, 0, "https://hood.launchfair.app"
        );
        locker.setLaunchpad(address(pad));
        locker.setDistributor(address(dist));
        dist.setLocker(address(locker));
        dist.setRegistrar(address(pad));

        router = new StockPairRouter(
            address(this), manager, IWETH(address(weth)), IV3SwapRouter(address(v3router)),
            ILaunchpadV4(address(pad)), 100
        );
        router.setDestinations(TREASURY, FLAGSHIP);
        address hookAddr =
            address((uint160(uint256(keccak256("stock-gate2"))) & ~uint160(0x3FFF)) | uint160(Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("RouterGateHook.sol:RouterGateHook", abi.encode(address(manager), address(router)), hookAddr);
        gate = RouterGateHook(hookAddr);

        pad.setStockPairRouter(address(router));
        pad.setStockGateHook(hookAddr);
        pad.setAllowedQuote(address(stock), true, 3000);

        vm.deal(address(this), 10 ether);
    }

    function _baseParams() internal pure returns (LaunchFairV4.CreateParams memory p) {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        p = LaunchFairV4.CreateParams({
            name: "StockCoin",
            symbol: "STK",
            metadata: meta,
            salt: bytes32(0),
            mode: LaunchTokenV2.Mode.Base,
            fee: 30_000,
            rewards: new LaunchFairV4.RewardVenue[](0),
            perps: new LaunchFairV4.PerpLeg[](0),
            prizeToken: address(0),
            prizeIsV3: false,
            prizeV3Fee: 0,
            prizePoolKey: none,
            minHold: 0,
            payoutThreshold: 0,
            payoutIntervalBlocks: 0,
            missBps: 0,
            jackpotChanceBps: 0,
            regularWinShareBps: 0
        });
    }

    function test_createStockToken_wiresPoolAndLaunch() public {
        address token = pad.createStockToken{value: 0.000005 ether}(_baseParams(), address(stock));

        LaunchFairV4.Launch memory l = pad.getLaunch(token);
        assertTrue(l.exists, "launch recorded");
        assertEq(l.quoteToken, address(stock), "quote is the stock");
        assertEq(l.fee, 0, "pool fee 0");
        assertEq(address(l.key.hooks), address(gate), "gate hook attached");
        assertEq(pad.creatorOf(token), address(this), "creator is the caller");
        // pool pairs the token with the stock (not WETH)
        address c0 = Currency.unwrap(l.key.currency0);
        address c1 = Currency.unwrap(l.key.currency1);
        assertTrue((c0 == token && c1 == address(stock)) || (c0 == address(stock) && c1 == token), "TOKEN/stock pool");
    }

    function test_createStockAndBuy_deliversTokensToDev() public {
        uint256 devBuy = 0.001 ether;
        address token =
            pad.createStockAndBuy{value: 0.000005 ether + devBuy}(_baseParams(), address(stock), 0);
        assertGt(IERC20(token).balanceOf(address(this)), 0, "dev received tokens atomically");
    }

    function test_createStockToken_rejectsUnapprovedQuote() public {
        MockWethT notAllowed = new MockWethT();
        vm.expectRevert(LaunchFairV4.QuoteNotAllowed.selector);
        pad.createStockToken{value: 0.000005 ether}(_baseParams(), address(notAllowed));
    }

    function test_createStockToken_rejectsNonBaseMode() public {
        LaunchFairV4.CreateParams memory p = _baseParams();
        p.mode = LaunchTokenV2.Mode.Lottery;
        vm.expectRevert(LaunchFairV4.InvalidMode.selector);
        pad.createStockToken{value: 0.000005 ether}(p, address(stock));
    }

    // ── audit fixes ──────────────────────────────────────────────────────────

    /// M-1: router + gate hook are set-once (re-setting the router would orphan existing pools).
    function test_stockSetters_areSetOnce() public {
        vm.expectRevert(LaunchFairV4.AlreadySet.selector);
        pad.setStockPairRouter(address(0xBEEF));
        vm.expectRevert(LaunchFairV4.AlreadySet.selector);
        pad.setStockGateHook(address(0xBEEF));
    }

    /// M-1: setting a gate hook bound to a different router than `stockPairRouter` is rejected.
    function test_setStockGateHook_rejectsMismatchedRouter() public {
        LaunchFairV4 pad2 = new LaunchFairV4(
            address(this), manager, IUniswapV3Factory(address(v3factory)), locker, address(dist), tokenDeployer,
            address(weth), SUPPLY, 1491146318, int24(200), int24(-203200), int24(-143400), 0, 0, "x"
        );
        StockPairRouter r2 = new StockPairRouter(
            address(this), manager, IWETH(address(weth)), IV3SwapRouter(address(v3router)),
            ILaunchpadV4(address(pad2)), 100
        );
        pad2.setStockPairRouter(address(r2));
        address badHook =
            address((uint160(uint256(keccak256("bad-gate"))) & ~uint160(0x3FFF)) | uint160(Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("RouterGateHook.sol:RouterGateHook", abi.encode(address(manager), address(0xBAD)), badHook);
        vm.expectRevert(LaunchFairV4.StockNotConfigured.selector);
        pad2.setStockGateHook(badHook);
    }

    /// L-1: the fee locker refuses to `claim` a stock-paired (non-WETH) pool.
    function test_locker_claim_rejectsStockPool() public {
        address token = pad.createStockToken{value: 0.000005 ether}(_baseParams(), address(stock));
        vm.expectRevert(LaunchFairV4FeeLocker.NotWethPaired.selector);
        locker.claim(token);
    }
}
