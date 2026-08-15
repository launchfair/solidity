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

/// @notice IMMUTABLE variant of WethFeeHook: identical fee mechanics, but the fee rate, split, and
/// destinations are fixed at construction with NO owner and NO setters. There is no `setFeeBps`,
/// `setDestinations`, or `setSplit`, and the per-tier `sideBps` are the fixed FeeSplitConfig defaults.
/// A token scanner therefore sees no admin surface: nobody can raise the fee, redirect where fees go,
/// or retune the split after you enter. The trade-off is that a mis-set destination or a fee change
/// requires deploying a fresh hook and repointing the launchpad (immutable-hook model) — existing
/// pools are bound to whichever hook they were created with.
///
/// The fee is charged **in WETH on both buys and sells**, always from the WETH leg of the swap — so a
/// sell produces no token sell pressure, and the fee is captured on every swap regardless of router.
/// All four cases {buy,sell} x {exact-in,exact-out} are covered by charging on whichever leg is WETH:
/// the specified currency in `beforeSwap`, the unspecified currency in `afterSwap` (exactly one fires
/// per swap). WETH accrues per token; anyone calls `distribute(token)` to redeem the accrued
/// ERC-6909 WETH claims for real WETH and run the treasury/dev/mechanism/flagship split.
///
/// PERMISSIONS: needs `beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta` (the low
/// bits of its address MUST encode exactly those), so it must be CREATE2-deployed to a mined address.
/// The constructor calls `Hooks.validateHookPermissions`, so a wrong-address deploy reverts.
contract WethFeeHookImmutable is IHooks, IUnlockCallback, FeeSplitConfig {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Hard cap on the fee (of the WETH leg). 1000 = 10% == the top tier, the ceiling by
    /// construction. Kept as a construction-time guard even though there is no setter.
    uint16 public constant MAX_FEE_BPS = 1_000;

    IPoolManager public immutable poolManager;
    address public immutable weth;

    /// @notice Fee in bps of the WETH leg (global fallback for foreign/legacy tokens with no launch
    /// record). Our own tokens use their per-tier rate from the launch record. FIXED at construction.
    uint16 public immutable feeBps;
    /// @notice WETH fees accrued per token (the pool's non-WETH currency), pending distribution.
    mapping(address token => uint256) public accrued;

    // ── fee-split config: FIXED at construction, no setters ──
    address public immutable treasury; // platform treasury (also the fallback for any unset destination)
    address public immutable distributor; // V4 reward/lottery mechanism (notify)
    address public immutable flagshipSink; // flagship buyback (0 folds to treasury)
    address public immutable launchpad; // resolves the per-token dev via creatorOf(token)
    // Global 4-way split (foreign/legacy tokens only; our tokens use the per-tier FeeSplitConfig).
    uint16 public constant treasuryBps = 2_500; // 25%
    uint16 public constant devBps = 2_500; // 25%
    uint16 public constant mechanismBps = 4_000; // 40%
    uint16 public constant flagshipBps = 1_000; // 10% — the four sum to BPS

    /// @notice Fee shares that could not be pushed to their recipient — pull with `withdrawOwed`.
    mapping(address => uint256) public owed;

    error NotPoolManager();
    error InvalidFeeBps();
    error NotConfigured();
    error EthTransferFailed();

    event FeeTaken(address indexed token, bool isBuy, uint256 wethFee);
    event Distributed(address indexed token, uint256 toTreasury, uint256 toDev, uint256 toMechanism, uint256 toFlagship);
    /// @notice A push to the creator failed; the value is claimable with `withdrawOwed`.
    event PayoutOwed(address indexed to, uint256 amount);
    event OwedWithdrawn(address indexed to, uint256 amount);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(
        IPoolManager pm_,
        address weth_,
        uint16 feeBps_,
        address treasury_,
        address distributor_,
        address flagshipSink_,
        address launchpad_
    ) {
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFeeBps();
        if (treasury_ == address(0)) revert NotConfigured(); // treasury is the fallback for every slice
        poolManager = pm_;
        weth = weth_;
        feeBps = feeBps_;
        treasury = treasury_;
        distributor = distributor_;
        flagshipSink = flagshipSink_;
        launchpad = launchpad_;
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

    // ── per-tier fee rate (creator's 3/5/10% choice, charged in-pool) ─────────────
    /// @dev The token's fee tier, read from the launchpad's AUTHORITATIVE launch record — never
    /// from the pool key (V4 initialize is permissionless). 0 for a foreign/legacy token → global fallback.
    function _launchFee(address token) internal view returns (uint24) {
        if (launchpad == address(0)) return 0;
        try ILaunchpadTierView(launchpad).getLaunch(token) returns (LaunchTierView memory L) {
            if (L.exists) return L.fee;
        } catch {}
        return 0;
    }

    /// @notice The WETH-leg fee rate applied to `token`'s swaps: its chosen tier (3/5/10%) if the
    /// launchpad launched it at a supported tier, else the global `feeBps`.
    function feeBpsFor(address token) public view returns (uint16) {
        uint24 f = _launchFee(token);
        if (isSupportedFee(f)) return uint16(f / 100); // 30000→300, 50000→500, 100000→1000
        return feeBps;
    }

    // ── the fee: WETH on both sides, all four swap cases ──────────────────────────
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

    // ── distribute accrued WETH through the split (permissionless) ────────────────
    /// @notice Redeem a token's accrued WETH 6909 claims for real WETH and run the split.
    function distribute(address token) external returns (uint256 amount) {
        amount = accrued[token];
        if (amount == 0) return 0;
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
            // the remainder is the mechanism slice, which folds into the flagship for a Base token.
            (toTreasury, toDev, toMechanism) = splitOf(tier, amount);
        } else {
            // Foreign/legacy token (no launch record): the global 4-way split.
            toTreasury = (amount * treasuryBps) / BPS;
            toDev = (amount * devBps) / BPS;
            toFlagship = (amount * flagshipBps) / BPS;
            toMechanism = amount - toTreasury - toDev - toFlagship;
        }

        // Mechanism slice stays in WETH — it feeds the on-chain buyback engine (the distributor swaps
        // WETH→reward). Plain (Base) tokens have no mechanism → the slice folds into the flagship.
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
            // CREDIT the creator on failure, never freeze the whole distribution or forfeit the share.
            _payEthOrCredit(dev == address(0) ? t : dev, toDev);
        }
        if (flagshipTotal > 0) _payEth(flagshipSink == address(0) ? t : flagshipSink, flagshipTotal);

        emit Distributed(token, toTreasury, toDev, notified ? toMechanism : 0, toFlagship);
    }

    /// @dev Send native ETH; reverts if the recipient rejects it. Used only for treasury and the
    /// flagship sink — both platform-controlled addresses that accept ETH.
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
