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
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {LaunchTokenV2} from "../LaunchTokenV2.sol";

interface ICreatorRegistryV4 {
    function creatorOf(address token) external view returns (address);
}

/// @notice Turns each mode token's accrued buy-side WETH fees into holder rewards
/// on Uniswap V4. The V4 FeeLocker forwards the mechanism's WETH here; a
/// permissionless `process(token)` buys the token's reward asset on its V4 pool
/// (via the PoolManager unlock/flash-accounting), then funds the token's
/// dividend tracker (Reward/Redistribute) or burns it (Burn).
contract LaunchFairV4Distributor is Ownable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    IERC20 public immutable weth;
    address public immutable registrar; // the launchpad; records buyback pools
    address public locker;

    mapping(address token => PoolKey) internal _buyback; // V4 pool to buy the asset on
    mapping(address token => bool) public registered;
    mapping(address token => uint256) public pendingWeth;
    /// @notice Dev-set minimum pending WETH before a payout fires (anti-dust; the
    /// keeper only processes once it's crossed). 0 = fire on any pending.
    mapping(address token => uint256) public payoutThreshold;

    event LockerSet(address locker);
    event BuybackRegistered(address indexed token);
    event Notified(address indexed token, uint256 amount, uint256 pending);
    event Processed(address indexed token, uint256 wethIn, uint256 assetOut, uint8 mode);
    event PayoutThresholdSet(address indexed token, uint256 threshold);

    error OnlyLocker();
    error OnlyRegistrar();
    error OnlyPoolManager();
    error LockerAlreadySet();
    error NotRegistered();
    error NothingPending();
    error BelowThreshold();
    error NotAuthorized();
    error WrongMode();
    error Slippage();
    error ZeroAddress();

    constructor(address owner_, IPoolManager pm_, IERC20 weth_, address registrar_) Ownable(owner_) {
        if (address(pm_) == address(0) || address(weth_) == address(0) || registrar_ == address(0)) revert ZeroAddress();
        poolManager = pm_;
        weth = weth_;
        registrar = registrar_;
    }

    function setLocker(address locker_) external onlyOwner {
        if (locker != address(0)) revert LockerAlreadySet();
        if (locker_ == address(0)) revert ZeroAddress();
        locker = locker_;
        emit LockerSet(locker_);
    }

    /// @notice Launchpad records the V4 pool where a token's reward asset is bought.
    function registerBuyback(address token, PoolKey calldata key) external {
        if (msg.sender != registrar) revert OnlyRegistrar();
        _buyback[token] = key;
        registered[token] = true;
        emit BuybackRegistered(token);
    }

    /// @notice Called by the V4 FeeLocker after forwarding `amount` WETH here.
    function notify(address token, uint256 amount) external {
        if (msg.sender != locker) revert OnlyLocker();
        pendingWeth[token] += amount;
        emit Notified(token, amount, pendingWeth[token]);
    }

    /// @notice The token's dev (creator) — or the launchpad — sets the minimum
    /// pending WETH that must accrue before a payout fires.
    function setPayoutThreshold(address token, uint256 amount) external {
        if (msg.sender != registrar && msg.sender != _creator(token)) revert NotAuthorized();
        payoutThreshold[token] = amount;
        emit PayoutThresholdSet(token, amount);
    }

    /// @notice True when a payout would succeed — the keeper polls/reacts on this.
    function readyToProcess(address token) external view returns (bool) {
        uint256 p = pendingWeth[token];
        return registered[token] && p > 0 && p >= payoutThreshold[token];
    }

    function _creator(address token) internal view returns (address) {
        try ICreatorRegistryV4(registrar).creatorOf(token) returns (address c) {
            return c;
        } catch {
            return address(0);
        }
    }

    /// @notice Permissionless: buy the token's reward asset with its pending WETH
    /// and distribute (Reward/Redistribute) or burn (Burn). `minOut` guards slippage.
    function process(address token, uint256 minOut) external nonReentrant returns (uint256 out) {
        uint256 wethIn = pendingWeth[token];
        if (wethIn == 0) revert NothingPending();
        if (wethIn < payoutThreshold[token]) revert BelowThreshold();
        if (!registered[token]) revert NotRegistered();
        LaunchTokenV2.Mode m = LaunchTokenV2(token).mode();
        if (m == LaunchTokenV2.Mode.Base) revert WrongMode();
        pendingWeth[token] = 0;

        out = abi.decode(poolManager.unlock(abi.encode(token, wethIn)), (uint256));
        if (out < minOut) revert Slippage();

        if (m == LaunchTokenV2.Mode.Burn) {
            LaunchTokenV2(token).fundBurn(out);
        } else {
            IERC20(LaunchTokenV2(token).distributionAsset()).forceApprove(token, out);
            LaunchTokenV2(token).fundRewards(out);
        }
        emit Processed(token, wethIn, out, uint8(m));
    }

    /// @dev PoolManager flash-accounting callback: swap WETH -> reward asset, pay
    /// the WETH owed, take the asset bought. Returns the asset amount received.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (address token, uint256 wethIn) = abi.decode(data, (address, uint256));

        PoolKey memory key = _buyback[token];
        Currency assetCur = Currency.wrap(LaunchTokenV2(token).distributionAsset());
        Currency wethCur = Currency.wrap(address(weth));
        bool zeroForOne = Currency.unwrap(key.currency0) == address(weth); // WETH is the input

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(wethIn), // exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // WETH side is negative (we owe); asset side positive (we receive).
        int128 wethDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 assetDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 wethOwed = uint256(int256(-wethDelta));
        uint256 assetOut = uint256(int256(assetDelta));

        // Pay WETH.
        poolManager.sync(wethCur);
        weth.safeTransfer(address(poolManager), wethOwed);
        poolManager.settle();
        // Take the bought asset.
        poolManager.take(assetCur, address(this), assetOut);

        return abi.encode(assetOut);
    }
}
