// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 — https://hood.launchfair.app
// Turns each mode token's accrued WETH LP fees into holder rewards.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {LaunchTokenV2} from "./LaunchTokenV2.sol";

/// @notice The V2 FeeLocker forwards each mode token's creator-half WETH here.
/// A permissionless `process(token)` buys back on the token's own pool
/// (Increasing/Burn) or the reward token's pool (Reward) and funds the token's
/// dividend tracker (or burns). Anyone may call `process` — the keeper we run
/// just guarantees liveness and batches swaps for good pricing.
contract LaunchFairDistributorV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable weth;
    address public locker;

    // V3 price bounds for an unconstrained exact-input swap.
    uint160 private constant MIN_SQRT = 4295128740;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    /// @notice WETH awaiting a buyback, per token.
    mapping(address token => uint256) public pendingWeth;

    event LockerSet(address locker);
    event Notified(address indexed token, uint256 wethAdded, uint256 pending);
    event Processed(address indexed token, uint256 wethIn, uint256 assetOut, uint8 mode);

    error OnlyLocker();
    error LockerAlreadySet();
    error ZeroAddress();
    error NothingPending();
    error WrongMode();
    error Slippage();
    error BadPool();

    constructor(address owner_, IERC20 weth_) Ownable(owner_) {
        if (address(weth_) == address(0)) revert ZeroAddress();
        weth = weth_;
    }

    /// @notice One-time wiring of the V2 FeeLocker (deployed after this).
    function setLocker(address locker_) external onlyOwner {
        if (locker != address(0)) revert LockerAlreadySet();
        if (locker_ == address(0)) revert ZeroAddress();
        locker = locker_;
        emit LockerSet(locker_);
    }

    /// @notice Called by the V2 FeeLocker right after it transfers `amount` WETH
    /// to this contract for `token`.
    function notify(address token, uint256 amount) external {
        if (msg.sender != locker) revert OnlyLocker();
        pendingWeth[token] += amount;
        emit Notified(token, amount, pendingWeth[token]);
    }

    /// @notice Permissionless: swap a token's pending WETH into its reward asset
    /// and distribute (Reward/Increasing) or burn it (Burn). `minOut` guards
    /// slippage; pass a fresh quote from the keeper.
    function process(address token, uint256 minOut) external nonReentrant returns (uint256 out) {
        uint256 wethIn = pendingWeth[token];
        if (wethIn == 0) revert NothingPending();
        pendingWeth[token] = 0;

        LaunchTokenV2 t = LaunchTokenV2(token);
        LaunchTokenV2.Mode m = t.mode();
        if (m == LaunchTokenV2.Mode.Base) revert WrongMode();

        bool isReward = m == LaunchTokenV2.Mode.Reward;
        address swapPool = isReward ? t.rewardPool() : t.pool();
        if (swapPool == address(0)) revert BadPool();
        address assetOut = t.distributionAsset(); // reward token, or this token

        // WETH is the input asset; we buy `assetOut`. zeroForOne == WETH is token0.
        bool assetIsToken0 = assetOut < address(weth);
        bool zeroForOne = !assetIsToken0;
        (int256 a0, int256 a1) = IUniswapV3Pool(swapPool).swap(
            address(this), zeroForOne, int256(wethIn), zeroForOne ? MIN_SQRT : MAX_SQRT, abi.encode(token, isReward)
        );
        out = uint256(-(assetIsToken0 ? a0 : a1));
        if (out < minOut) revert Slippage();

        if (m == LaunchTokenV2.Mode.Burn) {
            t.fundBurn(out); // burns `out` held by this contract
        } else {
            IERC20(assetOut).forceApprove(token, out);
            t.fundRewards(out); // token pulls `out` and credits holders
        }
        emit Processed(token, wethIn, out, uint8(m));
    }

    /// @notice Uniswap V3 swap callback — pays the WETH owed. The expected pool
    /// is read from the token's launchpad-set records (`pool()` / `rewardPool()`),
    /// never from `data` alone, so a spoofed caller cannot drain WETH.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address token, bool isReward) = abi.decode(data, (address, bool));
        address expected = isReward ? LaunchTokenV2(token).rewardPool() : LaunchTokenV2(token).pool();
        if (msg.sender != expected) revert BadPool();
        // We only ever owe WETH (the positive delta).
        if (amount0Delta > 0) weth.safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) weth.safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
