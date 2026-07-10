// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — https://hood.launchfair.app

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

import {FeeSplitConfig} from "./FeeSplitConfig.sol";
import {LaunchTokenV2} from "../LaunchTokenV2.sol";

interface ICreatorRegistryV4 {
    function creatorOf(address token) external view returns (address);
}

interface IDistributorV4 {
    function notify(address token, uint256 amount) external;
}

/// @notice Owns each V4 token's single-sided liquidity FOREVER (added once, never
/// removed — no decrease function exists) and routes claimed fees:
///   - sell-side token fees -> BURNED (deflationary, no sell pressure)
///   - buy-side WETH fees   -> split treasury/dev (always WETH) + mechanism,
///     by the pool's fee tier (FeeSplitConfig). Mechanism WETH -> distributor.
contract LaunchFairV4FeeLocker is FeeSplitConfig, Ownable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    IERC20 public immutable weth;
    address public launchpad;
    address public distributor;
    address public treasury;

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        bool tokenIsCurrency0;
        bool exists;
    }

    mapping(address token => Position) internal _positions;

    uint8 private constant ACTION_LOCK = 1;
    uint8 private constant ACTION_CLAIM = 2;

    event PositionLocked(address indexed token, uint128 liquidity);
    event FeesClaimed(
        address indexed token,
        uint8 mode,
        uint256 tokensBurned,
        uint256 wethToTreasury,
        uint256 wethToDev,
        uint256 wethToMechanism
    );
    event LaunchpadSet(address launchpad);
    event DistributorSet(address distributor);
    event TreasurySet(address treasury);

    error OnlyLaunchpad();
    error OnlyPoolManager();
    error LaunchpadAlreadySet();
    error DistributorAlreadySet();
    error AlreadyLocked();
    error UnknownToken();
    error ZeroAddress();

    constructor(address owner_, IPoolManager pm_, IERC20 weth_, address treasury_) Ownable(owner_) {
        if (address(pm_) == address(0) || address(weth_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        poolManager = pm_;
        weth = weth_;
        treasury = treasury_;
    }

    // ── wiring ───────────────────────────────────────────────────────────────
    function setLaunchpad(address launchpad_) external onlyOwner {
        if (launchpad != address(0)) revert LaunchpadAlreadySet();
        if (launchpad_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        emit LaunchpadSet(launchpad_);
    }

    function setDistributor(address distributor_) external onlyOwner {
        if (distributor != address(0)) revert DistributorAlreadySet();
        if (distributor_ == address(0)) revert ZeroAddress();
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Owner-tune a fee tier's per-side split (treasury == dev).
    function setSideBps(uint24 fee, uint16 side) external onlyOwner {
        _setSideBps(fee, side);
    }

    function positionOf(address token) external view returns (Position memory) {
        return _positions[token];
    }

    // ── lock liquidity ───────────────────────────────────────────────────────
    /// @notice Called by the launchpad (which has already sent the token supply
    /// here) to add the single-sided position and lock it forever.
    function lockLiquidity(
        address token,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bool tokenIsCurrency0
    ) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (_positions[token].exists) revert AlreadyLocked();
        _positions[token] =
            Position({key: key, tickLower: tickLower, tickUpper: tickUpper, tokenIsCurrency0: tokenIsCurrency0, exists: true});
        poolManager.unlock(abi.encode(ACTION_LOCK, token, uint256(liquidity)));
        emit PositionLocked(token, liquidity);
    }

    // ── claim fees ─────────────────────────────────────────────────────────────
    /// @notice Permissionless. Collects fees, burns the token (sell) side, splits
    /// the WETH (buy) side by the pool's fee tier, funds the mechanism.
    function claim(address token)
        external
        nonReentrant
        returns (uint256 tokensBurned, uint256 wethToTreasury, uint256 wethToDev, uint256 wethToMechanism)
    {
        Position memory p = _positions[token];
        if (!p.exists) revert UnknownToken();

        (uint256 tokenFees, uint256 wethFees) =
            abi.decode(poolManager.unlock(abi.encode(ACTION_CLAIM, token, uint256(0))), (uint256, uint256));

        if (tokenFees > 0) {
            LaunchTokenV2(token).burn(tokenFees);
            tokensBurned = tokenFees;
        }
        if (wethFees > 0) {
            (wethToTreasury, wethToDev, wethToMechanism) = splitOf(p.key.fee, wethFees);
            if (wethToTreasury > 0) weth.safeTransfer(treasury, wethToTreasury);
            if (wethToDev > 0) {
                address dev = ICreatorRegistryV4(launchpad).creatorOf(token);
                weth.safeTransfer(dev == address(0) ? treasury : dev, wethToDev);
            }
            if (wethToMechanism > 0) {
                weth.safeTransfer(distributor, wethToMechanism);
                IDistributorV4(distributor).notify(token, wethToMechanism);
            }
        }
        emit FeesClaimed(
            token, uint8(LaunchTokenV2(token).mode()), tokensBurned, wethToTreasury, wethToDev, wethToMechanism
        );
    }

    // ── V4 flash-accounting callback ─────────────────────────────────────────
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint8 action, address token, uint256 amt) = abi.decode(data, (uint8, address, uint256));
        Position memory p = _positions[token];

        if (action == ACTION_LOCK) {
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                p.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: p.tickLower,
                    tickUpper: p.tickUpper,
                    liquidityDelta: int256(amt),
                    salt: bytes32(0)
                }),
                ""
            );
            _settleDelta(p.key.currency0, d.amount0());
            _settleDelta(p.key.currency1, d.amount1());
            return "";
        }

        // ACTION_CLAIM: poke with 0 liquidity to accrue fees, then take them.
        (BalanceDelta cd,) = poolManager.modifyLiquidity(
            p.key,
            IPoolManager.ModifyLiquidityParams({tickLower: p.tickLower, tickUpper: p.tickUpper, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );
        int128 a0 = cd.amount0();
        int128 a1 = cd.amount1();
        _settleDelta(p.key.currency0, a0);
        _settleDelta(p.key.currency1, a1);
        uint256 tokenFees = p.tokenIsCurrency0 ? _pos(a0) : _pos(a1);
        uint256 wethFees = p.tokenIsCurrency0 ? _pos(a1) : _pos(a0);
        return abi.encode(tokenFees, wethFees);
    }

    /// @dev Pay (negative delta) or take (positive delta) a currency.
    function _settleDelta(Currency cur, int128 amount) internal {
        if (amount < 0) {
            poolManager.sync(cur);
            IERC20(Currency.unwrap(cur)).safeTransfer(address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(cur, address(this), uint256(uint128(amount)));
        }
    }

    function _pos(int128 x) private pure returns (uint256) {
        return x > 0 ? uint256(uint128(x)) : 0;
    }
}
