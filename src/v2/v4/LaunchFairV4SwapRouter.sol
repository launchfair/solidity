// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V4 — https://hood.launchfair.app
// Minimal Uniswap V4 swap router for the mode-token pools. There is no canonical V4
// router on this chain, and V4 pools can't be swapped through the V3 SwapRouter, so
// the frontend needs an on-chain entry point to buy/sell mode tokens. Every mode-token
// pool pairs WETH with the token; this router lets users trade with native ETH by
// wrapping/unwrapping at the edges and doing the swap through the PoolManager's
// unlock/flash-accounting callback (the same pattern the distributor uses for buybacks).

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract LaunchFairV4SwapRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    IWETH public immutable weth;

    event Bought(address indexed token, address indexed buyer, address indexed to, uint256 ethIn, uint256 tokensOut);
    event Sold(address indexed token, address indexed seller, address indexed to, uint256 tokensIn, uint256 ethOut);

    error OnlyPoolManager();
    error Slippage();
    error Expired();
    error BadPool();
    error ZeroAmount();
    error EthTransferFailed();

    constructor(IPoolManager pm_, IWETH weth_) {
        poolManager = pm_;
        weth = weth_;
    }

    /// @notice Buy the non-WETH token in `key` with native ETH. `key` must pair WETH
    /// with the token. Returns the token amount sent to `to`.
    function buy(PoolKey calldata key, uint256 minOut, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert ZeroAmount();
        address token = _pairedToken(key); // the non-WETH currency
        weth.deposit{value: msg.value}(); // wrap ETH -> WETH (the pool's input currency)
        uint256 spent;
        (out, spent) =
            abi.decode(poolManager.unlock(abi.encode(key, address(weth), msg.value, token, to)), (uint256, uint256));
        if (out < minOut) revert Slippage();
        // Partial fill (swap hit the pool's price limit): refund the unspent ETH.
        if (spent < msg.value) {
            uint256 refund = msg.value - spent;
            weth.withdraw(refund);
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert EthTransferFailed();
        }
        emit Bought(token, msg.sender, to, spent, out);
    }

    /// @notice Sell `amountIn` of the non-WETH token in `key` for native ETH. Requires
    /// the caller to have approved this router for `amountIn` of the token. Returns the
    /// ETH sent to `to`.
    function sell(PoolKey calldata key, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        address token = _pairedToken(key);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        // Swap token -> WETH, taking the WETH to this router so it can unwrap it.
        uint256 spent;
        (out, spent) =
            abi.decode(poolManager.unlock(abi.encode(key, token, amountIn, address(weth), address(this))), (uint256, uint256));
        if (out < minOut) revert Slippage();
        // Partial fill (swap hit the pool's price limit): refund the unsold tokens.
        if (spent < amountIn) IERC20(token).safeTransfer(msg.sender, amountIn - spent);
        weth.withdraw(out); // unwrap WETH -> ETH
        (bool ok,) = to.call{value: out}("");
        if (!ok) revert EthTransferFailed();
        emit Sold(token, msg.sender, to, spent, out);
    }

    /// @dev PoolManager flash-accounting callback: swap `amountIn` of `inputCur` for
    /// `outputCur` (exact input), pay the input owed, and take the output to `recipient`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, address inputCur, uint256 amountIn, address outputCur, address recipient) =
            abi.decode(data, (PoolKey, address, uint256, address, address));

        bool zeroForOne = Currency.unwrap(key.currency0) == inputCur; // input is currency0?
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Input side is negative (we owe it); output side positive (we receive it).
        int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 owed = uint256(int256(-inDelta));
        uint256 got = uint256(int256(outDelta));

        // Pay the input currency.
        poolManager.sync(Currency.wrap(inputCur));
        IERC20(inputCur).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        // Take the bought currency straight to the recipient.
        poolManager.take(Currency.wrap(outputCur), recipient, got);

        return abi.encode(got, owed); // (received, input actually spent)
    }

    /// @dev The non-WETH currency in a WETH-paired pool key.
    function _pairedToken(PoolKey calldata key) internal view returns (address) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == address(weth)) return c1;
        if (c1 == address(weth)) return c0;
        revert BadPool();
    }

    /// @dev Receive ETH only from unwrapping WETH.
    receive() external payable {
        if (msg.sender != address(weth)) revert EthTransferFailed();
    }
}
