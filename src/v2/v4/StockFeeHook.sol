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
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// The launchpad's per-token launch record. Field order must match LaunchFairV4.Launch exactly.
struct LaunchView {
    address creator;
    PoolKey key;
    uint24 fee;
    address quoteToken; // 0 for WETH-paired; the stock for stock-paired launches
    bool exists;
}

interface ILaunchpadStockView {
    function allowedQuote(address stock) external view returns (bool);
    function quoteV3Fee(address stock) external view returns (uint24);
    function creatorOf(address token) external view returns (address);
    /// The AUTHORITATIVE record of the pool this launchpad created for `token`.
    function getLaunch(address token) external view returns (LaunchView memory);
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
    /// @dev TWAP window for the claim floor (30 min) — long enough that moving it costs far
    /// more than the fee batch being converted.
    uint32 internal constant TWAP_WINDOW = 1800;
    mapping(address token => address) public quoteOf;
    /// @notice Fee shares that could not be pushed to their recipient — pull with `withdrawOwed`.
    mapping(address => uint256) public owed;
    /// @dev Pools resolved once as not-ours (foreign or quote-squatted) — skip re-resolving.
    mapping(PoolId => bool) internal _foreignPool;

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
    /// @notice A push to the creator failed and the value is now claimable with `withdrawOwed`.
    event PayoutOwed(address indexed to, uint256 amount);
    event OwedWithdrawn(address indexed to, uint256 amount);
    /// @notice The distributor rejected the mechanism credit, so it went to the flagship instead.
    event MechanismFoldedToFlagship(address indexed token, uint256 toFlagship);
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

    /// @dev Resolve (and cache) which side of the pool is the stock quote.
    ///
    /// The quote is taken from the LAUNCHPAD'S OWN LAUNCH RECORD, and this pool must BE the pool
    /// the launchpad created. Deriving it from the key instead is not safe: `PoolManager.initialize`
    /// is permissionless and this hook has no `beforeInitialize` gate, so anyone can open
    /// `TOKEN/<some other allowed stock>` naming this hook and swap 1 wei through it. With a
    /// first-swap-wins cache that squats the token's quote slot forever, and the REAL pool then
    /// mismatches on every swap and trades fee-free permanently — a free, unrecoverable kill on
    /// every fee for that token (treasury, creator, mechanism and flagship alike). Matching the
    /// pool id against the launch record makes a squatted pool simply not ours.
    ///
    /// `accrued[token]` is a bare scalar while the fees behind it are ERC-6909 claims of this
    /// pool's quote, so a token must never be seen with two different quotes; anchoring to the
    /// launch record gives exactly one pool per token by construction.
    function _pool(PoolKey calldata key) internal returns (address token, address quote) {
        PoolId id = key.toId();
        PoolInfo memory p = poolInfo[id];
        if (p.quote != address(0)) return (p.token, p.quote);
        // Negative cache: foreign/squatted pools resolve once, then short-circuit (gas only).
        if (_foreignPool[id]) return (address(0), address(0));

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (launchpad.allowedQuote(c0)) (token, quote) = (c1, c0);
        else if (launchpad.allowedQuote(c1)) (token, quote) = (c0, c1);
        else return _reject(id);

        LaunchView memory L = launchpad.getLaunch(token);
        // Ours, stock-paired, same quote, and THE launch pool — all four, or we charge nothing.
        if (!L.exists || L.creator == address(0) || L.quoteToken != quote) return _reject(id);
        if (PoolId.unwrap(L.key.toId()) != PoolId.unwrap(id)) return _reject(id);

        quoteOf[token] = quote;
        poolInfo[id] = PoolInfo({token: token, quote: quote});
    }

    /// @dev Mark a pool as none of ours so later swaps skip the three external reads.
    function _reject(PoolId id) private returns (address, address) {
        _foreignPool[id] = true;
        return (address(0), address(0));
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
        return claimFeesWithMin(token, 0);
    }

