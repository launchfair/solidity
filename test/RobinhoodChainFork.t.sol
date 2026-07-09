// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {V3Launchpad} from "../src/V3Launchpad.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";

interface IPoolTrade {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface INpmPositions {
    function ownerOf(uint256 tokenId) external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IWETHMin {
    function deposit() external payable;
}

/// Fork tests against the REAL canonical Uniswap V3 on Robinhood Chain mainnet
/// (chain id 4663). This is the audit gate for the V3 integration: pool
/// creation + init, single-sided mint at our ticks, real swaps through the
/// pool (incl. the max-buy guard), fee collection, and graduation.
///
/// Run with:  RUN_FORK_TESTS=true forge test --match-contract RobinhoodChainFork -vv
contract RobinhoodChainForkTest is Test {
    // Canonical Robinhood Chain mainnet addresses (verified on-chain):
    // factory owner = aliased Uniswap governance timelock; NPM.factory() = factory,
    // NPM.WETH9() = WETH ("Uniswap V3 Positions NFT-V1").
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    string constant DEFAULT_RPC = "https://rpc.mainnet.chain.robinhood.com";

    uint128 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant INITIAL_PRICE = 1_491_146_318;
    uint256 constant GRAD_WETH = 1 ether; // WETH raised into the pool that bonds a token
    uint16 constant MAX_BUY_BPS = 200;
    uint32 constant MAX_BUY_BLOCKS = 360;
    uint256 constant CREATION_FEE = 0.000005 ether;

    // TickMath.MIN_SQRT_RATIO + 1 / MAX_SQRT_RATIO - 1
    uint160 constant MIN_SQRT = 4295128740;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    FeeLocker locker;
    V3Launchpad pad;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    bool forked;

    function setUp() public {
        if (!vm.envOr("RUN_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC", string(DEFAULT_RPC)));
        forked = true;

        locker = new FeeLocker(address(this), INonfungiblePositionManager(NPM), IERC20(WETH), treasury);
        pad = new V3Launchpad(
            address(this),
            IUniswapV3Factory(FACTORY),
            INonfungiblePositionManager(NPM),
            locker,
            WETH,
            V3Launchpad.PoolConfig({
                feeTier: 10_000,
                tickLower0: -203_200,
                tickUpper0: 887_200,
                tokenTotalSupply: TOTAL_SUPPLY,
                initialPriceWethPerToken: INITIAL_PRICE,
                graduationWethAmount: GRAD_WETH,
                maxBuyBps: MAX_BUY_BPS,
                maxBuyBlocks: MAX_BUY_BLOCKS
            }),
            "https://fun.example.xyz"
        );
        locker.setLaunchpad(address(pad));

        vm.deal(address(this), 1_000 ether);
        vm.deal(creator, 1 ether); // creation fee
        IWETHMin(WETH).deposit{value: 200 ether}();
    }

    /// Uniswap V3 swap callback: pay the pool whatever it asks for.
    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        if (d0 > 0) IERC20(IPoolTrade(msg.sender).token0()).transfer(msg.sender, uint256(d0));
        if (d1 > 0) IERC20(IPoolTrade(msg.sender).token1()).transfer(msg.sender, uint256(d1));
    }

    function _buy(address pool, bool tokenIsToken0, uint256 wethIn) internal returns (uint256 tokensOut) {
        bool zeroForOne = !tokenIsToken0; // WETH is the input side
        (int256 a0, int256 a1) =
            IPoolTrade(pool).swap(address(this), zeroForOne, int256(wethIn), zeroForOne ? MIN_SQRT : MAX_SQRT, "");
        tokensOut = uint256(-(tokenIsToken0 ? a0 : a1));
    }

    function _sell(address pool, bool tokenIsToken0, uint256 tokensIn) internal returns (uint256 wethOut) {
        bool zeroForOne = tokenIsToken0; // token is the input side
        (int256 a0, int256 a1) =
            IPoolTrade(pool).swap(address(this), zeroForOne, int256(tokensIn), zeroForOne ? MIN_SQRT : MAX_SQRT, "");
        wethOut = uint256(-(tokenIsToken0 ? a1 : a0));
    }

