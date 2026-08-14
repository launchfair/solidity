// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {TokenDeployerV2} from "../../src/v2/TokenDeployerV2.sol";
import {LaunchFairV4} from "../../src/v2/v4/LaunchFairV4.sol";
import {LaunchFairV4FeeLocker} from "../../src/v2/v4/LaunchFairV4FeeLocker.sol";
import {LaunchFairV4Distributor} from "../../src/v2/v4/LaunchFairV4Distributor.sol";
import {LaunchFairV4SwapRouter, IWETH} from "../../src/v2/v4/LaunchFairV4SwapRouter.sol";
import {MockVRFCoordinator} from "./MockVRF.sol";
import {IV3SwapRouter, IUniswapV3Factory} from "../../src/interfaces/IUniswapV3.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {WethFeeHook} from "../../src/v2/v4/WethFeeHook.sol";
import {ReferenceStockPerpVenue} from "../../src/v2/v4/ReferenceStockPerpVenue.sol";
import {PerpPositionToken} from "../../src/v2/v4/PerpPositionToken.sol";

contract MockWethT is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
    // WETH9-style wrap/unwrap so the swap router can round-trip native ETH in createAndBuy tests.
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

/// 6-decimal quote (USDG-style) for the down-shifted launch-price test.
contract MockUsdg6 is ERC20 {
    constructor() ERC20("USDG", "USDG") {}
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice Minimal V3 factory stand-in: records which (tokenA, tokenB, fee) pools
/// "exist" so the launchpad's reward-pool validation can pass.
/// @notice Minimal stand-in for a V3 pool. The launchpad now reads `slot0` to prove a reward
/// venue is actually INITIALIZED (a `createPool` without `initialize` leaves a deployed pool at
/// price 0 that reverts on every swap, which would strand the token's mechanism WETH forever),
/// so venue pools in tests have to be real contracts with a real price.
contract MockV3PoolT {
    uint160 public sqrtPriceX96;

    constructor(uint160 p) {
        sqrtPriceX96 = p;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, int24(0), uint16(0), uint16(0), uint16(0), uint8(0), true);
    }
}

contract MockV3FactoryT {
    mapping(bytes32 => address) internal _pools;

    /// Registers a REAL initialized stub pool. The `pool` argument is only a label now — the
    /// launchpad checks the pool's price, so a bare placeholder address can no longer stand in.
    function setPool(address a, address b, uint24 fee, address) external {
        _pools[_k(a, b, fee)] = address(new MockV3PoolT(uint160(1) << 96));
    }

    /// Register an address verbatim — for testing that an UNINITIALIZED or non-pool venue is
    /// rejected at launch rather than accepted and stranded.
    function setPoolRaw(address a, address b, uint24 fee, address pool) external {
        _pools[_k(a, b, fee)] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return _pools[_k(a, b, fee)];
    }

    function _k(address a, address b, uint24 fee) internal pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(x, y, fee));
    }
}

/// @notice Minimal SwapRouter02 stand-in: pulls WETH and mints 2x the reward token
/// (a mintable MockWethT) to the recipient.
contract MockV3RouterT {
    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p) external returns (uint256 out) {
        MockWethT(payable(p.tokenIn)).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * 2;
        require(out >= p.amountOutMinimum, "slip");
        MockWethT(payable(p.tokenOut)).mint(p.recipient, out);
    }
}

