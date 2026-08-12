// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — stock-paired router. See the stock-pair design notes + audit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {IV3SwapRouter} from "../../interfaces/IUniswapV3.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ICreatorRegistry {
    function creatorOf(address token) external view returns (address);
}

/// @notice The launchpad's launch record + the per-quote V3 fee tier the router needs to route.
interface ILaunchpadV4 {
    struct Launch {
        address creator;
        PoolKey key;
        uint24 fee;
        address quoteToken; // 0 for WETH-paired tokens; the stock token for stock-paired ones
        bool exists;
    }

    function getLaunch(address token) external view returns (Launch memory);
    function creatorOf(address token) external view returns (address);
    function quoteV3Fee(address stock) external view returns (uint24);
}

/// @notice Router for **stock-paired** launch tokens: users buy with native ETH and sell for ETH,
/// while the token's liquidity pool is `TOKEN/<stock>` (e.g. `TOKEN/AAPL`) on our Uniswap-V4 stack.
/// The `<stock>/WETH` liquidity lives on Uniswap V3, so each trade is a 2-hop route:
///
///   BUY:  ETH → WETH (wrap) → [skim WETH fee] → V3(WETH→stock) → V4(stock→TOKEN) → TOKEN to user
///   SELL: TOKEN (pulled) → V4(TOKEN→stock) → V3(stock→WETH) → [skim WETH fee] → unwrap → ETH to user
///
/// The fee is always taken **in WETH at the router** (the WETH leg, both ways — no token sell
/// pressure), then split treasury/dev/flagship exactly like the WETH-paired path, so **dev-fee
/// economics are unchanged**. The stock pool itself is a 0-fee, `RouterGateHook`-gated pool, so no
/// LP fees accrue and nobody can bypass this router.
///
/// Stateless w.r.t. positions; the only held balance is accrued WETH fees pending `distribute`.
contract StockPairRouter is IUnlockCallback, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    uint16 public constant BPS = 10_000;
    /// @notice Hard cap on the router fee (of the WETH leg). 1000 = 10%.
    uint16 public constant MAX_FEE_BPS = 1_000;

    IPoolManager public immutable poolManager;
    IWETH public immutable weth;
    IV3SwapRouter public immutable v3Router; // SwapRouter02 for the <stock>/WETH hop
    ILaunchpadV4 public immutable launchpad; // resolves each token's pool + quote stock + V3 fee tier

    /// @notice Fee in bps of the WETH leg, charged on both buys and sells. Owner-settable, ≤ cap.
    uint16 public feeBps;
    /// @notice WETH fees accrued per token, pending `distribute`.
    mapping(address token => uint256) public accrued;

    // ── fee-split config (owner-settable). Stock tokens are Base (no mechanism), so the mechanism
    //    slice folds into the flagship — matching the WethFeeHook's behavior for plain tokens. ──
    address public treasury; // platform treasury (fallback for any unset destination)
    address public flagshipSink; // flagship buyback
    uint16 public treasuryBps = 2_500; // 25%
    uint16 public devBps = 2_500; // 25%
    uint16 public mechanismBps = 4_000; // 40% → folds to flagship (Base tokens)
    uint16 public flagshipBps = 1_000; // 10%  — the four MUST sum to BPS

    event Bought(address indexed token, address indexed buyer, address indexed to, uint256 ethIn, uint256 tokensOut);
    event Sold(address indexed token, address indexed seller, address indexed to, uint256 tokensIn, uint256 ethOut);
    event FeeAccrued(address indexed token, bool isBuy, uint256 wethFee);
    event Distributed(address indexed token, uint256 toTreasury, uint256 toDev, uint256 toFlagship);
    event FeeBpsSet(uint16 feeBps);
    event SplitSet(uint16 treasuryBps, uint16 devBps, uint16 mechanismBps, uint16 flagshipBps);
    event DestinationsSet(address treasury, address flagshipSink);

    error OnlyPoolManager();
    error Slippage();
    error Expired();
    error ZeroAmount();
    error NotStockToken();
    error EthTransferFailed();
    error InvalidFeeBps();
    error InvalidSplit();
    error NotConfigured();

    constructor(
        address owner_,
        IPoolManager pm_,
        IWETH weth_,
        IV3SwapRouter v3Router_,
        ILaunchpadV4 launchpad_,
        uint16 feeBps_
    ) Ownable(owner_) {
        if (
            address(pm_) == address(0) || address(weth_) == address(0) || address(v3Router_) == address(0)
                || address(launchpad_) == address(0)
        ) revert NotConfigured();
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFeeBps();
        poolManager = pm_;
        weth = weth_;
        v3Router = v3Router_;
        launchpad = launchpad_;
        feeBps = feeBps_;
    }

    // ── admin ────────────────────────────────────────────────────────────────
    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert InvalidFeeBps();
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

    function setSplit(uint16 t, uint16 d, uint16 m, uint16 f) external onlyOwner {
        if (uint256(t) + d + m + f != BPS) revert InvalidSplit();
        treasuryBps = t;
        devBps = d;
        mechanismBps = m;
        flagshipBps = f;
        emit SplitSet(t, d, m, f);
    }

    function setDestinations(address treasury_, address flagshipSink_) external onlyOwner {
        treasury = treasury_;
        flagshipSink = flagshipSink_;
        emit DestinationsSet(treasury_, flagshipSink_);
    }

    // ── trade ────────────────────────────────────────────────────────────────
    /// @notice Buy `token` with native ETH. Routes ETH→WETH→stock→TOKEN; the WETH fee is skimmed
    /// before the stock hop. `minOut` is the minimum TOKEN delivered to `to`.
    function buy(address token, uint256 minOut, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert ZeroAmount();
        (PoolKey memory key, address stock, uint24 v3Fee) = _resolve(token);

        weth.deposit{value: msg.value}(); // wrap ETH → WETH
        uint256 fee = (msg.value * feeBps) / BPS; // skim the fee off the WETH in
        if (fee > 0) {
            accrued[token] += fee;
            emit FeeAccrued(token, true, fee);
        }
        // Hop 1: WETH → stock on V3.
        uint256 stockAmt = _v3ExactIn(address(weth), stock, v3Fee, msg.value - fee);
        // Hop 2: stock → TOKEN on our V4 pool, delivered straight to `to`.
        uint256 stockSpent;
        (out, stockSpent) =
            abi.decode(poolManager.unlock(abi.encode(key, stock, stockAmt, token, to)), (uint256, uint256));
        if (out < minOut) revert Slippage();
        // Partial fill (buy walked the whole token curve — practically impossible): return the
        // unspent stock to the buyer rather than strand it in the router.
        if (stockSpent < stockAmt) IERC20(stock).safeTransfer(to, stockAmt - stockSpent);
        emit Bought(token, msg.sender, to, msg.value, out);
    }

    /// @notice Sell `amountIn` of `token` for native ETH. Requires the caller to have approved this
    /// router for `amountIn`. Routes TOKEN→stock→WETH; the WETH fee is skimmed from the WETH out.
    /// `minOut` is the minimum ETH delivered to `to`.
    function sell(address token, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        (PoolKey memory key, address stock, uint24 v3Fee) = _resolve(token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        // Hop 1: TOKEN → stock on our V4 pool (stock comes to the router).
        uint256 stockAmt;
        uint256 tokenSpent;
        (stockAmt, tokenSpent) =
            abi.decode(poolManager.unlock(abi.encode(key, token, amountIn, stock, address(this))), (uint256, uint256));
        if (tokenSpent < amountIn) IERC20(token).safeTransfer(msg.sender, amountIn - tokenSpent);
        // Hop 2: stock → WETH on V3.
        uint256 wethOut = _v3ExactIn(stock, address(weth), v3Fee, stockAmt);
        // Skim the fee off the WETH out.
        uint256 fee = (wethOut * feeBps) / BPS;
        out = wethOut - fee;
        if (fee > 0) {
            accrued[token] += fee;
            emit FeeAccrued(token, false, fee);
        }
        if (out < minOut) revert Slippage();
        weth.withdraw(out); // unwrap WETH → ETH
        (bool ok,) = to.call{value: out}("");
        if (!ok) revert EthTransferFailed();
        emit Sold(token, msg.sender, to, amountIn, out);
    }

    /// @dev V3 exact-input single-hop swap, output to this router. Slippage is enforced by the
    /// caller's final `minOut` (buy: TOKEN out; sell: ETH out), so intermediate min is 0.
    function _v3ExactIn(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).forceApprove(address(v3Router), amountIn);
        amountOut = v3Router.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev PoolManager flash-accounting callback for the V4 hop: swap `amountIn` of `inputCur` for
    /// `outputCur` (exact input), pay the input owed, and take the output to `recipient`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, address inputCur, uint256 amountIn, address outputCur, address recipient) =
            abi.decode(data, (PoolKey, address, uint256, address, address));

        bool zeroForOne = Currency.unwrap(key.currency0) == inputCur;
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 owed = uint256(int256(-inDelta));
        uint256 got = uint256(int256(outDelta));

        poolManager.sync(Currency.wrap(inputCur));
        IERC20(inputCur).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        poolManager.take(Currency.wrap(outputCur), recipient, got);

        return abi.encode(got, owed); // (received, input actually spent)
    }

    // ── fees ─────────────────────────────────────────────────────────────────
    /// @notice Distribute a token's accrued WETH fees through the split (permissionless). The router
    /// already holds the fee as real WETH, so this is a plain fan-out (no PoolManager redeem needed).
    /// Dev = the token's creator (`creatorOf`); every unset destination falls back to treasury. The
    /// mechanism slice folds into the flagship (stock tokens are Base — no reward/lottery mechanism).
    function distribute(address token) external nonReentrant returns (uint256 amount) {
        amount = accrued[token];
        if (amount == 0) return 0;
        if (treasury == address(0)) revert NotConfigured();
        accrued[token] = 0;

        IERC20 w = IERC20(address(weth));
        uint256 toTreasury = (amount * treasuryBps) / BPS;
        uint256 toDev = (amount * devBps) / BPS;
        // flagship gets its own slice + the folded mechanism slice + any rounding dust (remainder).
        uint256 toFlagship = amount - toTreasury - toDev;

        address sink = flagshipSink == address(0) ? treasury : flagshipSink;
        if (toTreasury > 0) w.safeTransfer(treasury, toTreasury);
        if (toDev > 0) {
            address dev = launchpad.creatorOf(token);
            w.safeTransfer(dev == address(0) ? treasury : dev, toDev);
        }
        if (toFlagship > 0) w.safeTransfer(sink, toFlagship);
        emit Distributed(token, toTreasury, toDev, toFlagship);
    }

    // ── internals ──────────────────────────────────────────────────────────────
    /// @dev Resolve a stock token's V4 pool key, its quote stock, and the stock's V3 fee tier.
    function _resolve(address token) internal view returns (PoolKey memory key, address stock, uint24 v3Fee) {
        ILaunchpadV4.Launch memory l = launchpad.getLaunch(token);
        if (!l.exists || l.quoteToken == address(0)) revert NotStockToken();
        key = l.key;
        stock = l.quoteToken;
        v3Fee = launchpad.quoteV3Fee(stock);
    }

    /// @dev Receive ETH only from unwrapping WETH.
    receive() external payable {
        if (msg.sender != address(weth)) revert EthTransferFailed();
    }
}