    function test_fork_launchOnRealUniswapV3() public {
        if (!forked) return;

        vm.prank(creator);
        address token = pad.createToken{value: CREATION_FEE}(
            "Fork Probe",
            "PROBE",
            LaunchToken.Metadata({
                logoURI: "ipfs://QmProbe", website: "https://probe.xyz", telegram: "", discord: "", twitter: ""
            }),
            bytes32(0)
        );
        V3Launchpad.LaunchInfo memory info = pad.getLaunch(token);

        // Real pool exists on the canonical factory and opened at our price.
        assertEq(info.pool, IUniswapV3Factory(FACTORY).getPool(token, WETH, 10_000));
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(info.pool).slot0();
        uint256 wethPerToken = info.tokenIsToken0
            ? Math.mulDiv(sqrtP, uint256(sqrtP) * 1e18, 1 << 192)
            : Math.mulDiv(1 << 96, 1e18, Math.mulDiv(sqrtP, sqrtP, 1 << 96));
        assertApproxEqRel(wethPerToken, INITIAL_PRICE, 1e12, "real pool must open at launch price");

        // The REAL position manager accepted our single-sided mint at our ticks
        // (proves tick-spacing alignment) and the locker owns the NFT.
        assertEq(INpmPositions(NPM).ownerOf(info.positionTokenId), address(locker), "LP NFT must be locked");
        (,,,, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            INpmPositions(NPM).positions(info.positionTokenId);
        assertEq(fee, 10_000);
        assertGt(liquidity, 0);
        if (info.tokenIsToken0) {
            assertEq(tickLower, -203_200);
            assertEq(tickUpper, 887_200);
        } else {
            assertEq(tickLower, -887_200);
            assertEq(tickUpper, 203_200);
        }

        // Essentially the whole supply is pool liquidity (dust burned).
        assertEq(IERC20(token).balanceOf(address(pad)), 0);
        assertGt(IERC20(token).totalSupply(), uint256(TOTAL_SUPPLY) - 1 ether);
    }

    function test_fork_tradeGuardClaimGraduate_endToEnd() public {
        if (!forked) return;

        vm.prank(creator);
        address token = pad.createToken{value: CREATION_FEE}("Fork Trade", "TRADE");
        V3Launchpad.LaunchInfo memory info = pad.getLaunch(token);
        uint256 cap = (uint256(TOTAL_SUPPLY) * MAX_BUY_BPS) / 10_000; // 20M tokens

        // Launch guard: a small real buy through the REAL pool works...
        uint256 got = _buy(info.pool, info.tokenIsToken0, 0.02 ether);
        assertGt(got, 0);
        assertLe(IERC20(token).balanceOf(address(this)), cap);
        assertGt(pad.curveProgress(token), 0, "curve progress must move with real buys");

        // ...but a buy that would exceed 2% of supply reverts inside the pool's
        // transfer to us ("TF" = the pool's TransferHelper wrapping MaxBuyExceeded).
        vm.expectRevert(bytes("TF"));
        _buy(info.pool, info.tokenIsToken0, 0.1 ether);

        // Guard expires after 360 (L1) blocks.
        vm.roll(block.number + MAX_BUY_BLOCKS);
        uint256 bought = _buy(info.pool, info.tokenIsToken0, 5 ether);
        assertGt(bought, cap, "whale buy must clear after expiry");

        // The 5 ETH buy bonded > 1 WETH into the real pool: milestone fires.
        assertEq(pad.curveProgress(token), 10_000);
        assertTrue(pad.checkGraduation(token));

        // Sell a chunk back: price dips but graduation is sticky, and the
        // sell accrues token-side fees in the position.
        IERC20(token).approve(info.pool, type(uint256).max);
        uint256 wethBack = _sell(info.pool, info.tokenIsToken0, bought / 4);
        assertGt(wethBack, 0);
        assertTrue(pad.getLaunch(token).graduated);

        // Claim real collected fees: WETH split 50/50, token side burned.
        uint256 supplyBefore = IERC20(token).totalSupply();
        (uint256 toTreasury, uint256 toDev, uint256 burned) = locker.claim(token);
        assertGt(toTreasury, 0, "treasury WETH share");
        assertApproxEqAbs(toDev, toTreasury, 1, "50/50 split");
        assertGt(burned, 0, "token-side fees burned");
        assertEq(IERC20(token).totalSupply(), supplyBefore - burned);
        assertEq(wethBal(creator), toDev, "dev got only WETH");
        assertEq(IERC20(token).balanceOf(creator), 0, "dev got no tokens");
    }

    /// createAndBuy: token creation + a dev buy in ONE transaction, against the
    /// REAL pool. The creator's excess ETH (above the creation fee) is wrapped,
    /// swapped through the freshly-minted pool, and the tokens land on the creator
    /// — all atomically, still under the 2% launch cap.
    function test_fork_createAndBuy_atomicDevBuy() public {
        if (!forked) return;

        uint256 devBuy = 0.02 ether;
        uint256 creatorEthBefore = creator.balance;

        vm.prank(creator);
        address token = pad.createAndBuy{value: CREATION_FEE + devBuy}(
            "Fork DevBuy",
            "DEVBUY",
            LaunchToken.Metadata({logoURI: "", website: "", telegram: "", discord: "", twitter: ""}),
            bytes32(0),
            1 // minTokensOut: just needs to net > 0
        );

        V3Launchpad.LaunchInfo memory info = pad.getLaunch(token);
        uint256 cap = (uint256(TOTAL_SUPPLY) * MAX_BUY_BPS) / 10_000;

        // Creator received the dev-bought tokens atomically, within the 2% cap.
        uint256 bal = IERC20(token).balanceOf(creator);
        assertGt(bal, 0, "creator must receive dev-bought tokens");
        assertLe(bal, cap, "dev buy must respect the 2% launch cap");

        // The buy bonded WETH into the pool: curve progress moved off zero.
        assertGt(pad.curveProgress(token), 0, "curve progress must move from the dev buy");
        assertGt(IERC20(WETH).balanceOf(info.pool), 0, "pool holds the dev-bought WETH");

        // Exactly fee + devBuy consumed; createAndBuy leaves no refund path open.
        assertEq(creator.balance, creatorEthBefore - CREATION_FEE - devBuy, "only fee+devBuy spent");

        // The launchpad keeps nothing from the swap (no WETH/token dust stranded).
        assertEq(IERC20(WETH).balanceOf(address(pad)), 0, "no WETH dust in launchpad");
        assertEq(IERC20(token).balanceOf(address(pad)), 0, "no token dust in launchpad");
    }

    /// The dev-buy slippage guard reverts the WHOLE create if the swap can't
    /// deliver at least minTokensOut — nothing is half-created.
    function test_fork_createAndBuy_slippageGuardRevertsAll() public {
        if (!forked) return;

        vm.prank(creator);
        vm.expectRevert(V3Launchpad.DevBuyTooLittle.selector);
        pad.createAndBuy{value: CREATION_FEE + 0.01 ether}(
            "Slip",
            "SLIP",
            LaunchToken.Metadata({logoURI: "", website: "", telegram: "", discord: "", twitter: ""}),
            bytes32(0),
            type(uint256).max // impossible min-out
        );
    }

    function wethBal(address who) internal view returns (uint256) {
        return IERC20(WETH).balanceOf(who);
    }
}