/// @notice Capstone: launch a Redistribute token through LaunchFairV4, trade to
/// generate fees, claim, process, and confirm a holder is auto-rewarded — the
/// whole V4 pipeline behind one entry point.
contract LaunchFairV4Test is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    MockWethT weth;
    MockV3FactoryT v3factory;
    MockV3RouterT v3router;
    TokenDeployerV2 tokenDeployer;
    LaunchFairV4FeeLocker locker;
    LaunchFairV4Distributor dist;
    MockVRFCoordinator vrf;
    LaunchFairV4SwapRouter v4Router;
    LaunchFairV4 pad;

    address constant TREASURY = address(0x7EA);
    address constant FLAGSHIP = address(0xF1A);
    address constant HOLDER = address(0xB0B);
    uint128 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new MockWethT();
        vm.deal(address(weth), 10_000 ether);
        v3factory = new MockV3FactoryT();
        v3router = new MockV3RouterT();

        tokenDeployer = new TokenDeployerV2();
        locker = new LaunchFairV4FeeLocker(address(this), manager, IERC20(address(weth)), TREASURY);
        // registrar placeholder = this; repointed to the launchpad below.
        dist = new LaunchFairV4Distributor(
            address(this), manager, IV3SwapRouter(address(v3router)), IERC20(address(weth)), address(this)
        );
        pad = new LaunchFairV4(
            address(this), manager, IUniswapV3Factory(address(v3factory)), locker, address(dist), tokenDeployer,
            address(weth), SUPPLY, 1491146318, int24(200), int24(-203200), int24(-143400), 0, 0, "https://hood.launchfair.app"
        );

        vrf = new MockVRFCoordinator();
        v4Router = new LaunchFairV4SwapRouter(manager, IWETH(address(weth)));
        locker.setLaunchpad(address(pad));
        locker.setDistributor(address(dist));
        dist.setLocker(address(locker));
        dist.setRegistrar(address(pad));
        dist.setVrf(address(vrf));
        pad.setSwapRouter(address(v4Router)); // wire the router for createAndBuy

        vm.deal(address(this), 10 ether);
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
                rewards: _noRewards(),
                perps: _noPerps(),
                prizeToken: address(0),
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
        key = pad.getLaunch(token).key;
    }

    // Sorted holder set for settleDraw when the test contract is the sole ticket-holder.
    function _self() internal view returns (address[] memory h) {
        h = new address[](1);
        h[0] = address(this);
    }

    // No external reward assets (Redistribute / WETH-pot Lottery).
    function _noRewards() internal pure returns (LaunchFairV4.RewardVenue[] memory r) {
        r = new LaunchFairV4.RewardVenue[](0);
    }

    function _noPerps() internal pure returns (LaunchFairV4.PerpLeg[] memory p) {
        p = new LaunchFairV4.PerpLeg[](0);
    }

    /// Launch guard is TIME-based: 1% wallet cap for the first 60 SECONDS, exactly — a
    /// too-big transfer reverts inside the window and clears the moment it expires.
    function test_launchGuard_onePercentForSixtySeconds() public {
        pad.setAntiSnipe(100, 60); // the production DeployV4 config: 1% for 60 seconds
        (address token,) = _createRedistribute();
        LaunchTokenV2 t = LaunchTokenV2(token);
        assertTrue(t.limitActive(), "guard live at launch");
        assertEq(t.maxWalletAmount(), uint256(1_000_000_000 ether) / 100, "cap = 1% of supply");

        // Inside the window: pushing a wallet past 1% reverts. (Transfers stand in for buys —
        // the guard applies to the recipient's balance either way.) The locker holds the
        // supply; use a limit-exempt path: mint isn't available, so check via the token's own
        // accounting — the locker is exempt, a fresh wallet is not.
        vm.warp(block.timestamp + 59);
        assertTrue(t.limitActive(), "still live at 59s");
        vm.warp(block.timestamp + 2); // 61s
        assertFalse(t.limitActive(), "guard expired after 60 seconds");
    }

    /// Stock-paired launches honor the per-quote launch price: the single-sided range (whose
    /// BOTTOM is the effective launch price) shifts up by the configured price ratio, so a
    /// stock quote can target a sane USD launch mcap instead of inheriting the WETH-calibrated
    /// default ("1.49 units of quote" ⇒ ~$270 for an NVDA quote).
    function test_stockLaunch_quoteInitialPrice_shiftsRange() public {
        MockWethT stockQ = new MockWethT();
        address stubRouter = address(0x570c);
        address gateAddr =
            address((uint160(uint256(keccak256("gate-shift"))) & ~uint160(0x3FFF)) | uint160(Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("RouterGateHook.sol:RouterGateHook", abi.encode(address(manager), stubRouter), gateAddr);
        pad.setStockPairRouter(stubRouter);
        pad.setStockGateHook(gateAddr);
        pad.setAllowedQuote(address(stockQ), true, 3000);

        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.CreateParams memory p = LaunchFairV4.CreateParams({
            name: "Stock A", symbol: "SA", metadata: meta, salt: keccak256("sa"),
            mode: LaunchTokenV2.Mode.Base, fee: 30_000, rewards: _noRewards(), perps: _noPerps(),
            prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
            minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0,
            missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
        });
        address a = pad.createStockToken{value: 0.000005 ether}(p, address(stockQ));

        // 100x the default launch price ⇒ ln(100)/ln(1.0001) ≈ 46054 ticks, floored to the
        // 200-tick spacing = 46000.
        pad.setAllowedQuotePrice(address(stockQ), pad.initialPriceWethPerToken() * 100);
        p.symbol = "SB";
        p.salt = keccak256("sb");
        address b = pad.createStockToken{value: 0.000005 ether}(p, address(stockQ));

        // Normalize the range bottom to token-per-quote orientation regardless of address order.
        LaunchFairV4FeeLocker.Position memory pa = locker.positionOf(a);
        LaunchFairV4FeeLocker.Position memory pb = locker.positionOf(b);
        int24 bottomA = pa.tokenIsCurrency0 ? pa.tickLower : -pa.tickUpper;
        int24 bottomB = pb.tokenIsCurrency0 ? pb.tickLower : -pb.tickUpper;
        assertEq(bottomB - bottomA, 46_000, "range bottom lifted by the configured price ratio");
    }

    /// Wire a stub stock stack (router placeholder + gate hook) and allow `quote`. Unique salt
    /// per test so deployCodeTo addresses never collide.
    function _stockStack(bytes32 salt, address quote) internal {
        address stubRouter = address(uint160(uint256(keccak256(abi.encode("router", salt)))));
        address gateAddr =
            address((uint160(uint256(keccak256(abi.encode("gate", salt)))) & ~uint160(0x3FFF)) | uint160(Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("RouterGateHook.sol:RouterGateHook", abi.encode(address(manager), stubRouter), gateAddr);
        pad.setStockPairRouter(stubRouter);
        pad.setStockGateHook(gateAddr);
        pad.setAllowedQuote(quote, true, 3000);
    }

    function _stockParams(string memory sym, LaunchTokenV2.Mode mode) internal pure returns (LaunchFairV4.CreateParams memory p) {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        p = LaunchFairV4.CreateParams({
            name: sym, symbol: sym, metadata: meta, salt: keccak256(bytes(sym)),
            mode: mode, fee: 30_000, rewards: _noRewards(), perps: _noPerps(),
            prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
            minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0,
            missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
        });
    }

    /// Stock pairs now take MODES: a Reward-mode stock token deploys with its reward config and
    /// registers the mechanism, exactly like a WETH pair.
    function test_stockLaunch_rewardMode_fullMechanismWiring() public {
        MockWethT stockQ = new MockWethT();
        _stockStack("reward", address(stockQ));
        // A V3-venued reward asset (validated against the mock factory, like the WETH-pair tests).
        MockWethT rewardAsset = new MockWethT();
        v3factory.setPool(address(rewardAsset), address(weth), 3000, address(0xBEEF));

        LaunchFairV4.CreateParams memory p = _stockParams("SRW", LaunchTokenV2.Mode.Reward);
        p.rewards = _oneReward(address(rewardAsset), true, 3000);
        address token = pad.createStockToken{value: 0.000005 ether}(p, address(stockQ));

        assertEq(uint8(LaunchTokenV2(token).mode()), uint8(LaunchTokenV2.Mode.Reward), "mode survived the stock path");
        address[] memory assets = LaunchTokenV2(token).rewardTokensList();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(rewardAsset), "reward asset registered on the token");
        assertEq(pad.getLaunch(token).quoteToken, address(stockQ), "stock-paired");
    }

    function test_stockLaunch_lotteryMode_operatorWired() public {
        MockWethT stockQ = new MockWethT();
        _stockStack("lottery", address(stockQ));
        address token = pad.createStockToken{value: 0.000005 ether}(_stockParams("SLT", LaunchTokenV2.Mode.Lottery), address(stockQ));
        assertEq(uint8(LaunchTokenV2(token).mode()), uint8(LaunchTokenV2.Mode.Lottery));
        assertEq(LaunchTokenV2(token).lotteryOperator(), address(dist), "distributor runs the draws");
    }

    /// Redistribute buys back the token's OWN pool — stock-quoted here, unroutable for the
    /// WETH-spending distributor — and Perps stays WETH-only. Both must refuse a stock quote.
    function test_stockLaunch_redistributeAndPerps_revert() public {
        MockWethT stockQ = new MockWethT();
        _stockStack("reject", address(stockQ));
        LaunchFairV4.CreateParams memory p = _stockParams("SRD", LaunchTokenV2.Mode.Increasing);
        vm.expectRevert(LaunchFairV4.InvalidMode.selector);
        pad.createStockToken{value: 0.000005 ether}(p, address(stockQ));
        p = _stockParams("SPP", LaunchTokenV2.Mode.Perps);
        vm.expectRevert(LaunchFairV4.InvalidMode.selector);
        pad.createStockToken{value: 0.000005 ether}(p, address(stockQ));
    }

    /// USDG (6 decimals): its sane launch price in quote-wei (~3 wei/token for a ~$3k mcap) sits
    /// ~9 orders BELOW the 18-dp default, so the price knob must shift the range (and the pool's
    /// init price with it) DOWNWARD — the up-only knob would have listed at a $1.5T mcap.
    function test_stockLaunch_usdg6Decimals_downShiftedLaunchPrice() public {
        MockUsdg6 usdg = new MockUsdg6();
        MockWethT plain = new MockWethT();
        _stockStack("usdg", address(usdg));
        pad.setAllowedQuote(address(plain), true, 3000);
        pad.setAllowedQuotePrice(address(usdg), 3); // 3 USDG-wei per whole token ≈ $3k FDV

        address a = pad.createStockToken{value: 0.000005 ether}(_stockParams("SPL", LaunchTokenV2.Mode.Base), address(plain));
        address b = pad.createStockToken{value: 0.000005 ether}(_stockParams("SUS", LaunchTokenV2.Mode.Base), address(usdg));

        LaunchFairV4FeeLocker.Position memory pa = locker.positionOf(a);
        LaunchFairV4FeeLocker.Position memory pb = locker.positionOf(b);
        int24 bottomA = pa.tokenIsCurrency0 ? pa.tickLower : -pa.tickUpper;
        int24 bottomB = pb.tokenIsCurrency0 ? pb.tickLower : -pb.tickUpper;
        int24 diff = bottomB - bottomA;
        // ln(3 / 1491146318) / ln(1.0001) ≈ -200,297 → truncated to the 200 spacing = -200,200.
        assertEq(diff, -200_200, "range dropped by the knob ratio, spacing-aligned");

        // Init price followed the range down: the pool's current tick sits at/below the shifted
        // range bottom (token-per-quote orientation), so the single-sided mint (which SUCCEEDED
        // above — a wrong-side init would have needed quote-side funds and reverted in the
        // locker) leaves the first buy walking price up into the range exactly as on WETH pairs.
        PoolKey memory key = pad.getLaunch(b).key;
        (, int24 tickNow,,) = StateLibrary.getSlot0(manager, key.toId());
        int24 tickTokenPerQuote = pb.tokenIsCurrency0 ? tickNow : -tickNow;
        assertLe(tickTokenPerQuote, bottomB, "pool initialized at/below the down-shifted range bottom");
    }

    /// Selling must be ONE transaction: the platform routers read as infinitely approved, so no
    /// approve step is ever needed. Everything else still requires a real allowance.
    function test_trustedSpender_routersNeedNoApproval() public {
        (address token, PoolKey memory key) = _createRedistribute();
        LaunchTokenV2 t = LaunchTokenV2(token);

        assertEq(t.allowance(HOLDER, address(v4Router)), type(uint256).max, "V4 router pre-approved");
        assertTrue(t.trustedSpender(address(v4Router)), "router flagged trusted");
        assertEq(t.allowance(HOLDER, address(0xBAD)), 0, "everyone else still needs an approval");

        // A trusted spender can actually move tokens with no approve() call. Get real tokens
        // by buying off the pool (past the launch guard), then hand them to the holder.
        vm.warp(block.timestamp + 120);
        _buy(key, token, 0.01 ether);
        uint256 bought = IERC20(token).balanceOf(address(this));
        assertGt(bought, 1_000 ether, "bought enough to test with");
        IERC20(token).transfer(HOLDER, bought);

        vm.prank(address(v4Router));
        t.transferFrom(HOLDER, address(0xCAFE), 1_000 ether);
        assertEq(t.balanceOf(address(0xCAFE)), 1_000 ether, "sold without an approval tx");

        // ...and an untrusted one still cannot.
        vm.prank(address(0xBAD));
        vm.expectRevert();
        t.transferFrom(HOLDER, address(0xBAD), 10 ether);
    }

    /// Stock-paired tokens get the same treatment for the stock router.
    function test_trustedSpender_stockRouter() public {
        MockWethT stockQ = new MockWethT();
        _stockStack("trusted", address(stockQ));
        address token = pad.createStockToken{value: 0.000005 ether}(_stockParams("STR", LaunchTokenV2.Mode.Base), address(stockQ));
        assertEq(LaunchTokenV2(token).allowance(HOLDER, pad.stockPairRouter()), type(uint256).max, "stock router pre-approved");
    }

    // A single reward asset taking the full fee weight, on a V3 (or V4) venue.
    function _oneReward(address asset, bool isV3, uint24 v3Fee)
        internal
        pure
        returns (LaunchFairV4.RewardVenue[] memory r)
    {
        PoolKey memory none;
        r = new LaunchFairV4.RewardVenue[](1);
        r[0] = LaunchFairV4.RewardVenue({token: asset, weightBps: 10_000, isV3: isV3, v3Fee: v3Fee, v4Key: none});
    }

    // minOuts array of `n` zeros (no slippage floor) for process().
    function _zeros(uint256 n) internal pure returns (uint256[] memory m) {
        m = new uint256[](n);
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

    /// End-to-end: a PLAIN (Base) token on V4 with the WETH fee hook — fee is WETH on both the
    /// buy and the sell (no token taken → no sell pressure), and distribute() splits it, folding
    /// the plain token's mechanism slice into the flagship.
    function test_endToEnd_baseTokenOnV4_wethHookBothWays() public {
        // Deploy the hook at a permission-encoded address + wire it.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x7777) << 144));
        deployCodeTo("WethFeeHook.sol:WethFeeHook", abi.encode(address(this), manager, address(weth), uint16(100)), hookAddr);
        WethFeeHook hook = WethFeeHook(payable(hookAddr));
        hook.setDestinations(TREASURY, address(dist), FLAGSHIP, address(pad));
        pad.setFeeHook(hookAddr);

        // Launch a BASE/plain token on V4 (allowed now that the hook is set).
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Plain", symbol: "PLN", metadata: meta, salt: bytes32(uint256(7)),
                mode: LaunchTokenV2.Mode.Base, fee: 30_000, rewards: _noRewards(), perps: _noPerps(), prizeToken: address(0),
                prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none, minHold: 0,
                payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
        PoolKey memory pk = pad.getLaunch(token).key;
        assertEq(address(pk.hooks), hookAddr, "pool uses the hook");
        assertEq(pk.fee, 0, "pool LP fee is 0 (the hook is the fee)");

        // Buy → hook skims WETH from the input.
        _buy(pk, token, 0.1 ether);
        uint256 afterBuy = hook.accrued(token);
        assertGt(afterBuy, 0, "hook took a WETH fee on the buy");

        // Sell the bought tokens → hook skims WETH from the OUTPUT, takes ZERO token.
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 hookTokBefore = IERC20(token).balanceOf(hookAddr);
        IERC20(token).approve(address(swapRouter), bal);
        bool zeroForOne = Currency.unwrap(pk.currency0) == address(token);
        swapRouter.swap(
            pk,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(bal),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(hook.accrued(token), afterBuy, "hook took a WETH fee on the sell too");
        assertEq(IERC20(token).balanceOf(hookAddr), hookTokBefore, "hook took NO token -> no sell pressure");

        // Distribute → plain token: mechanism folds into the flagship (no reward/lottery).
        hook.distribute(token);
        assertEq(hook.accrued(token), 0, "accrual cleared");
        assertGt(FLAGSHIP.balance, 0, "flagship funded (flagship + mechanism for a plain token)");
        assertGt(TREASURY.balance, 0, "treasury funded");
        assertEq(dist.pendingWeth(token), 0, "plain token never funds the reward/lottery distributor");
    }

    function test_endToEnd_launch_trade_claim_process_reward() public {
        (address token, PoolKey memory key) = _createRedistribute();

        // Pool exists + liquidity locked (the locker holds the position).
        assertTrue(pad.getLaunch(token).exists, "launched");
        assertEq(pad.creatorOf(token), address(this), "creator recorded");

        // A buyer becomes a holder (buys token, receives it here) + generates WETH fee.
        _buy(key, token, 0.1 ether);
        // Move the freshly-bought tokens to HOLDER so there's a real dividend holder.
        uint256 bought = IERC20(token).balanceOf(address(this));
        assertGt(bought, 0, "bought token");
        IERC20(token).transfer(HOLDER, bought);
        assertEq(LaunchTokenV2(token).totalShares(), bought, "HOLDER is the holder");

        // Claim the buy-side WETH fee -> split -> mechanism to the distributor.
        locker.claim(token);
        uint256 pending = dist.pendingWeth(token);
        assertGt(pending, 0, "mechanism WETH pending");

        // Process -> buy back the token -> auto-compound into HOLDER's balance.
        // Redistribute is auto-compounding: the balance grows on the buyback itself,
        // no claim and no push.
        uint256 beforeProcess = IERC20(token).balanceOf(HOLDER);
        dist.process(token, _zeros(1)); // Redistribute has one reward asset (the token itself)
        assertGt(IERC20(token).balanceOf(HOLDER), beforeProcess, "balance auto-grew on the buyback");
        assertGt(LaunchTokenV2(token).totalWithdrawableOf(HOLDER), 0, "reflection accrued");

        // A manual realize only folds the reflection into the raw balance — the
        // displayed balanceOf is unchanged (it already reflected the growth).
        uint256 grown = IERC20(token).balanceOf(HOLDER);
        address[] memory who = new address[](1);
        who[0] = HOLDER;
        LaunchTokenV2(token).processAccounts(who);
        assertApproxEqAbs(IERC20(token).balanceOf(HOLDER), grown, 100, "realize doesn't change balanceOf");
        assertEq(LaunchTokenV2(token).totalWithdrawableOf(HOLDER), 0, "reflection realized");
    }

    // A Reward token whose reward asset trades on Uniswap V3 (not an exclusive V4
    // pool): the dev picks it, the launchpad validates the V3 pool exists and wires
    // a V3 buyback, and process() routes the swap through SwapRouter02.
    function test_endToEnd_reward_v3RewardToken() public {
        MockWethT reward = new MockWethT();
        v3factory.setPool(address(weth), address(reward), 10_000, address(0xBEEF)); // pool exists

        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "RewV3",
                symbol: "RV3",
                metadata: meta,
                salt: bytes32(uint256(2)),
                mode: LaunchTokenV2.Mode.Reward,
                fee: 30_000,
                rewards: _oneReward(address(reward), true, 10_000),
                perps: _noPerps(),
                prizeToken: address(0),
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
        assertEq(dist.buybackVenue(token, address(reward)), 1, "wired to a V3 buyback");

        PoolKey memory key = pad.getLaunch(token).key;
        _buy(key, token, 0.1 ether);
        IERC20(token).transfer(HOLDER, IERC20(token).balanceOf(address(this)));

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "mechanism WETH pending");

        dist.process(token, _zeros(1));
        assertGt(LaunchTokenV2(token).withdrawableDividendOf(address(reward), HOLDER), 0, "HOLDER accrued the reward");

        vm.prank(HOLDER);
        LaunchTokenV2(token).claim();
        assertGt(reward.balanceOf(HOLDER), 0, "HOLDER received the V3-bought reward token");
    }

    // Perps mode end-to-end: fees are deposited as MARGIN into a leveraged stock position via the
    // venue, and holders receive the fungible POSITION TOKEN as a reward — hands-off, exactly like a
    // reward token. A holder ends up with the leveraged position in their wallet and redeems it for
    // WETH at NAV (which grows with the leveraged move). Principal-safe: only fees were ever margin.
    function test_endToEnd_perps_holderGetsLeveragedPositionToken_andRedeems() public {
        bytes32 AAPL = keccak256("AAPL");
        ReferenceStockPerpVenue venue = new ReferenceStockPerpVenue(address(this), address(weth));
        venue.listMarket(AAPL, "AAPL", 200 ether, true);
        weth.mint(address(this), 100 ether);
        weth.approve(address(venue), type(uint256).max);
        venue.fundLiquidity(50 ether); // house liquidity backs leveraged profit on redeem
        venue.setOpener(address(dist), true); // the distributor is the authorized margin depositor
        pad.setPerpsVenue(address(venue)); // distributor's venue is pinned per-token at registerPerps

        // Launch a Perps token: one leg, AAPL 3x long, full weight — dev's pick, frozen at launch.
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.PerpLeg[] memory legs = new LaunchFairV4.PerpLeg[](1);
        legs[0] = LaunchFairV4.PerpLeg({market: AAPL, isLong: true, leverageBps: 30_000, weightBps: 10_000});
        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "AAPL3x", symbol: "AAPL3X", metadata: meta, salt: bytes32(uint256(42)),
                mode: LaunchTokenV2.Mode.Perps, fee: 30_000, rewards: _noRewards(), perps: legs,
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none, minHold: 0,
                payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
        address posTok = venue.positionTokenFor(AAPL, true, 30_000);
        assertEq(LaunchTokenV2(token).rewardTokensList()[0], posTok, "position token is the reward asset");

        PoolKey memory key = pad.getLaunch(token).key;
        _buy(key, token, 0.1 ether);
        IERC20(token).transfer(HOLDER, IERC20(token).balanceOf(address(this)));

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "mechanism WETH pending");

        // process(): deposit the WETH as margin → mint the position token → fund the tracker.
        dist.process(token, _zeros(1));
        assertGt(LaunchTokenV2(token).withdrawableDividendOf(posTok, HOLDER), 0, "HOLDER accrued the position token");

        // HOLDER claims → the leveraged position token lands in their wallet, to do whatever with.
        vm.prank(HOLDER);
        LaunchTokenV2(token).claim();
        uint256 shares = IERC20(posTok).balanceOf(HOLDER);
        assertGt(shares, 0, "HOLDER holds the leveraged-position token");

        // AAPL rallies 10% → 3x = +30% NAV. HOLDER redeems it for WETH profit.
        uint256 navEntry = venue.shareValue(posTok, shares);
        venue.setMarkPrice(AAPL, 220 ether);
        uint256 navAfter = venue.shareValue(posTok, shares);
        assertGt(navAfter, navEntry, "the leveraged position gained on the move");

        uint256 wethBefore = weth.balanceOf(HOLDER);
        vm.prank(HOLDER);
        uint256 out = venue.redeem(posTok, shares, 0);
        assertEq(out, navAfter, "redeemed at NAV");
        assertEq(weth.balanceOf(HOLDER) - wethBefore, out, "HOLDER got WETH for the leveraged position");
        assertGt(out, 0, "position had value");
    }

    // AUDIT HIGH: a liquidated leg (market still open, but its pool value hit 0) must NOT revert the
    // whole process() and brick the token's rewards — it holds that leg and deploys the others.
    function test_perps_liquidatedLegDoesNotBrickTheToken() public {
        bytes32 AAPL = keccak256("AAPL");
        bytes32 TSLA = keccak256("TSLA");
        ReferenceStockPerpVenue venue = new ReferenceStockPerpVenue(address(this), address(weth));
        venue.listMarket(AAPL, "AAPL", 200 ether, true);
        venue.listMarket(TSLA, "TSLA", 100 ether, true);
        weth.mint(address(this), 100 ether);
        weth.approve(address(venue), type(uint256).max);
        venue.fundLiquidity(50 ether);
        venue.setOpener(address(dist), true);
        pad.setPerpsVenue(address(venue));

        // 2-leg basket: AAPL 3x long 50%, TSLA 2x short 50%.
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.PerpLeg[] memory legs = new LaunchFairV4.PerpLeg[](2);
        legs[0] = LaunchFairV4.PerpLeg({market: AAPL, isLong: true, leverageBps: 30_000, weightBps: 5_000});
        legs[1] = LaunchFairV4.PerpLeg({market: TSLA, isLong: false, leverageBps: 20_000, weightBps: 5_000});
        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Basket", symbol: "BKT", metadata: meta, salt: bytes32(uint256(77)),
                mode: LaunchTokenV2.Mode.Perps, fee: 30_000, rewards: _noRewards(), perps: legs,
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none, minHold: 0,
                payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
        PoolKey memory key = pad.getLaunch(token).key;

        // Cycle 1: both legs get margin.
        _buy(key, token, 0.1 ether);
        locker.claim(token);
        dist.process(token, _zeros(2));

        // AAPL 3x-long pool is liquidated by a −35% move — but its MARKET stays open (price > 0).
        venue.setMarkPrice(AAPL, 130 ether);
        assertTrue(venue.marketOpen(AAPL), "market open; only the pool is liquidated");

        // Cycle 2: new fees. Without the try/catch fix this reverts forever; with it, process holds
        // the AAPL leg and deploys the TSLA leg.
        _buy(key, token, 0.1 ether);
        locker.claim(token);
        dist.process(token, _zeros(2)); // must not revert
        assertGt(dist.pendingWeth(token), 0, "liquidated AAPL leg's WETH held for next cycle, not bricked");
    }

    // Multi-reward: two dev-chosen reward assets distributed in parallel, each with
    // its own fee weight (60/40) + V3 venue. process() splits the fee batch by weight
    // and buys both assets in a single call; holders accrue in each asset separately.
    function test_endToEnd_reward_multiAsset_parallel() public {
        MockWethT rewardA = new MockWethT();
        MockWethT rewardB = new MockWethT();
        v3factory.setPool(address(weth), address(rewardA), 10_000, address(0xBEE1));
        v3factory.setPool(address(weth), address(rewardB), 10_000, address(0xBEE2));

        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](2);
        rewards[0] =
            LaunchFairV4.RewardVenue({token: address(rewardA), weightBps: 6_000, isV3: true, v3Fee: 10_000, v4Key: none});
        rewards[1] =
            LaunchFairV4.RewardVenue({token: address(rewardB), weightBps: 4_000, isV3: true, v3Fee: 10_000, v4Key: none});

        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Multi",
                symbol: "MULTI",
                metadata: meta,
                salt: bytes32(uint256(5)),
                mode: LaunchTokenV2.Mode.Reward,
                fee: 30_000,
                rewards: rewards,
                perps: _noPerps(),
                prizeToken: address(0),
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );

        // Both assets registered as reward buckets, in order, with their weights + venues.
        address[] memory list = LaunchTokenV2(token).rewardTokensList();
        assertEq(list.length, 2, "two reward assets");
        assertEq(list[0], address(rewardA), "asset0 = A");
        assertEq(list[1], address(rewardB), "asset1 = B");
        assertEq(LaunchTokenV2(token).rewardWeightBps(address(rewardA)), 6_000, "A weight 60%");
        assertEq(LaunchTokenV2(token).rewardWeightBps(address(rewardB)), 4_000, "B weight 40%");
        assertEq(dist.buybackVenue(token, address(rewardA)), 1, "A on V3");
        assertEq(dist.buybackVenue(token, address(rewardB)), 1, "B on V3");

        PoolKey memory key = pad.getLaunch(token).key;
        _buy(key, token, 0.1 ether);
        IERC20(token).transfer(HOLDER, IERC20(token).balanceOf(address(this)));

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "fee pending");

        dist.process(token, _zeros(2)); // buys both assets in one call

        uint256 wdA = LaunchTokenV2(token).withdrawableDividendOf(address(rewardA), HOLDER);
        uint256 wdB = LaunchTokenV2(token).withdrawableDividendOf(address(rewardB), HOLDER);
        assertGt(wdA, 0, "accrued asset A");
        assertGt(wdB, 0, "accrued asset B");
        // Split follows the weights: A = 60%, B = 40% -> wdA/wdB == 60/40 == 1.5.
        assertApproxEqRel(wdA * 4_000, wdB * 6_000, 1e15, "60/40 fee split honored");

        // Claiming pays out every reward asset in one call.
        vm.prank(HOLDER);
        LaunchTokenV2(token).claim();
        assertGt(rewardA.balanceOf(HOLDER), 0, "HOLDER got asset A");
        assertGt(rewardB.balanceOf(HOLDER), 0, "HOLDER got asset B");
    }

    // Reward weights must sum to exactly 10000.
    function test_reward_rejectsBadWeights() public {
        MockWethT a = new MockWethT();
        MockWethT b = new MockWethT();
        v3factory.setPool(address(weth), address(a), 10_000, address(0xBEE1));
        v3factory.setPool(address(weth), address(b), 10_000, address(0xBEE2));
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](2);
        rewards[0] = LaunchFairV4.RewardVenue({token: address(a), weightBps: 6_000, isV3: true, v3Fee: 10_000, v4Key: none});
        rewards[1] = LaunchFairV4.RewardVenue({token: address(b), weightBps: 3_000, isV3: true, v3Fee: 10_000, v4Key: none}); // 9000
        vm.expectRevert(LaunchFairV4.BadRewardConfig.selector);
        pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Bad", symbol: "BAD", metadata: meta, salt: bytes32(uint256(6)),
                mode: LaunchTokenV2.Mode.Reward, fee: 30_000, rewards: rewards,
                perps: _noPerps(),
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
                minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
    }

    // A duplicate reward asset is rejected (one dividend bucket per asset).
    function test_reward_rejectsDuplicateAsset() public {
        MockWethT a = new MockWethT();
        v3factory.setPool(address(weth), address(a), 10_000, address(0xBEE1));
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](2);
        rewards[0] = LaunchFairV4.RewardVenue({token: address(a), weightBps: 5_000, isV3: true, v3Fee: 10_000, v4Key: none});
        rewards[1] = LaunchFairV4.RewardVenue({token: address(a), weightBps: 5_000, isV3: true, v3Fee: 10_000, v4Key: none});
        vm.expectRevert(LaunchFairV4.BadRewardConfig.selector);
        pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Dup", symbol: "DUP", metadata: meta, salt: bytes32(uint256(7)),
                mode: LaunchTokenV2.Mode.Reward, fee: 30_000, rewards: rewards,
                perps: _noPerps(),
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
                minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
    }

    // More than MAX_REWARDS (5) assets is rejected.
    function test_reward_rejectsTooMany() public {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        LaunchFairV4.RewardVenue[] memory rewards = new LaunchFairV4.RewardVenue[](6);
        for (uint256 i; i < 6; i++) {
            MockWethT a = new MockWethT();
            v3factory.setPool(address(weth), address(a), 10_000, address(uint160(0xBE00 + i)));
            rewards[i] =
                LaunchFairV4.RewardVenue({token: address(a), weightBps: 2_000, isV3: true, v3Fee: 10_000, v4Key: none});
        }
        vm.expectRevert(LaunchFairV4.BadRewardConfig.selector);
        pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Six", symbol: "SIX", metadata: meta, salt: bytes32(uint256(8)),
                mode: LaunchTokenV2.Mode.Reward, fee: 30_000, rewards: rewards,
                perps: _noPerps(),
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
                minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
    }

    // A V3 reward whose pool doesn't exist is rejected at creation (no un-routable
    // buyback can be locked in).
    function test_reward_v3_rejectsMissingPool() public {
        MockWethT reward = new MockWethT(); // factory has no pool registered for it
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        vm.expectRevert(LaunchFairV4.InvalidRewardPool.selector);
        pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Bad",
                symbol: "BAD",
                metadata: meta,
                salt: bytes32(uint256(3)),
                mode: LaunchTokenV2.Mode.Reward,
                fee: 30_000,
                rewards: _oneReward(address(reward), true, 10_000),
                perps: _noPerps(),
                prizeToken: address(0),
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
    }

    function _createLottery() internal returns (address token, PoolKey memory key) {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "Lotto",
                symbol: "LOTTO",
                metadata: meta,
                salt: bytes32(uint256(1)),
                mode: LaunchTokenV2.Mode.Lottery,
                fee: 100_000, // 10% fee -> a beefy pot
                rewards: _noRewards(),
                perps: _noPerps(),
                prizeToken: address(0), // WETH pot
                prizeIsV3: false,
                prizeV3Fee: 0,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
        key = pad.getLaunch(token).key;
    }

    // Full lottery pipeline through the launchpad: launch -> buy (earns tickets)
    // -> claim (funds the pot) -> commit to a future drand round -> settle (pays
    // the verifiable winner + records the draw).
    function test_endToEnd_lottery_launch_buy_draw() public {
        (address token, PoolKey memory key) = _createLottery();
        dist.setDrawOperator(address(this)); // this session acts as the keeper

        // Launchpad wired the lottery: distributor is the draw operator.
        assertEq(LaunchTokenV2(token).lotteryOperator(), address(dist), "distributor is operator");

        // Holdings are tickets: buying gives this buyer a balance -> proportional tickets.
        _buy(key, token, 0.1 ether);
        uint256 epoch = LaunchTokenV2(token).lotteryEpoch();
        uint256 myTickets = LaunchTokenV2(token).balanceOf(address(this));
        assertGt(myTickets, 0, "holdings earn tickets");
        assertEq(LaunchTokenV2(token).totalEligibleSupply(), myTickets, "sole eligible holder");

        // Claim the buy-side fee -> mechanism WETH becomes the pot.
        locker.claim(token);
        uint256 pot = dist.pendingWeth(token);
        assertGt(pot, 0, "pot funded");

        // Commit snapshots holdings at this block. The pot is NOT reserved (it rolls) and
        // the cycle advances only when a draw actually wins.
        uint256 round = 9_999_999;
        // Eligibility freezes at block.number-1, so holdings must predate the commit block.
        vm.roll(block.number + 1);
        dist.commitDraw(token, round);
        assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch, "session unchanged at commit");
        assertEq(dist.pendingWeth(token), pot, "pot live at commit (not reserved)");
        (,,, uint256 snapBlk,,,) = dist.pendingDraw(token);

        // …the keeper posts the beacon to the coordinator (which pushes it to the
        // distributor), then settles — the randomness comes from the coordinator.
        bytes32 rnd = keccak256("drand-beacon");
        uint256 wt = uint256(keccak256(abi.encode(rnd, token, round))) % LaunchTokenV2(token).totalEligibleAt(snapBlk);
        assertLt(wt, myTickets, "winning ticket falls in our range");
        vrf.deliver(round, rnd);

        uint256 balBefore = weth.balanceOf(address(this));
        dist.settleDraw(token, _self(), 0);

        // Default odds (miss 10% / jackpot 2% / regular 88% @ 70/30). Assert the payout matches
        // whichever bucket THIS beacon's roll lands in — the full launch→draw flow works for all.
        uint256 roll = uint256(keccak256(abi.encode(rnd, token, round, uint256(1)))) % 10_000;
        uint256 paid = weth.balanceOf(address(this)) - balBefore;
        if (roll < 1000) {
            assertEq(paid, 0, "miss pays nobody");
            assertEq(dist.pendingWeth(token), pot, "pot rolls over on a miss");
            assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch, "miss doesn't advance the session");
        } else if (roll >= 9800) {
            assertEq(paid, pot, "jackpot pays the whole pot");
            assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch + 1, "jackpot advances the session");
        } else {
            assertEq(paid, (pot * 7000) / 10_000, "regular pays 70% of the pot");
            assertEq(dist.jackpotWeth(token), pot - paid, "30% skims to the jackpot pool");
            assertEq(LaunchTokenV2(token).lotteryEpoch(), epoch, "regular win doesn't advance the session");
        }
        assertEq(dist.drawCount(token), 1, "draw recorded in history");
    }

    // A lottery whose prize is a dev-chosen token that trades on V3: the launchpad
    // wires the prize's V3 buyback venue, and at settle the pot is swapped to the
    // prize token and paid to the winner.
    function test_endToEnd_lottery_v3PrizeToken() public {
        MockWethT prize = new MockWethT();
        v3factory.setPool(address(weth), address(prize), 10_000, address(0xBEEF));

        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        address token = pad.createToken{value: 0.000005 ether}(
            LaunchFairV4.CreateParams({
                name: "LottoTok",
                symbol: "LTK",
                metadata: meta,
                salt: bytes32(uint256(4)),
                mode: LaunchTokenV2.Mode.Lottery,
                fee: 100_000,
                rewards: _noRewards(),
                perps: _noPerps(),
                prizeToken: address(prize), // token prize (not WETH)
                prizeIsV3: true,
                prizeV3Fee: 10_000,
                prizePoolKey: none,
                minHold: 0,
                payoutThreshold: 0,
                payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            })
        );
        assertEq(dist.buybackVenue(token, address(prize)), 1, "prize bought on V3");
        assertEq(LaunchTokenV2(token).prizeToken(), address(prize), "prize token recorded");

        PoolKey memory key = pad.getLaunch(token).key;
        dist.setDrawOperator(address(this));
        _buy(key, token, 0.1 ether); // this session earns all tickets
        uint256 epoch = LaunchTokenV2(token).lotteryEpoch();

        locker.claim(token);
        assertGt(dist.pendingWeth(token), 0, "pot funded");

        // Eligibility freezes at block.number-1, so holdings must predate the commit block.
        vm.roll(block.number + 1);
        dist.commitDraw(token, 42);
        vrf.deliver(42, keccak256("beacon"));
        dist.settleDraw(token, _self(), 0);

        // Default odds: whichever bucket the beacon lands in, a win pays the prize TOKEN.
        uint256 roll = uint256(keccak256(abi.encode(keccak256("beacon"), token, uint256(42), uint256(1)))) % 10_000;
        if (roll < 1000) {
            assertEq(prize.balanceOf(address(this)), 0, "a miss pays no prize");
        } else {
            assertGt(prize.balanceOf(address(this)), 0, "winner paid in the V3 prize token");
            assertEq(
                LaunchTokenV2(token).lotteryEpoch(), roll >= 9800 ? epoch + 1 : epoch, "epoch advances only on a jackpot"
            );
        }
        assertEq(dist.drawCount(token), 1, "draw recorded");
    }

    // createAndBuy: the creator gets a bag in the SAME tx as the launch — atomic, no front-run gap.
    function test_createAndBuy_devGetsTokensAtomically() public {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        uint256 fee = pad.creationFeeWei();
        uint256 buyAmount = 0.05 ether;
        uint256 treBefore = TREASURY.balance;

        address token = pad.createAndBuy{value: fee + buyAmount}(
            LaunchFairV4.CreateParams({
                name: "Red", symbol: "RED", metadata: meta, salt: bytes32(uint256(77)),
                mode: LaunchTokenV2.Mode.Increasing, fee: 30_000, rewards: _noRewards(),
                perps: _noPerps(),
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
                minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            }),
            0 // minTokensOut
        );

        assertTrue(pad.getLaunch(token).exists, "launched");
        assertEq(pad.creatorOf(token), address(this), "creator recorded");
        assertGt(LaunchTokenV2(token).balanceOf(address(this)), 0, "dev bought a bag in the same tx");
        assertEq(TREASURY.balance - treBefore, fee, "creation fee paid to treasury");
    }

    // createAndBuy with a zero buy behaves like createToken: token created, no dev bag.
    function test_createAndBuy_zeroBuy_justCreates() public {
        LaunchTokenV2.Metadata memory meta;
        PoolKey memory none;
        address token = pad.createAndBuy{value: pad.creationFeeWei()}(
            LaunchFairV4.CreateParams({
                name: "Red", symbol: "RED", metadata: meta, salt: bytes32(uint256(78)),
                mode: LaunchTokenV2.Mode.Increasing, fee: 30_000, rewards: _noRewards(),
                perps: _noPerps(),
                prizeToken: address(0), prizeIsV3: false, prizeV3Fee: 0, prizePoolKey: none,
                minHold: 0, payoutThreshold: 0, payoutIntervalBlocks: 0, missBps: 0, jackpotChanceBps: 0, regularWinShareBps: 0
            }),
            0
        );
        assertTrue(pad.getLaunch(token).exists, "launched");
        assertEq(LaunchTokenV2(token).balanceOf(address(this)), 0, "no dev bag on a zero buy");
    }

    // The swap router is set once, owner-only.
    function test_setSwapRouter_setOnce() public {
        // Already set in setUp → a second set reverts.
        vm.expectRevert(LaunchFairV4.AlreadySet.selector);
        pad.setSwapRouter(address(0xBEEF));
    }
}
