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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WethFeeHookImmutable} from "../../src/v2/v4/WethFeeHookImmutable.sol";

contract ImmToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 a) external { _burn(msg.sender, a); (bool ok,) = msg.sender.call{value: a}(""); require(ok, "w"); }
    receive() external payable { _mint(msg.sender, msg.value); }
}

/// A token that reports a non-Base mode so the hook funds its mechanism instead of folding.
contract ModeToken is ImmToken {
    uint8 private _mode;
    constructor(string memory n, string memory s) ImmToken(n, s) {}
    function setMode(uint8 x) external { _mode = x; }
    function mode() external view returns (uint8) { return _mode; }
}

/// Records the WETH the hook routes to a token's mechanism via notify().
contract MockDistributor {
    uint256 public got;
    function notify(address, uint256 amt) external { got += amt; }
}

/// Minimal launchpad exposing getLaunch/creatorOf so the hook can read a token's tier + creator.
contract MockPad {
    struct L { address creator; PoolKey key; uint24 fee; address quoteToken; bool exists; }
    mapping(address => L) internal _l;
    function setLaunch(address token, address creator, uint24 fee) external {
        _l[token].creator = creator; _l[token].fee = fee; _l[token].exists = true;
    }
    function getLaunch(address token) external view returns (L memory) { return _l[token]; }
    function creatorOf(address token) external view returns (address) { return _l[token].creator; }
}

