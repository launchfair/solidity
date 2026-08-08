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
import {WethFeeHook} from "../../src/v2/v4/WethFeeHook.sol";
import {HookMiner} from "../../script/HookMiner.sol";

contract HookMockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract WethFeeHookTest is Test, Deployers {
    WethFeeHook hook;
    HookMockToken weth;
    HookMockToken token;
    PoolKey poolKey;
    bool tokenIsCurrency0;

    address constant TREASURY = address(0x7EA);
    address constant FLAGSHIP = address(0xF1A);
    uint16 constant FEE_BPS = 100; // 1% of the WETH leg

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new HookMockToken("WETH", "WETH");
        token = new HookMockToken("TOK", "TOK");
        token.mint(address(this), 1_000_000_000 ether);
        weth.mint(address(this), 10_000_000 ether);

        // Deploy the hook at an address whose low bits encode exactly its permissions.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4444) << 144));
        deployCodeTo("WethFeeHook.sol:WethFeeHook", abi.encode(address(this), manager, address(weth), FEE_BPS), hookAddr);
        hook = WethFeeHook(hookAddr);
        // dev + mechanism fold into treasury here (launchpad + distributor left unset).
        hook.setDestinations(TREASURY, address(0), FLAGSHIP, address(0));

        tokenIsCurrency0 = address(token) < address(weth);
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(token)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddr)});
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Two-sided liquidity so both buys and sells execute.
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

    function test_buy_takesWethFeeFromInput() public {
        uint256 wethIn = 1 ether;
        weth.approve(address(swapRouter), wethIn);
        _swap(!tokenIsCurrency0, wethIn); // WETH is input
        uint256 expected = (wethIn * FEE_BPS) / 10_000;
        assertEq(hook.accrued(address(token)), expected, "hook accrued 1% of the WETH input (held as a claim)");
    }

    function test_sell_takesWethFeeFromOutput_noTokenTaken() public {
        uint256 tokenIn = 10_000 ether;
        token.approve(address(swapRouter), tokenIn);
        uint256 hookTokBefore = token.balanceOf(address(hook));
        _swap(tokenIsCurrency0, tokenIn); // token is input, WETH is output
        assertGt(hook.accrued(address(token)), 0, "hook accrued a WETH fee on the sell");
        assertEq(token.balanceOf(address(hook)), hookTokBefore, "hook took NO token -> no sell pressure");
    }

    function test_distribute_splitsFourWays() public {
        weth.approve(address(swapRouter), 1 ether);
        _swap(!tokenIsCurrency0, 1 ether);
        uint256 acc = hook.accrued(address(token));
        assertGt(acc, 0);
        hook.distribute(address(token));
        assertEq(hook.accrued(address(token)), 0, "accrual cleared");
        // Defaults 25/25/40/10. dev folds into treasury (launchpad unset); this token has no
        // reward/lottery mechanism, so its mechanism slice folds into the flagship. Net: treasury
        // gets treasury+dev (50%), flagship gets flagship+mechanism (50%).
        uint256 tre = (acc * 2500) / 10_000 + (acc * 2500) / 10_000;
        uint256 flag = acc - tre;
        assertEq(weth.balanceOf(TREASURY), tre, "treasury + dev = 50%");
        assertEq(weth.balanceOf(FLAGSHIP), flag, "flagship + mechanism = 50%");
    }

    function test_setSplit_mustSumToBps() public {
        vm.expectRevert(WethFeeHook.InvalidSplit.selector);
        hook.setSplit(3000, 3000, 3000, 3000); // sums to 12000
    }

    function test_hookMiner_findsPermissionedAddress() public view {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(this), manager, address(weth), uint16(100));
        (address a,) = HookMiner.find(address(0x4e59b44847b379578588920cA78FbF26c0B4956C), flags, type(WethFeeHook).creationCode, args);
        assertEq(uint160(a) & 0x3FFF, flags, "mined address encodes the hook permissions");
    }

    // ── exact-OUTPUT fee legs (M-1) ────────────────────────────────────────────────
    function _swapExactOut(bool zeroForOne, uint256 amountOut) internal {
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountOut), // positive = exact-output
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // Exact-output BUY: WETH in, exactly N tokens out. Fee taken in WETH from the (unspecified)
    // input leg in afterSwap; the hook takes NO token.
    function test_exactOutputBuy_takesWethFee_noTokenTaken() public {
        weth.approve(address(swapRouter), type(uint256).max);
        uint256 hookTokBefore = token.balanceOf(address(hook));
        uint256 myTokBefore = token.balanceOf(address(this));
        _swapExactOut(!tokenIsCurrency0, 1_000 ether); // WETH -> exact 1000 token
        assertEq(token.balanceOf(address(this)) - myTokBefore, 1_000 ether, "got exactly the requested token");
        assertGt(hook.accrued(address(token)), 0, "WETH fee accrued on an exact-output buy");
        assertEq(token.balanceOf(address(hook)), hookTokBefore, "hook took NO token");
    }

    // Exact-output SELL: token in, exactly M WETH out. Fee taken in WETH from the (specified)
    // output leg in beforeSwap; the swapper still receives EXACTLY M, and NO token is taken.
    function test_exactOutputSell_takesWethFee_swapperGetsExactWeth() public {
        uint256 wethOut = 1 ether;
        token.approve(address(swapRouter), type(uint256).max);
        uint256 myWethBefore = weth.balanceOf(address(this));
        uint256 hookTokBefore = token.balanceOf(address(hook));
        _swapExactOut(tokenIsCurrency0, wethOut); // token -> exact 1 WETH
        assertEq(weth.balanceOf(address(this)) - myWethBefore, wethOut, "swapper got EXACTLY the requested WETH");
        assertEq(hook.accrued(address(token)), (wethOut * FEE_BPS) / 10_000, "fee = feeBps of the WETH out");
        assertEq(token.balanceOf(address(hook)), hookTokBefore, "hook took NO token -> no sell pressure");
    }

    // L-1: the fee is capped so an owner fat-finger can't set a swap-bricking fee.
    function test_setFeeBps_capEnforced() public {
        uint16 cap = hook.MAX_FEE_BPS();
        vm.expectRevert(WethFeeHook.InvalidFeeBps.selector);
        hook.setFeeBps(cap + 1);
        hook.setFeeBps(cap); // exactly the cap is allowed
        assertEq(hook.feeBps(), cap);
    }

    // The global fee rate applies to ALL tokens on the hook, live or new — a `setFeeBps` change is
    // read at swap time, so it takes effect immediately for every existing pool.
    function test_globalFeeBps_appliesToLivePools() public {
        weth.approve(address(swapRouter), type(uint256).max);
        uint256 firstFee = (1 ether * uint256(FEE_BPS)) / 10_000;
        _swap(!tokenIsCurrency0, 1 ether); // buy at the initial 1%
        assertEq(hook.accrued(address(token)), firstFee, "1% at first");

        hook.setFeeBps(300); // 3% now — applies to the SAME already-live pool
        _swap(!tokenIsCurrency0, 1 ether);
        uint256 second = hook.accrued(address(token)) - firstFee;
        assertEq(second, (1 ether * 300) / 10_000, "the new global 3% took effect on the live pool");
    }
}
