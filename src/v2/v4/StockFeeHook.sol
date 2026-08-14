// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — stock-paired pool fee hook (the RouterGateHook's successor).

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IV3SwapRouter, IUniswapV3Factory, IUniswapV3Pool} from "../../interfaces/IUniswapV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ILaunchpadStockView {
    function allowedQuote(address stock) external view returns (bool);
    function quoteV3Fee(address stock) external view returns (uint24);
    function creatorOf(address token) external view returns (address);
}

interface IStockRoutesView {
    /// The StockPairRouter's owner-maintained multi-hop stock→…→WETH path (empty = direct hop).
    function sellPathOf(address stock) external view returns (bytes memory);
}

interface IWETHW {
    function withdraw(uint256) external;
}

interface IModeTokenView {
    /// LaunchTokenV2.mode() — 0 = Base (no mechanism of its own).
    function mode() external view returns (uint8);
}

interface IDistributorNotify {
    /// LaunchFairV4Distributor.notify — credit `amount` of just-transferred WETH to `token`'s
    /// mechanism (same call the V4 FeeLocker makes for WETH-paired mode tokens).
    function notify(address token, uint256 amount) external;
}

/// @notice Fee hook for stock-paired (`TOKEN/<stock>`) launch pools — replaces the RouterGateHook
/// so these pools are OPEN: any router, aggregator, or terminal can buy and sell them (no
/// TradeRestriction flag), and the fee can't be bypassed because it is charged inside the pool.
///
/// Mechanically a sibling of the audited WethFeeHook: the pool runs at LP fee 0 and this hook
/// takes `feeBps` of the QUOTE (stock) leg on every swap, all four cases (buy/sell ×
/// exact-in/out), held as ERC-6909 claims. The quote side is resolved once per pool from the
/// launchpad's `allowedQuote` allow-list and cached, so a later allow-list change can never turn
/// fees off for a live pool.
///
/// Fees accrue in the STOCK. `distribute(token, minWethOut)` (owner/treasury — a keeper call,
/// min-out guarded so the conversion can't be sandwiched) redeems the claims, converts
/// stock→WETH on Uniswap V3 using the StockPairRouter's own route config (single source of
/// truth — `sellPathOf`, falling back to the launchpad's `quoteV3Fee` direct hop), then pays the
/// 4-way split in native ETH: treasury / token creator / mechanism / flagship. Stock tokens are
/// Base-mode only, so the mechanism slice folds into the flagship — same semantics as the router.
///
/// PERMISSIONS: beforeSwap + afterSwap + both return-delta flags (identical to WethFeeHook);
/// CREATE2-mined address, validated in the constructor. Liquidity ops are not touched, so the
/// FeeLocker's single-sided launch lock is unaffected.
contract StockFeeHook is IHooks, Ownable2Step {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000; // 10% hard ceiling

    IPoolManager public immutable poolManager;
    address public immutable weth;
    IV3SwapRouter public immutable v3Router; // SwapRouter02 — the stock→WETH conversion venue
    ILaunchpadStockView public immutable launchpad; // allow-list + per-token creator
    IStockRoutesView public immutable stockRouter; // owner-maintained conversion paths

    uint16 public feeBps; // fee on the quote (stock) leg, both directions

    // ── per-pool quote cache + per-token accrual (fees held as stock 6909 claims) ──
    struct PoolInfo {
        address token; // the launch token side
        address quote; // the stock side (the "money" the fee is charged in)
    }

    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(address token => uint256) public accrued; // in the token's quote stock
    mapping(address token => address) public quoteOf;

    // ── split & destinations (all settable — a misconfig is never terminal) ──
    address public treasury; // fallback for every unset destination
    address public flagshipSink;
    uint16 public treasuryBps = 2_500; // 25%
    uint16 public devBps = 2_500; // 25%
    uint16 public mechanismBps = 4_000; // 40% → MODE tokens' distributor; folds to flagship for Base
    uint16 public flagshipBps = 1_000; // 10% — the four MUST sum to BPS
    /// The V4 distributor (setDistributor). Mechanism slices for Reward/Lottery stock tokens go
    /// here in WETH + a notify() credit, mirroring the V4 FeeLocker's WETH-pair flow.
    address public distributor;
    /// V3 factory for the permissionless claim's self-quoted floor (setClaimConfig). While
    /// unset, claimFees() is disabled and only the gated distribute() path runs.
    IUniswapV3Factory public claimV3Factory;
    /// Tolerance under the chained spot for claimFees' floor (≤ 2000). Covers per-block drift
    /// + impact; per-hop pool fees are subtracted separately.
    uint16 public claimSlippageBps = 300;

    event FeeTaken(address indexed token, address indexed quote, bool isBuy, uint256 quoteFee);
    event Distributed(
        address indexed token,
        uint256 stockIn,
        uint256 wethOut,
        uint256 toTreasury,
        uint256 toDev,
        uint256 toFlagship,
        uint256 toMechanism
    );
    event FeeBpsSet(uint16 feeBps);
    event SplitSet(uint16 treasuryBps, uint16 devBps, uint16 mechanismBps, uint16 flagshipBps);
    event DistributorSet(address distributor);
    event ClaimConfigSet(address v3Factory, uint16 slippageBps);
    event DestinationsSet(address treasury, address flagshipSink);

    error NotPoolManager();
    error NotAuthorized();
    error InvalidFeeBps();
    error InvalidSplit();
    error NotConfigured();
    error EthTransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwnerOrTreasury() {
        if (msg.sender != owner() && msg.sender != treasury) revert NotAuthorized();
        _;
    }

    constructor(
        address owner_,
        IPoolManager pm_,
        address weth_,
        IV3SwapRouter v3Router_,
        ILaunchpadStockView launchpad_,
        IStockRoutesView stockRouter_,
        uint16 feeBps_
    ) Ownable(owner_) {
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFeeBps();
        poolManager = pm_;
        weth = weth_;
        v3Router = v3Router_;
        launchpad = launchpad_;
        stockRouter = stockRouter_;
        feeBps = feeBps_;
        // Fail fast: the address must encode exactly this hook's permission bits.
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function setFeeBps(uint16 bps) external onlyOwnerOrTreasury {
        if (bps > MAX_FEE_BPS) revert InvalidFeeBps();
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

    /// @notice Retune the 4-way split (must sum to BPS). Mechanism folds to flagship at payout.
    function setSplit(uint16 t, uint16 d, uint16 m, uint16 f) external onlyOwnerOrTreasury {
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

    /// @notice The V4 distributor that funds Reward/Lottery mechanisms for stock-paired MODE
    /// tokens (stock pairs were Base-only before this). Freely re-settable, same philosophy as
    /// the other destinations — a misconfig is never terminal. While unset (or for Base tokens),
    /// the mechanism slice folds to the flagship exactly as before.
    function setDistributor(address distributor_) external onlyOwnerOrTreasury {
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    /// @notice Enable/tune the permissionless claim: the V3 factory its floor quotes from and
    /// the slippage tolerance. Freely re-settable — a misconfig is never terminal.
    function setClaimConfig(IUniswapV3Factory factory_, uint16 slippageBps_) external onlyOwnerOrTreasury {
        if (slippageBps_ > 2_000) revert InvalidSplit();
        claimV3Factory = factory_;
        claimSlippageBps = slippageBps_;
        emit ClaimConfigSet(address(factory_), slippageBps_);
    }

    /// @notice The StockPairRouter this hook shares route config with. Satisfies the launchpad's
    /// hook↔router consistency check in `setStockGateHook` (the RouterGateHook interface).
    function router() external view returns (address) {
        return address(stockRouter);
    }

    /// @dev Resolve (and cache) which side of the pool is the stock quote. Resolution uses the
    /// launchpad's quote allow-list ONCE per pool; after that the cache is authoritative, so
    /// un-allowing a stock later never makes its live pools trade fee-free. Returns a zero quote
    /// for pools where neither side is an allowed stock (fee is skipped, swap proceeds).
    function _pool(PoolKey calldata key) internal returns (address token, address quote) {
        PoolId id = key.toId();
        PoolInfo memory p = poolInfo[id];
        if (p.quote != address(0)) return (p.token, p.quote);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (launchpad.allowedQuote(c0)) (token, quote) = (c1, c0);
        else if (launchpad.allowedQuote(c1)) (token, quote) = (c0, c1);
        else return (address(0), address(0));
        poolInfo[id] = PoolInfo({token: token, quote: quote});
        quoteOf[token] = quote;
    }

    // ── the fee: the quote (stock) leg, all four swap cases ──────────────────────
    /// @dev Charges when the quote leg is the SPECIFIED currency (exact-input buy: stock in;
    /// exact-output sell: stock out). Mirrors WethFeeHook.beforeSwap with quote in WETH's role.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (feeBps != 0 && params.amountSpecified != 0) {
            (address tk, address quote) = _pool(key);
            if (quote != address(0)) {
                bool exactIn = params.amountSpecified < 0;
                address c0 = Currency.unwrap(key.currency0);
                address specified = (params.zeroForOne == exactIn) ? c0 : Currency.unwrap(key.currency1);
                if (specified == quote) {
                    uint256 amt = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
                    uint256 fee = (amt * feeBps) / BPS;
                    if (fee > 0) {
                        poolManager.mint(address(this), uint256(uint160(quote)), fee); // claim, not a physical take
                        accrued[tk] += fee;
                        emit FeeTaken(tk, quote, exactIn, fee); // exactIn ⇒ buy (stock in)
                        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), int128(0)), 0);
                    }
                }
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Charges when the quote leg is the UNSPECIFIED currency (exact-input sell: stock out;
    /// exact-output buy: stock in). beforeSwap/afterSwap are mutually exclusive per swap.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (feeBps != 0 && params.amountSpecified != 0) {
            (address tk, address quote) = _pool(key);
            if (quote != address(0)) {
                bool exactIn = params.amountSpecified < 0;
                address c0 = Currency.unwrap(key.currency0);
                address unspecified = (params.zeroForOne == exactIn) ? Currency.unwrap(key.currency1) : c0;
                if (unspecified == quote) {
                    int256 d = int256(quote == c0 ? delta.amount0() : delta.amount1());
                    uint256 mag = uint256(d >= 0 ? d : -d);
                    uint256 fee = (mag * feeBps) / BPS;
                    if (fee > 0) {
                        poolManager.mint(address(this), uint256(uint160(quote)), fee); // claim, not a physical take
                        accrued[tk] += fee;
                        emit FeeTaken(tk, quote, !exactIn, fee); // exactIn ⇒ sell (stock out)
                        return (IHooks.afterSwap.selector, int128(int256(fee)));
                    }
                }
            }
        }
        return (IHooks.afterSwap.selector, int128(0));
    }

    // ── distribute: stock claims → real stock → WETH → 4-way ETH split ───────────
    /// @notice Redeem a token's accrued stock fees, convert them to WETH, and split. Owner/
    /// treasury variant with an EXPLICIT min-out — the keeper's batching entry point.
    function distribute(address token, uint256 minWethOut) external onlyOwnerOrTreasury returns (uint256 wethOut) {
        return _distribute(token, minWethOut);
    }

    /// @notice PERMISSIONLESS claim: anyone — most naturally the token's creator pressing the
    /// site's "Claim fees" button — can trigger the conversion + split. Nobody can redirect a
    /// wei of it (every share goes to its fixed recipient: treasury, creatorOf(token), the
    /// distributor mechanism, the flagship sink), and the caller cannot rig the conversion:
    /// the min-out is SELF-QUOTED on-chain from the sell route's pool spots × (1 −
    /// `claimSlippageBps`), same defense as FlagshipBuyback.buyback(). Requires the claim
    /// config (v3Factory) to be set; until then only the gated distribute() works.
    function claimFees(address token) external returns (uint256 wethOut) {
        if (address(claimV3Factory) == address(0)) revert NotConfigured();
        uint256 amount = accrued[token];
        if (amount == 0) return 0;
        return _distribute(token, _claimFloor(quoteOf[token], amount));
    }

    function _distribute(address token, uint256 minWethOut) internal returns (uint256 wethOut) {
        uint256 amount = accrued[token];
        if (amount == 0) return 0;
        if (treasury == address(0)) revert NotConfigured();
        address quote = quoteOf[token];
        accrued[token] = 0;
        bytes memory res = poolManager.unlock(abi.encode(token, quote, amount, minWethOut));
        wethOut = abi.decode(res, (uint256));
    }

    /// @dev Expected WETH out for `amountIn` of `quote` along the router's sell route (or the
    /// direct `quoteV3Fee` hop), chained from each hop pool's spot price in RAW wei terms
    /// (decimals cancel across hops), minus each hop's pool fee and `claimSlippageBps` once.
    function _claimFloor(address quote, uint256 amountIn) internal view returns (uint256) {
        bytes memory path = stockRouter.sellPathOf(quote);
        uint256 amt = amountIn;
        uint256 feeSumBps = uint256(claimSlippageBps);
        if (path.length == 0) {
            uint24 fee = launchpad.quoteV3Fee(quote);
            amt = _spotOut(quote, weth, fee, amt);
            feeSumBps += uint256(fee) / 100;
        } else {
            // path = tokenIn(20) ++ [fee(3) ++ tokenOut(20)]…
            address tokenIn = _addrAt(path, 0);
            uint256 off = 20;
            while (off + 23 <= path.length) {
                uint24 fee = _feeAt(path, off);
                address tokenOut = _addrAt(path, off + 3);
                amt = _spotOut(tokenIn, tokenOut, fee, amt);
                feeSumBps += uint256(fee) / 100;
                tokenIn = tokenOut;
                off += 23;
            }
        }
        if (feeSumBps >= BPS) return 0;
        return (amt * (BPS - feeSumBps)) / BPS;
    }

    /// @dev Raw-wei spot conversion through one V3 pool (two mulDivs against sqrtPriceX96²).
    function _spotOut(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn) internal view returns (uint256) {
        address pool = claimV3Factory.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert NotConfigured();
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        bool inIsToken0 = tokenIn < tokenOut;
        return inIsToken0
            ? Math.mulDiv(Math.mulDiv(amountIn, sqrtP, 1 << 96), sqrtP, 1 << 96)
            : Math.mulDiv(Math.mulDiv(amountIn, 1 << 96, sqrtP), 1 << 96, sqrtP);
    }

    function _addrAt(bytes memory path, uint256 pos) private pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(path, 32), pos)))
        }
    }

    function _feeAt(bytes memory path, uint256 pos) private pure returns (uint24 f) {
        assembly {
            f := shr(232, mload(add(add(path, 32), pos)))
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, address quote, uint256 amount, uint256 minWethOut) =
            abi.decode(data, (address, address, uint256, uint256));
        poolManager.burn(address(this), uint256(uint160(quote)), amount); // claims -> positive delta
        poolManager.take(Currency.wrap(quote), address(this), amount); // pull the real stock out

        // stock → WETH on V3, along the SAME route the StockPairRouter sells through (its
        // owner-maintained multi-hop path; empty ⇒ the launchpad's direct-hop fee tier).
        IERC20(quote).forceApprove(address(v3Router), amount);
        bytes memory path = stockRouter.sellPathOf(quote);
        uint256 out = path.length > 0
            ? v3Router.exactInput(
                IV3SwapRouter.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    amountIn: amount,
                    amountOutMinimum: minWethOut
                })
            )
            : v3Router.exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn: quote,
                    tokenOut: weth,
                    fee: launchpad.quoteV3Fee(quote),
                    recipient: address(this),
                    amountIn: amount,
                    amountOutMinimum: minWethOut,
                    sqrtPriceLimitX96: 0
                })
            );

        _split(token, amount, out);
        return abi.encode(out);
    }

    function _split(address token, uint256 stockIn, uint256 out) private {
        uint256 toTreasury = (out * treasuryBps) / BPS;
        uint256 toDev = (out * devBps) / BPS;

        // MODE stock tokens (Reward/Lottery — mode != 0) fund their mechanism through the
        // distributor, exactly like the V4 FeeLocker does for WETH pairs: the slice stays WETH
        // and is credited via notify(). Base tokens (and an unset distributor, and any token
        // whose mode read fails) fold the slice into the flagship as before — fail-open to the
        // old behavior, never a stuck distribute().
        uint256 toMechanism;
        address dist = distributor;
        if (dist != address(0) && mechanismBps != 0) {
            try IModeTokenView(token).mode() returns (uint8 m) {
                if (m != 0) toMechanism = (out * mechanismBps) / BPS;
            } catch {}
        }
        // Flagship takes the remainder (its own share + Base tokens' folded mechanism + dust).
        uint256 toFlagship = out - toTreasury - toDev - toMechanism;

        uint256 ethPortion = out - toMechanism; // mechanism stays WETH
        if (ethPortion > 0) IWETHW(weth).withdraw(ethPortion); // pay in native ETH, never WETH
        if (toTreasury > 0) _payEth(treasury, toTreasury);
        if (toDev > 0) {
            address dev = launchpad.creatorOf(token);
            _payEth(dev == address(0) ? treasury : dev, toDev);
        }
        if (toFlagship > 0) _payEth(flagshipSink == address(0) ? treasury : flagshipSink, toFlagship);
        if (toMechanism > 0) {
            IERC20(weth).safeTransfer(dist, toMechanism);
            IDistributorNotify(dist).notify(token, toMechanism);
        }

        emit Distributed(token, stockIn, out, toTreasury, toDev, toFlagship, toMechanism);
    }

    /// @dev Reverts on rejection — `distribute` unwinds atomically, so nothing is lost.
    function _payEth(address to, uint256 value) private {
        (bool ok,) = to.call{value: value}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Accept ETH only from unwrapping WETH (during `distribute`).
    receive() external payable {
        if (msg.sender != weth) revert EthTransferFailed();
    }

    // ── unused IHooks callbacks (never invoked — the address bits don't enable them) ──
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
