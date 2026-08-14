// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair — flagship/core buyback vault.
//
// The post-launch flagship SINK is this CONTRACT, not a human wallet: every fee source
// (V4 locker carve, stock router split, StockFeeHook split) pushes its flagship slice of
// native ETH here, and the ETH sits in the contract until the DEPLOYER (owner) triggers a
// buyback. The cron job's key therefore never custodies fee funds — a leaked keeper key can
// trigger owner-gated actions but cannot redirect value anywhere except the on-chain flow:
//
//   buyback()            wrap balance → swap WETH→core on the locked V3 pool → core held here
//   publishSeason(...)   approve + fundAndPublish on the season Merkle distributor, so the
//                        bought core goes straight from this vault into user claims — it
//                        never passes through an EOA
//   withdrawToken/Eth    owner escape hatches (the "never stuck" rule)
//
// The buyback self-quotes its slippage floor from the pool's spot (settable `slippageBps`,
// fee-adjusted), so the cron is a single argumentless call. Per-swap size is capped
// (settable `maxWethPerSwap`) — a big pot gets averaged in over multiple cycles.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3Factory, IUniswapV3Pool, IV3SwapRouter} from "../interfaces/IUniswapV3.sol";

interface IWETH9B {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

interface ISeasonDistributorB {
    function fundAndPublish(uint256 season, uint256 amount, bytes32 merkleRoot, uint256 total) external;
}

contract FlagshipBuyback is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;

    IWETH9B public immutable weth;
    IUniswapV3Factory public immutable factory;
    IV3SwapRouter public immutable v3Router;
    IERC20 public immutable core; // the flagship/core token (exists before this deploys)
    uint24 public immutable poolFee; // the locked core pool's fee tier (10000 = 1%)

    /// The season Merkle distributor this vault funds (its rootPublisher must be THIS contract).
    address public distributor;
    /// Slippage tolerance on top of the pool fee for the self-quoted min-out (default 3%).
    uint16 public slippageBps = 300;
    /// Per-call swap cap — a large pot is averaged in across cron cycles (default 0.5 ETH).
    uint256 public maxWethPerSwap = 0.5 ether;

    // ── keeper gas auto-top-up ───────────────────────────────────────────────
    /// @notice The cron wallet whose gas this vault keeps topped up. 0 disables the feature.
    address public gasRecipient;
    /// @notice Top up only while the recipient is BELOW this balance (and only up to it).
    uint256 public gasFloorWei = 0.03 ether;
    /// @notice Never send more than this in one top-up.
    uint256 public gasMaxPerTopUpWei = 0.02 ether;
    /// @notice Never send more than this per rolling 24h — bounds the bleed if the keeper key
    /// is ever compromised and burns gas on purpose, leaving time to repoint it.
    uint256 public gasDailyCapWei = 0.1 ether;
    uint256 public gasSpentInWindow;
    uint256 public gasWindowStart;