contract WethFeeHookImmutableTest is Test, Deployers {
    WethFeeHookImmutable hook;
    ImmToken weth;
    ImmToken token;
    MockPad pad;
    PoolKey poolKey;
    bool tokenIsCurrency0;

    address constant TREASURY = address(0x7EA);
    address constant FLAGSHIP = address(0xF1A);
    uint16 constant FEE_BPS = 100; // 1% global fallback

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new ImmToken("WETH", "WETH");
        vm.deal(address(weth), 10_000 ether);
        token = new ImmToken("TOK", "TOK");
        token.mint(address(this), 1_000_000_000 ether);
        weth.mint(address(this), 10_000_000 ether);

        pad = new MockPad();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4444) << 144));
        // Config is BAKED IN at construction — no setters afterward.
        deployCodeTo(
            "WethFeeHookImmutable.sol:WethFeeHookImmutable",
            abi.encode(manager, address(weth), FEE_BPS, TREASURY, address(0), FLAGSHIP, address(pad)),
            hookAddr
        );
        hook = WethFeeHookImmutable(payable(hookAddr));

        tokenIsCurrency0 = address(token) < address(weth);
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(token)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddr)});
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
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

    // ── the config is FROZEN at construction ──────────────────────────────────────
    function test_configIsImmutable() public view {
        assertEq(hook.feeBps(), FEE_BPS, "feeBps baked in");
        assertEq(hook.treasury(), TREASURY, "treasury baked in");
        assertEq(hook.flagshipSink(), FLAGSHIP, "flagship baked in");
        assertEq(hook.launchpad(), address(pad), "launchpad baked in");
        assertEq(hook.BASE_FEE_BPS(), 100, "1% base");
        assertEq(hook.DEV_TRADE_BPS(), 40, "dev 0.4% of trade, flat");
        assertEq(hook.BUYBACK_TRADE_BPS(), 20, "buyback 0.2% of trade, flat");
        assertEq(hook.TREASURY_BASE_TRADE_BPS(), 10, "treasury 0.1% base, flat");
        assertEq(hook.TREASURY_NOTCH_BPS(), 200, "+2% of the fee-above-1%");
    }

    // ── NO admin surface: the exact selectors a scanner flags do not exist ─────────
    function test_noAdminSetters() public {
        (bool a,) = address(hook).call(abi.encodeWithSignature("setFeeBps(uint16)", uint16(500)));
        assertFalse(a, "setFeeBps must not exist (HiddenFees)");
        (bool b,) = address(hook).call(
            abi.encodeWithSignature("setDestinations(address,address,address,address)", TREASURY, address(0), FLAGSHIP, address(pad))
        );
        assertFalse(b, "setDestinations must not exist (LiquidityDrain)");
        (bool c,) = address(hook).call(
            abi.encodeWithSignature("setSplit(uint16,uint16,uint16,uint16)", uint16(2500), uint16(2500), uint16(4000), uint16(1000))
        );
        assertFalse(c, "setSplit must not exist (Other)");
        (bool d,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(d, "no owner (ownerless)");
        (bool e,) = address(hook).call(abi.encodeWithSignature("setSideBps(uint24,uint16)", uint24(30000), uint16(500)));
        assertFalse(e, "per-tier split not settable either");
    }

    // ── fees still work: global fallback ──────────────────────────────────────────
    function test_buy_globalFallback_takesWethFee() public {
        uint256 wethIn = 1 ether;
        weth.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, wethIn); // token NOT in the launch record → global 1%
        assertEq(hook.accrued(address(token)), (wethIn * FEE_BPS) / 10_000, "1% global fee accrued");
    }

    // ── per-tier RATE, flat 50/30/10/10 SPLIT ─────────────────────────────────────
    // Flat take + scaling protocol. At the 10% tier the collected fee splits (as % of the trade):
    // dev 0.4 / treasury 0.28 (0.1 base + 2% of the 9% extra) / buyback 0.2 flat / protocol 9.12.
    // This token exposes no mode() and the distributor is unset, so its protocol slice folds into the
    // buyback -> buyback gets 0.2 + 9.12 = 9.32% of the trade (93.2% of the collected fee).
    function test_tierRate_flatSplit_baseFoldsToBuyback() public {
        pad.setLaunch(address(token), address(0xDEF), 100_000); // 10% tier, creator 0xDEF

        weth.approve(address(swapRouter), type(uint256).max);
        _swap(!tokenIsCurrency0, 1 ether);
        uint256 acc = hook.accrued(address(token));
        assertEq(acc, (1 ether * 1000) / 10_000, "10% tier charged, not global 1%");

        uint256 toTreasury = (acc * 28) / 1000; // 0.28% of trade = 2.8% of the 10% fee
        uint256 toDev = (acc * 40) / 1000; // 0.4% of trade = 4% of the fee
        hook.distribute(address(token));
        assertEq(TREASURY.balance, toTreasury, "treasury flat 0.1% + 2% notch = 0.28% of trade");
        assertEq(address(0xDEF).balance, toDev, "creator PAID flat 0.4% of trade");
        // buyback (flagship) = its flat 0.2% + the folded scaling protocol = the rest.
        assertEq(FLAGSHIP.balance, acc - toTreasury - toDev, "buyback got flat 0.2% + folded protocol");
        assertEq(hook.accrued(address(token)), 0, "accrual cleared");
    }

    // ── MODE token at the 10% tier: the SCALING protocol slice (~9.12% of the trade) funds the
    // token's mechanism; dev/treasury/buyback stay flat (0.4 / 0.28 / 0.2% of the trade) ──
    function test_modeToken_protocolScales_flatTake() public {
        MockDistributor dist = new MockDistributor();
        ModeToken mtoken = new ModeToken("MODE", "MODE");
        mtoken.setMode(1); // Reward mode -> _hasMechanism true
        mtoken.mint(address(this), 1_000_000_000 ether);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x5555) << 144));
        deployCodeTo(
            "WethFeeHookImmutable.sol:WethFeeHookImmutable",
            abi.encode(manager, address(weth), FEE_BPS, TREASURY, address(dist), FLAGSHIP, address(pad)),
            hookAddr
        );
        WethFeeHookImmutable h = WethFeeHookImmutable(payable(hookAddr));
        pad.setLaunch(address(mtoken), address(0xDEF), 100_000); // 10% tier, creator 0xDEF

        bool mIs0 = address(mtoken) < address(weth);
        (Currency c0, Currency c1) = mIs0
            ? (Currency.wrap(address(mtoken)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(mtoken)));
        PoolKey memory k = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddr)});
        manager.initialize(k, SQRT_PRICE_1_1);
        mtoken.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ""
        );

        weth.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: !mIs0,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: !mIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 acc = h.accrued(address(mtoken));
        assertEq(acc, (1 ether * 1000) / 10_000, "10% tier charged");
        uint256 tre0 = TREASURY.balance;
        uint256 fl0 = FLAGSHIP.balance;
        uint256 dev0 = address(0xDEF).balance;
        uint256 toTreasury = (acc * 28) / 1000; // 0.28% of trade
        uint256 toDev = (acc * 40) / 1000; // 0.4% of trade
        uint256 toBuyback = (acc * 20) / 1000; // 0.2% of trade, flat
        h.distribute(address(mtoken));
        assertEq(dist.got(), acc - toTreasury - toDev - toBuyback, "mechanism = the scaling protocol (~91.2%)");
        assertEq(TREASURY.balance - tre0, toTreasury, "treasury flat 0.28% of trade");
        assertEq(address(0xDEF).balance - dev0, toDev, "dev flat 0.4% of trade");
        assertEq(FLAGSHIP.balance - fl0, toBuyback, "buyback flat 0.2% (protocol NOT folded)");
    }

    // ── sells take the fee from the WETH output, never the token ──────────────────
    function test_sell_takesWethFee_noTokenTaken() public {
        token.approve(address(swapRouter), 10_000 ether);
        uint256 hookTokBefore = token.balanceOf(address(hook));
        _swap(tokenIsCurrency0, 10_000 ether);
        assertGt(hook.accrued(address(token)), 0, "WETH fee accrued on the sell");
        assertEq(token.balanceOf(address(hook)), hookTokBefore, "hook took NO token -> no sell pressure");
    }
}
