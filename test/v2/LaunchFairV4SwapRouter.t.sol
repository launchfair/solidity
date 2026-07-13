// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LaunchFairV4SwapRouter, IWETH} from "../../src/v2/v4/LaunchFairV4SwapRouter.sol";

contract MockTok is ERC20 {
    constructor() ERC20("Tok", "TOK") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @notice Buy/sell a WETH-paired V4 token through the router with native ETH, over a
/// real PoolManager pool with two-sided liquidity.
contract LaunchFairV4SwapRouterTest is Test, Deployers {
    WETH weth;
    MockTok token;
    LaunchFairV4SwapRouter router;
    PoolKey poolKey;
    bool wethIsCurrency0;

    address constant ALICE = address(0xA11CE);

    function setUp() public {
        deployFreshManagerAndRouters();
        weth = new WETH();
        token = new MockTok();

        // Fund this contract with WETH + token to seed liquidity.
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 50 ether}();

        wethIsCurrency0 = address(weth) < address(token);
        (Currency c0, Currency c1) = wethIsCurrency0
            ? (Currency.wrap(address(weth)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(weth)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Approve + add wide two-sided liquidity around 1:1.
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100 ether, salt: 0}),
            ""
        );

        router = new LaunchFairV4SwapRouter(manager, IWETH(address(weth)));
    }

    function test_buy_withEth_deliversTokens() public {
        vm.deal(ALICE, 5 ether);
        uint256 ethBefore = ALICE.balance;

        vm.prank(ALICE);
        uint256 out = router.buy{value: 1 ether}(poolKey, 0, ALICE, block.timestamp + 1);

        assertGt(out, 0, "received tokens");
        assertEq(token.balanceOf(ALICE), out, "tokens landed with ALICE");
        assertEq(ALICE.balance, ethBefore - 1 ether, "spent exactly 1 ETH");
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(weth.balanceOf(address(router)), 0, "router holds no WETH");
    }

    function test_sell_forEth_returnsEth() public {
        // ALICE first buys so she has tokens to sell.
        vm.deal(ALICE, 5 ether);
        vm.prank(ALICE);
        uint256 bought = router.buy{value: 1 ether}(poolKey, 0, ALICE, block.timestamp + 1);

        uint256 ethBefore = ALICE.balance;
        vm.startPrank(ALICE);
        IERC20(address(token)).approve(address(router), bought);
        uint256 ethOut = router.sell(poolKey, bought, 0, ALICE, block.timestamp + 1);
        vm.stopPrank();

        assertGt(ethOut, 0, "received ETH");
        assertEq(ALICE.balance, ethBefore + ethOut, "ETH landed with ALICE");
        assertEq(token.balanceOf(ALICE), 0, "sold all tokens");
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(weth.balanceOf(address(router)), 0, "router holds no WETH");
        // Round-trip (minus fees + slippage) should be less than the 1 ETH put in.
        assertLt(ethOut, 1 ether, "round-trip costs fees");
    }

    function test_buy_slippageReverts() public {
        vm.deal(ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(LaunchFairV4SwapRouter.Slippage.selector);
        router.buy{value: 1 ether}(poolKey, type(uint256).max, ALICE, block.timestamp + 1);
    }

    function test_buy_expiredReverts() public {
        vm.deal(ALICE, 5 ether);
        vm.warp(1000);
        vm.prank(ALICE);
        vm.expectRevert(LaunchFairV4SwapRouter.Expired.selector);
        router.buy{value: 1 ether}(poolKey, 0, ALICE, 999);
    }

    function test_buy_rejectsNonWethPool() public {
        MockTok other = new MockTok();
        (Currency c0, Currency c1) = address(token) < address(other)
            ? (Currency.wrap(address(token)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(token)));
        PoolKey memory bad = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        vm.deal(ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(LaunchFairV4SwapRouter.BadPool.selector);
        router.buy{value: 1 ether}(bad, 0, ALICE, block.timestamp + 1);
    }
}