    event FeeReceived(address indexed from, uint256 amount);
    event Buyback(uint256 wethIn, uint256 coreOut);
    event GasPolicySet(address recipient, uint256 floorWei, uint256 maxPerTopUpWei, uint256 dailyCapWei);
    event GasToppedUp(address indexed recipient, uint256 amount, uint256 newBalance);
    event SeasonPublished(uint256 indexed season, uint256 amount, bytes32 root, uint256 total);
    event DistributorSet(address distributor);
    event ParamsSet(uint16 slippageBps, uint256 maxWethPerSwap);
    event EthWithdrawn(address indexed to, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    error NothingToBuy();
    error NoPool();
    error ZeroAddress();
    error BadParams();
    error EthTransferFailed();

    constructor(
        address owner_,
        IWETH9B weth_,
        IUniswapV3Factory factory_,
        IV3SwapRouter v3Router_,
        IERC20 core_,
        uint24 poolFee_
    ) Ownable(owner_) {
        if (
            address(weth_) == address(0) || address(factory_) == address(0) || address(v3Router_) == address(0)
                || address(core_) == address(0)
        ) revert ZeroAddress();
        weth = weth_;
        factory = factory_;
        v3Router = v3Router_;
        core = core_;
        poolFee = poolFee_;
    }

    /// @dev Fee sources push plain ETH here.
    receive() external payable {
        emit FeeReceived(msg.sender, msg.value);
    }

    // ── config (owner — a misconfig is never terminal) ───────────────────────
    function setDistributor(address d) external onlyOwner {
        if (d == address(0)) revert ZeroAddress();
        distributor = d;
        emit DistributorSet(d);
    }

    function setParams(uint16 slippageBps_, uint256 maxWethPerSwap_) external onlyOwner {
        // Slippage + pool fee must stay below 100% or the floor math underflows; 20% is
        // already far beyond any sane setting.
        if (slippageBps_ > 2_000 || maxWethPerSwap_ == 0) revert BadParams();
        slippageBps = slippageBps_;
        maxWethPerSwap = maxWethPerSwap_;
        emit ParamsSet(slippageBps_, maxWethPerSwap_);
    }

    // ── keeper gas ───────────────────────────────────────────────────────────
    /// @notice Configure the keeper gas top-up. `recipient` 0 turns it off. Owner-only.
    function setGasPolicy(address recipient, uint256 floorWei, uint256 maxPerTopUpWei, uint256 dailyCapWei)
        external
        onlyOwner
    {
        gasRecipient = recipient;
        gasFloorWei = floorWei;
        gasMaxPerTopUpWei = maxPerTopUpWei;
        gasDailyCapWei = dailyCapWei;
        emit GasPolicySet(recipient, floorWei, maxPerTopUpWei, dailyCapWei);
    }

    /// @notice Top the keeper back up to `gasFloorWei` if it has fallen below it.
    ///
    /// PERMISSIONLESS on purpose: a keeper that has run out of gas cannot send the very
    /// transaction that would refill it, so gating this on the keeper (or the owner) would
    /// reintroduce exactly the stall it exists to prevent. There is nothing to steal — funds
    /// can only ever go to the owner-set `gasRecipient`, only while it is under the floor, only
    /// up to the floor, and never more than the per-call and per-day caps. Also runs
    /// automatically inside `buyback()`, so the normal cron self-replenishes.
    function topUpGas() public returns (uint256 sent) {
        address r = gasRecipient;
        if (r == address(0) || gasFloorWei == 0) return 0;

        uint256 bal = r.balance;
        if (bal >= gasFloorWei) return 0; // still funded — send nothing
        uint256 need = gasFloorWei - bal;
        if (need > gasMaxPerTopUpWei) need = gasMaxPerTopUpWei;

        // Rolling 24h budget.
        if (block.timestamp >= gasWindowStart + 1 days) {
            gasWindowStart = block.timestamp;
            gasSpentInWindow = 0;
        }
        if (gasDailyCapWei != 0) {
            uint256 left = gasSpentInWindow >= gasDailyCapWei ? 0 : gasDailyCapWei - gasSpentInWindow;
            if (need > left) need = left;
        }

        uint256 avail = address(this).balance;
        if (need > avail) need = avail;
        if (need == 0) return 0;

        gasSpentInWindow += need;
        (bool ok,) = r.call{value: need}("");
        if (!ok) revert EthTransferFailed();
        sent = need;
        emit GasToppedUp(r, need, r.balance);
    }

    // ── the cron call ────────────────────────────────────────────────────────
    /// @notice Buy core with the accumulated fee ETH (capped per call). Owner-only; the
    /// min-out floor is self-quoted from the pool spot minus fee+slippage, so the cron
    /// needs no arguments and a mid-flight price move just reverts (retry next cycle).
    /// Tops the keeper's gas up FIRST, so the wallet paying for this call is refilled by it.
    function buyback() external onlyOwner nonReentrant returns (uint256 coreOut) {
        topUpGas();
        uint256 amountIn = address(this).balance;
        if (amountIn > maxWethPerSwap) amountIn = maxWethPerSwap;
        if (amountIn == 0) revert NothingToBuy();

        uint256 minOut = _floor(amountIn);
        weth.deposit{value: amountIn}();
        IERC20(address(weth)).forceApprove(address(v3Router), amountIn);
        coreOut = v3Router.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(core),
                fee: poolFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        emit Buyback(amountIn, coreOut);
    }

    /// @dev Spot-quoted floor: expected out at the pool's current price, minus fee+slippage.
    /// The spot is marginal (fee-exclusive), so the pool fee must be subtracted too.
    function _floor(uint256 amountIn) internal view returns (uint256) {
        address pool = factory.getPool(address(weth), address(core), poolFee);
        if (pool == address(0)) revert NoPool();
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        bool wethIsToken0 = address(weth) < address(core);
        // expected = amountIn × P or ÷ P, with P = (sqrtP/2^96)² — two mulDivs avoid overflow.
        uint256 expected = wethIsToken0
            ? Math.mulDiv(Math.mulDiv(amountIn, sqrtP, 1 << 96), sqrtP, 1 << 96)
            : Math.mulDiv(Math.mulDiv(amountIn, 1 << 96, sqrtP), 1 << 96, sqrtP);
        uint256 poolFeeBps = uint256(poolFee) / 100; // 1e-6 units → bps
        return (expected * (BPS - poolFeeBps - slippageBps)) / BPS;
    }

    // ── season funding (core never passes through an EOA) ────────────────────
    /// @notice Fund + publish a season on the Merkle distributor straight from this vault.
    /// The distributor's `rootPublisher` must be THIS contract.
    function publishSeason(uint256 season, uint256 amount, bytes32 root, uint256 total)
        external
        onlyOwner
        nonReentrant
    {
        if (distributor == address(0)) revert ZeroAddress();
        core.forceApprove(distributor, amount);
        ISeasonDistributorB(distributor).fundAndPublish(season, amount, root, total);
        emit SeasonPublished(season, amount, root, total);
    }

    // ── escape hatches (owner) ───────────────────────────────────────────────
    function withdrawEth(address to, uint256 amount) external onlyOwner nonReentrant {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthWithdrawn(to, amount);
    }

    /// @notice Withdraw any held token — e.g. the season TEAM CUT (carved off each bought
    /// batch before publishing) or a rescue. Owner-only, like every value move here.
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(to, amount);
        emit TokenWithdrawn(token, to, amount);
    }
}
