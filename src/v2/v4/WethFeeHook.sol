// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — https://hood.launchfair.app

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FeeSplitConfig} from "./FeeSplitConfig.sol";

interface ICreatorRegistryV4 {
    function creatorOf(address token) external view returns (address);
}

/// The launchpad's per-token launch record — the AUTHORITATIVE source of a token's fee tier.
/// Field order must match LaunchFairV4.Launch exactly.
struct LaunchTierView {
    address creator;
    PoolKey key;
    uint24 fee; // the creator-chosen tier (30000/50000/100000), or 0 for legacy/foreign
    address quoteToken;
    bool exists;
}

interface ILaunchpadTierView {
    function getLaunch(address token) external view returns (LaunchTierView memory);
}

interface IDistributorV4 {
    function notify(address token, uint256 amount) external;
}

interface IModeToken {
    function mode() external view returns (uint8); // 0 = Base/plain (no reward/lottery mechanism)
}

interface IWETH {
    function withdraw(uint256) external;
}

/// @notice Uniswap V4 hook that charges a fee **in WETH on both buys and sells**, always taken
/// from the WETH leg of the swap — so a sell produces **no token sell pressure**, and the fee is
/// captured on **every** swap on the pool regardless of which router/aggregator routes it.
///
///   - Buy  (WETH in): the fee is skimmed from the WETH leg (input) in `beforeSwap`/`afterSwap`.
///   - Sell (WETH out): the fee is skimmed from the WETH leg (output) in `beforeSwap`/`afterSwap`.
///
/// All four cases are covered — {buy, sell} × {exact-input, exact-output} — by charging on
/// whichever leg is WETH: on the *specified* currency in `beforeSwap` when WETH is specified, and
/// on the *unspecified* currency in `afterSwap` when WETH is unspecified. Exactly one leg fires per
/// swap (specified and unspecified are complements, and WETH is one of them).
///
/// The WETH accrues per token; a keeper (or anyone) calls `distribute(token)` to redeem the
/// accrued ERC-6909 WETH claims for real WETH and run the treasury/dev/mechanism/flagship split.
/// So this replaces the fee SOURCE, not the fee ROUTING.
///
/// PERMISSIONS: this hook needs `beforeSwap | afterSwap | beforeSwapReturnDelta |
/// afterSwapReturnDelta` (the low bits of its address MUST encode exactly those, 0xCC), so it must
/// be CREATE2-deployed to a mined address. The constructor calls `Hooks.validateHookPermissions`,
/// so a wrong-address deploy reverts at CREATE2 (fail fast). See docs/V4_WETH_FEE_HOOK.md.
///
/// Audited pre-deployment (see AUDIT_V4_HOOK.md): the shared ERC-6909 WETH claim pool is
/// non-drainable (Σ accrued == claims == redeemable WETH), delta accounting is correct in all four
/// cases, and reentrancy is guarded. Still recommended: its own on-chain fork test pass before use.
contract WethFeeHook is IHooks, IUnlockCallback, Ownable2Step, FeeSplitConfig {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Hard cap on the fee (of the WETH leg) — prevents an owner fat-finger from setting a
    /// fee ≥ the swap amount, which would revert every swap and brick the pool. 1000 = 10%. The
    /// per-tier rates (3/5/10% of the trade) are charged in bps of the WETH leg, and 10% == 1000
    /// is exactly this cap, so the 10% tier is the ceiling by construction.
    uint16 public constant MAX_FEE_BPS = 1_000;

    IPoolManager public immutable poolManager;
    address public immutable weth;

    /// @notice Fee in bps of the WETH leg, charged on both buys and sells. Owner-settable, ≤ MAX_FEE_BPS.
    uint16 public feeBps;
    /// @notice WETH fees accrued per token (the pool's non-WETH currency), pending distribution.
    mapping(address token => uint256) public accrued;

    // ── fee-split config (owner-settable): the accrued WETH splits four ways ──
    address public treasury; // platform treasury (also the fallback for any unset destination)
    address public distributor; // V4 reward/lottery mechanism (notify)
    address public flagshipSink; // flagship buyback
    address public launchpad; // resolves the per-token dev via creatorOf(token)
    uint16 public treasuryBps = 2_500; // 25%
    uint16 public devBps = 2_500; // 25%
    uint16 public mechanismBps = 4_000; // 40% (reward/lottery)
    uint16 public flagshipBps = 1_000; // 10% (flagship buyback) — the four MUST sum to BPS

    /// @notice Fee shares that could not be pushed to their recipient — pull with `withdrawOwed`.
    mapping(address => uint256) public owed;

    error NotPoolManager();
    error InvalidFeeBps();
    error NotConfigured();
    error NotAuthorized();
    error EthTransferFailed();

    /// @dev The global tax knobs are settable by the owner (deployer) OR the treasury.
    modifier onlyOwnerOrTreasury() {
        if (msg.sender != owner() && msg.sender != treasury) revert NotAuthorized();
        _;
    }

    event FeeTaken(address indexed token, bool isBuy, uint256 wethFee);
    event Distributed(address indexed token, uint256 toTreasury, uint256 toDev, uint256 toMechanism, uint256 toFlagship);
    /// @notice A push to the creator failed; the value is claimable with `withdrawOwed`.
    event PayoutOwed(address indexed to, uint256 amount);
    event OwedWithdrawn(address indexed to, uint256 amount);
    event FeeBpsSet(uint16 feeBps);
    event SplitSet(uint16 treasuryBps, uint16 devBps, uint16 mechanismBps, uint16 flagshipBps);
    event DestinationsSet(address treasury, address distributor, address flagshipSink, address launchpad);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(address owner_, IPoolManager pm_, address weth_, uint16 feeBps_) Ownable(owner_) {
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFeeBps();
        poolManager = pm_;
        weth = weth_;
        feeBps = feeBps_;
        // Fail fast: the address must encode exactly this hook's permission bits, or CREATE2 reverts.
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

    function setDestinations(address treasury_, address distributor_, address flagshipSink_, address launchpad_)
        external
        onlyOwner
    {
        treasury = treasury_;
        distributor = distributor_;
        flagshipSink = flagshipSink_;
        launchpad = launchpad_;
        emit DestinationsSet(treasury_, distributor_, flagshipSink_, launchpad_);
    }

    /// @notice Retune the 4-way split (the four bps MUST sum to BPS). Owner or treasury.
    function setSplit(uint16 t, uint16 d, uint16 m, uint16 f) external onlyOwnerOrTreasury {
        if (uint256(t) + d + m + f != BPS) revert InvalidSplit();
        treasuryBps = t;
        devBps = d;
        mechanismBps = m;
        flagshipBps = f;
        emit SplitSet(t, d, m, f);
    }

    // ── per-tier fee rate (creator's 3/5/10% choice, charged in-pool) ─────────────
    /// @dev The token's fee tier, read from the launchpad's AUTHORITATIVE launch record — never
    /// from the pool key. V4 `initialize` is permissionless, so trusting the key's fee field would
    /// let anyone open a pool at a tier of their choosing; the launch record is the one the creator
    /// actually chose. 0 for a foreign/legacy token (no record) → the global `feeBps` fallback.
    function _launchFee(address token) internal view returns (uint24) {
        if (launchpad == address(0)) return 0;
        try ILaunchpadTierView(launchpad).getLaunch(token) returns (LaunchTierView memory L) {
            if (L.exists) return L.fee;
        } catch {}
        return 0;
    }

    /// @notice The WETH-leg fee rate applied to `token`'s swaps: its chosen tier (3/5/10% of the
    /// trade) if the launchpad launched it at a supported tier, else the global `feeBps`.
    function feeBpsFor(address token) public view returns (uint16) {
        uint24 f = _launchFee(token);
        if (isSupportedFee(f)) return uint16(f / 100); // 30000→300, 50000→500, 100000→1000
        return feeBps;
    }

    // ── the fee: WETH on both sides, all four swap cases ──────────────────────────
    /// @dev Charges when the WETH leg is the SPECIFIED currency (exact-input buy: WETH is the
    /// specified input; exact-output sell: WETH is the specified output). A positive specified
    /// delta pulls `feeBps` of that WETH to the hook as a 6909 claim; the swapper bears the cost.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified != 0) {
            bool exactIn = params.amountSpecified < 0;
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            // "specified" currency = input on exact-in, output on exact-out.
            address specified = (params.zeroForOne == exactIn) ? c0 : c1;
            if (specified == weth) {
                address tk = c0 == weth ? c1 : c0;
                uint16 bps = feeBpsFor(tk); // the token's chosen tier, or the global default
                uint256 amt = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
                uint256 fee = bps == 0 ? 0 : (amt * bps) / BPS;
                if (fee > 0) {
                    poolManager.mint(address(this), uint256(uint160(weth)), fee); // claim, not a physical take
                    accrued[tk] += fee;
                    emit FeeTaken(tk, exactIn, fee); // exactIn ⇒ buy (WETH in); exactOut ⇒ sell (WETH out)
                    return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), int128(0)), 0);
                }
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Charges when the WETH leg is the UNSPECIFIED currency (exact-input sell: WETH is the
    /// unspecified output; exact-output buy: WETH is the unspecified input). Skims `feeBps` of the
    /// actual WETH amount from the swap delta. `beforeSwap` and `afterSwap` are mutually exclusive
    /// per swap (specified/unspecified are complements, WETH is exactly one of them).
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (params.amountSpecified != 0) {
            bool exactIn = params.amountSpecified < 0;
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            // "unspecified" currency = output on exact-in, input on exact-out (complement of `specified`).
            address unspecified = (params.zeroForOne == exactIn) ? c1 : c0;
            if (unspecified == weth) {
                address tk = c0 == weth ? c1 : c0;
                uint16 bps = feeBpsFor(tk); // the token's chosen tier, or the global default
                int256 d = int256(weth == c0 ? delta.amount0() : delta.amount1());
                uint256 mag = uint256(d >= 0 ? d : -d);
                uint256 fee = bps == 0 ? 0 : (mag * bps) / BPS;
                if (fee > 0) {
                    poolManager.mint(address(this), uint256(uint160(weth)), fee); // claim, not a physical take
                    accrued[tk] += fee;
                    emit FeeTaken(tk, !exactIn, fee); // exactIn ⇒ sell (WETH out); exactOut ⇒ buy (WETH in)
                    return (IHooks.afterSwap.selector, int128(int256(fee)));
                }
            }
        }
        return (IHooks.afterSwap.selector, int128(0));
    }

    // ── distribute accrued WETH through the 4-way split (permissionless) ──────────
    /// @notice Redeem a token's accrued WETH 6909 claims for real WETH and run the 4-way split.
    function distribute(address token) external returns (uint256 amount) {
        amount = accrued[token];
        if (amount == 0) return 0;
        if (treasury == address(0)) revert NotConfigured(); // treasury is the fallback for every slice
        accrued[token] = 0;
        // The fees are held as ERC-6909 WETH claims (minted during swaps). Redeem them for real
        // WETH inside an unlock (burn -> take), then split — see unlockCallback.
        poolManager.unlock(abi.encode(token, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), uint256(uint160(weth)), amount); // claims -> positive delta
        poolManager.take(Currency.wrap(weth), address(this), amount); // pull the real WETH out
        _split(token, amount);
        return "";
    }

    function _split(address token, uint256 amount) private {
        address t = treasury;
        IERC20 w = IERC20(weth);
        uint256 toTreasury;
        uint256 toDev;
        uint256 toMechanism;
        uint256 toFlagship;

        uint24 tier = _launchFee(token);
        if (isSupportedFee(tier)) {
            // PER-TIER split (the creator's 3/5/10% choice). treasury == dev == sideBps[tier];
            // the remainder is the mechanism slice. There is no explicit flagship % in the tier
            // table by design: a Base token's mechanism folds into the flagship below (so plain
            // tokens still feed the flywheel), and a mode token's mechanism funds its own
            // reward/lottery. This is exactly the FeeSplitConfig model the team defined.
            (toTreasury, toDev, toMechanism) = splitOf(tier, amount);
        } else {
            // Foreign/legacy token (no launch record): the global 4-way split, unchanged.
            toTreasury = (amount * treasuryBps) / BPS;
            toDev = (amount * devBps) / BPS;
            toFlagship = (amount * flagshipBps) / BPS;
            toMechanism = amount - toTreasury - toDev - toFlagship;
        }

        // Mechanism slice stays in WETH — it feeds the on-chain buyback engine (the distributor swaps
        // WETH→reward). Plain (Base) tokens have no mechanism → the slice folds into the flagship.
        // Fund the mechanism only if the token has one AND the distributor accepts it; else fold.
        bool notified;
        if (toMechanism > 0 && distributor != address(0) && _hasMechanism(token)) {
            try IDistributorV4(distributor).notify(token, toMechanism) {
                w.safeTransfer(distributor, toMechanism);
                notified = true;
            } catch {}
        }
        uint256 flagshipTotal = toFlagship + (notified ? 0 : toMechanism);

        // treasury + dev + flagship are paid in NATIVE ETH (never WETH) — unwrap that portion.
        uint256 ethPortion = toTreasury + toDev + flagshipTotal;
        if (ethPortion > 0) IWETH(weth).withdraw(ethPortion);
        if (toTreasury > 0) _payEth(t, toTreasury);
        if (toDev > 0) {
            address dev = launchpad != address(0) ? ICreatorRegistryV4(launchpad).creatorOf(token) : address(0);
            // CREDIT the creator on failure, never freeze the whole distribution or forfeit the
            // share to the treasury. `creatorOf` is arbitrary (a splitter, a 7702 delegate, a Safe
            // that does work on receipt), and it is fixed at launch with no setter — so a reverting
            // creator used to brick treasury + flagship + mechanism for that token forever. The
            // twin fix already lives in LaunchFairV4FeeLocker and StockFeeHook; this is the file
            // that serves the main product and never got it.
            _payEthOrCredit(dev == address(0) ? t : dev, toDev);
        }
        if (flagshipTotal > 0) _payEth(flagshipSink == address(0) ? t : flagshipSink, flagshipTotal);

        emit Distributed(token, toTreasury, toDev, notified ? toMechanism : 0, toFlagship);
    }

    /// @dev Send native ETH; reverts if the recipient rejects it. Used only for treasury and the
    /// flagship sink — both platform-controlled addresses that accept ETH; a revert here is a
    /// misconfiguration to fix, and unwinds the (already-zeroed) `accrued` for a clean retry.
    function _payEth(address to, uint256 value) private {
        (bool ok,) = to.call{value: value}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Pay the creator, whose address is arbitrary. On failure CREDIT the value (pull via
    /// `withdrawOwed`) instead of reverting the whole distribution or confiscating it to treasury.
    function _payEthOrCredit(address to, uint256 value) private {
        if (value == 0) return;
        (bool ok,) = to.call{value: value, gas: 100_000}("");
        if (!ok) {
            owed[to] += value;
            emit PayoutOwed(to, value);
        }
    }

    /// @notice Withdraw fee shares that could not be pushed. Permissionless; the ETH only ever
    /// goes to the address that is owed it.
    function withdrawOwed(address to) external returns (uint256 amount) {
        amount = owed[to];
        if (amount == 0) return 0;
        owed[to] = 0; // zeroed before the send: a reentrant call sees nothing left
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit OwedWithdrawn(to, amount);
    }

    /// @dev Accept ETH only from unwrapping WETH (during `distribute`).
    receive() external payable {
        if (msg.sender != weth) revert EthTransferFailed();
    }

    /// @dev True when the token has a reward/lottery mechanism (mode != Base). Falls back to false
    /// (→ flagship) if the token doesn't expose mode(), so a mechanism slice can never strand.
    function _hasMechanism(address token) private view returns (bool) {
        try IModeToken(token).mode() returns (uint8 m) {
            return m != 0;
        } catch {
            return false;
        }
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
