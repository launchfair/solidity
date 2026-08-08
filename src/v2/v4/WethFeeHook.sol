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

interface ICreatorRegistryV4 {
    function creatorOf(address token) external view returns (address);
}

interface IDistributorV4 {
    function notify(address token, uint256 amount) external;
}

interface IModeToken {
    function mode() external view returns (uint8); // 0 = Base/plain (no reward/lottery mechanism)
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
contract WethFeeHook is IHooks, IUnlockCallback, Ownable2Step {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    uint16 public constant BPS = 10_000;
    /// @notice Hard cap on the fee (of the WETH leg) — prevents an owner fat-finger from setting a
    /// fee ≥ the swap amount, which would revert every swap and brick the pool. 1000 = 10%.
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

    error NotPoolManager();
    error InvalidSplit();
    error InvalidFeeBps();
    error NotConfigured();

    event FeeTaken(address indexed token, bool isBuy, uint256 wethFee);
    event Distributed(address indexed token, uint256 toTreasury, uint256 toDev, uint256 toMechanism, uint256 toFlagship);
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

    function setFeeBps(uint16 bps) external onlyOwner {
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

    /// @notice Retune the 4-way WETH split (the four bps MUST sum to BPS).
    function setSplit(uint16 t, uint16 d, uint16 m, uint16 f) external onlyOwner {
        if (uint256(t) + d + m + f != BPS) revert InvalidSplit();
        treasuryBps = t;
        devBps = d;
        mechanismBps = m;
        flagshipBps = f;
        emit SplitSet(t, d, m, f);
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
        if (feeBps != 0 && params.amountSpecified != 0) {
            bool exactIn = params.amountSpecified < 0;
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            // "specified" currency = input on exact-in, output on exact-out.
            address specified = (params.zeroForOne == exactIn) ? c0 : c1;
            if (specified == weth) {
                uint256 amt = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
                uint256 fee = (amt * feeBps) / BPS;
                if (fee > 0) {
                    address tk = c0 == weth ? c1 : c0;
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
        if (feeBps != 0 && params.amountSpecified != 0) {
            bool exactIn = params.amountSpecified < 0;
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            // "unspecified" currency = output on exact-in, input on exact-out (complement of `specified`).
            address unspecified = (params.zeroForOne == exactIn) ? c1 : c0;
            if (unspecified == weth) {
                int256 d = int256(weth == c0 ? delta.amount0() : delta.amount1());
                uint256 mag = uint256(d >= 0 ? d : -d);
                uint256 fee = (mag * feeBps) / BPS;
                if (fee > 0) {
                    address tk = c0 == weth ? c1 : c0;
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
        uint256 toTreasury = (amount * treasuryBps) / BPS;
        uint256 toDev = (amount * devBps) / BPS;
        uint256 toFlagship = (amount * flagshipBps) / BPS;
        uint256 toMechanism = amount - toTreasury - toDev - toFlagship; // remainder (mechanism + dust)

        if (toTreasury > 0) w.safeTransfer(t, toTreasury);
        if (toDev > 0) {
            address dev = launchpad != address(0) ? ICreatorRegistryV4(launchpad).creatorOf(token) : address(0);
            w.safeTransfer(dev == address(0) ? t : dev, toDev);
        }
        if (toFlagship > 0) w.safeTransfer(flagshipSink == address(0) ? t : flagshipSink, toFlagship);
        if (toMechanism > 0) {
            // Plain (Base, mode 0) tokens have no reward/lottery mechanism → their mechanism slice
            // funds the FLAGSHIP instead (like V1 plain tokens). Mode tokens route to the distributor.
            bool notified;
            if (distributor != address(0) && _hasMechanism(token)) {
                // Credit the mechanism, then fund it. If the distributor rejects this token (e.g. the
                // hook isn't an authorized notifier, or an unknown token), fall back to the flagship
                // so a token's fees can never strand on a reverting notify.
                try IDistributorV4(distributor).notify(token, toMechanism) {
                    w.safeTransfer(distributor, toMechanism);
                    notified = true;
                } catch {}
            }
            if (!notified) w.safeTransfer(flagshipSink == address(0) ? t : flagshipSink, toMechanism);
        }
        emit Distributed(token, toTreasury, toDev, toMechanism, toFlagship);
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