    /// @notice `claimFees` with an explicit floor. The larger of the caller's value and the
    /// self-quote wins, so this can never be used to LOWER the guard.
    ///
    /// The self-quote takes the HIGHER of each hop's spot price and its 30-minute TWAP. Spot
    /// alone was read from the same pools the conversion then swaps through, in the same
    /// transaction, so a caller who pushed the price down first had that manipulated price baked
    /// into their own floor and it constrained nothing: push, claim, back-run. A TWAP cannot be
    /// moved inside one transaction, and taking the higher of the two means a manipulated-low
    /// spot is simply ignored. If a pool is too young to serve a TWAP the floor falls back to
    /// spot. Robinhood's own stock/WETH pools already carry deep observation rings (measured
    /// 2026-08-14: NVDA 1500, COIN 1500, USDG 2500, RDDT 500), so the TWAP is live on every quote
    /// we allow today; a brand-new or thin pool is the only case that degrades to spot.
    function claimFeesWithMin(address token, uint256 minWethOut) public returns (uint256 wethOut) {
        if (address(claimV3Factory) == address(0)) revert NotConfigured();
        uint256 amount = accrued[token];
        if (amount == 0) return 0;
        uint256 floor_ = _claimFloor(quoteOf[token], amount);
        // A zero floor means the quote failed (missing pool, or the fee sum ate it) — refuse
        // rather than swap with no protection at all.
        if (floor_ == 0 && minWethOut == 0) revert NotConfigured();
        return _distribute(token, minWethOut > floor_ ? minWethOut : floor_);
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

    /// @dev Raw-wei conversion through one V3 pool at the HIGHER of spot and the 30-minute TWAP,
    /// so a price pushed down inside this transaction cannot lower the floor (see claimFeesWithMin).
    function _spotOut(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn) internal view returns (uint256) {
        address pool = claimV3Factory.getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert NotConfigured();
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        bool inIsToken0 = tokenIn < tokenOut;
        uint256 spot = _atSqrt(sqrtP, amountIn, inIsToken0);
        uint256 twap = _twapOut(pool, amountIn, inIsToken0);
        return twap > spot ? twap : spot;
    }

    /// @dev The same conversion at the pool's `TWAP_WINDOW` average tick; 0 if unavailable
    /// (young pool, cardinality 1) so the caller falls back to spot.
    function _twapOut(address pool, uint256 amountIn, bool inIsToken0) internal view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        ago[1] = 0;
        try IUniswapV3Pool(pool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 diff = cum[1] - cum[0];
            int24 tick = int24(diff / int56(uint56(TWAP_WINDOW)));
            // Round toward negative infinity, matching Uniswap's OracleLibrary.
            if (diff < 0 && (diff % int56(uint56(TWAP_WINDOW)) != 0)) tick--;
            return _atSqrt(TickMath.getSqrtPriceAtTick(tick), amountIn, inIsToken0);
        } catch {
            return 0;
        }
    }

    /// @dev amountIn × (sqrtP/2**96)^±2, as two mulDivs so nothing overflows.
    function _atSqrt(uint160 sqrtP, uint256 amountIn, bool inIsToken0) private pure returns (uint256) {
        if (sqrtP == 0) return 0;
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

        // BEST-EFFORT, exactly like WethFeeHook: a distributor that reverts (revoked fee source,
        // repointed address, a paused mechanism) must not take the treasury's, the creator's and
        // the flagship's slices down with it. Transfer + notify go together in one self-call so a
        // failed credit can never leave the WETH stranded at the distributor uncredited.
        if (toMechanism > 0) {
            try this.pushMechanism(dist, token, toMechanism) {}
            catch {
                toFlagship += toMechanism;
                toMechanism = 0;
                emit MechanismFoldedToFlagship(token, toFlagship);
            }
        }

        uint256 ethPortion = out - toMechanism; // mechanism stays WETH
        if (ethPortion > 0) IWETHW(weth).withdraw(ethPortion); // pay in native ETH, never WETH
        if (toTreasury > 0) _payEth(treasury, toTreasury);
        if (toDev > 0) {
            address dev = launchpad.creatorOf(token);
            _payEthOrCredit(dev == address(0) ? treasury : dev, toDev);
        }
        if (toFlagship > 0) _payEth(flagshipSink == address(0) ? treasury : flagshipSink, toFlagship);

        emit Distributed(token, stockIn, out, toTreasury, toDev, toFlagship, toMechanism);
    }

    /// @dev Reverts on rejection — `distribute` unwinds atomically, so nothing is lost.
    function _payEth(address to, uint256 value) private {
        (bool ok,) = to.call{value: value}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Pay a recipient that might reject ETH (a creator address is arbitrary — a contract
    /// with no receive(), a Safe variant, a self-destructed address). Reverting here would strand
    /// the WHOLE distribution forever: treasury's and the flagship's slices are in the same call,
    /// and `creatorOf` is fixed at launch with no way to change it.
    ///
    /// On failure the value is CREDITED to the recipient, never handed to the treasury. The old
    /// treasury fallback silently and permanently confiscated the fee share of any creator whose
    /// wallet does real work on receipt — a revenue splitter, a forwarding contract, a 7702
    /// delegate — with no record of a debt and no way to recover it. The push stipend is generous
    /// enough for normal wallets and multisigs; anything beyond that pulls with `withdrawOwed`.
    function _payEthOrCredit(address to, uint256 value) private {
        if (value == 0) return;
        (bool ok,) = to.call{value: value, gas: 100_000}("");
        if (!ok) {
            owed[to] += value;
            emit PayoutOwed(to, value);
        }
    }

    /// @notice Withdraw fee shares that could not be pushed (see `_payEthOrCredit`). Anyone may
    /// trigger it for any address; the ETH only ever goes to the address that is owed it.
    function withdrawOwed(address to) external returns (uint256 amount) {
        amount = owed[to];
        if (amount == 0) return 0;
        owed[to] = 0; // zeroed before the send: a reentrant call sees nothing left
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit OwedWithdrawn(to, amount);
    }

    /// @dev Transfer + credit the mechanism slice atomically. Self-call only, so `_distribute`
    /// can wrap BOTH halves in one try/catch (see there).
    function pushMechanism(address dist, address token, uint256 amount) external {
        if (msg.sender != address(this)) revert NotConfigured();
        IERC20(weth).safeTransfer(dist, amount);
        IDistributorNotify(dist).notify(token, amount);
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
