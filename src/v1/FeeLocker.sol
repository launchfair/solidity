// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {INonfungiblePositionManager} from "../interfaces/IUniswapV3.sol";
import {LaunchToken} from "./LaunchToken.sol";

interface ICreatorRegistryV3 {
    function creatorOf(address token) external view returns (address);
}

/// @notice Permanently locks each launched token's Uniswap V3 LP position and
/// handles fee claims. The position NFT can NEVER leave this contract and
/// liquidity can never be decreased — there is deliberately no function for
/// either, so the pool's liquidity is locked forever (no rug, no migration).
///
/// V3 fees accrue in the swap's input asset:
///   - buys pay 1% in WETH  -> split 25% treasury / 25% dev / 50% flagship buyback
///   - sells pay 1% in token -> BURNED (never paid to anyone, so neither the
///     dev nor the platform can dump fee-tokens on holders)
///
/// The 50% "flagship buyback" slice is the platform flywheel: it funds buybacks
/// of the platform (flagship) token, later redistributed to active traders by
/// weekly season points. It is sent to `flagshipSink` — a destination the
/// deployer points at the buyback keeper once the flagship exists. Until
/// `flagshipSink` is set the slice folds back into `treasury`, so V1 works fully
/// before the flagship is deployed and no WETH is ever stuck.
contract FeeLocker is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyLaunchpad();
    error LaunchpadAlreadySet();
    error UnknownToken();
    error AlreadyRegistered();
    error NothingToClaim();
    error ZeroAddress();
    error InvalidShares();

    uint16 public constant BPS = 10_000;
    /// @notice Floor on the creator (dev) share — the creator slice can never be tuned to zero,
    /// so "a cut goes to creators" can't be silently revoked. 1000 = 10%.
    uint16 public constant MIN_DEV_BPS = 1_000;
    /// @notice Owner-tunable WETH split of the collected fee, in bps (the three MUST sum
    /// to BPS, and dev ≥ MIN_DEV_BPS). Defaults to 25% treasury / 25% dev / 50% flagship buyback;
    /// retune any time via `setFeeShares`. NOTE: a change applies to every claim AFTER it —
    /// including fees that had already accrued but weren't yet claimed.
    uint16 public treasuryShareBps = 2_500; // 25%
    uint16 public devShareBps = 2_500; // 25%
    uint16 public flagshipShareBps = 5_000; // 50% (the claim pays the exact remainder so 100% is always disbursed)

    INonfungiblePositionManager public immutable positionManager;
    IERC20 public immutable weth;
    address public launchpad;
    address public treasury;
    /// @notice Destination of the 50% flagship-buyback slice. address(0) => the
    /// slice folds into treasury (the pre-flagship default). Owner-settable so the
    /// deployer can point it at the buyback keeper once the flagship token is live.
    address public flagshipSink;

    struct LockedPosition {
        uint256 tokenId;
        bool tokenIsToken0; // token/WETH ordering inside the pool
        bool exists;
    }

    mapping(address token => LockedPosition) public positions;

    event PositionLocked(address indexed token, uint256 indexed tokenId, bool tokenIsToken0);
    event FeesClaimed(
        address indexed token,
        address indexed dev,
        address caller,
        uint256 wethToTreasury,
        uint256 wethToDev,
        uint256 wethToFlagship,
        uint256 tokensBurned
    );
    event TreasurySet(address treasury);
    event LaunchpadSet(address launchpad);
    event FlagshipSinkSet(address flagshipSink);
    event FeeSharesSet(uint16 treasuryBps, uint16 devBps, uint16 flagshipBps);

    constructor(address owner_, INonfungiblePositionManager positionManager_, IERC20 weth_, address treasury_)
        Ownable(owner_)
    {
        if (address(positionManager_) == address(0) || address(weth_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        positionManager = positionManager_;
        weth = weth_;
        treasury = treasury_;
    }

    /// @notice One-time wiring of the launchpad (deployed after the locker).
    function setLaunchpad(address launchpad_) external onlyOwner {
        if (launchpad != address(0)) revert LaunchpadAlreadySet();
        if (launchpad_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        emit LaunchpadSet(launchpad_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Point the 50% flagship-buyback slice at a sink (the buyback keeper
    /// wallet, once the flagship exists). Re-settable by the owner; setting it back
    /// to address(0) disables the flagship route and folds that slice into treasury.
    function setFlagshipSink(address sink) external onlyOwner {
        flagshipSink = sink;
        emit FlagshipSinkSet(sink);
    }

    /// @notice Retune the fee split (bps of the collected fee). The three shares MUST sum
    /// to BPS (10000). Applies to every claim AFTER this call.
    function setFeeShares(uint16 treasuryBps, uint16 devBps, uint16 flagshipBps) external onlyOwner {
        if (uint256(treasuryBps) + devBps + flagshipBps != BPS) revert InvalidShares();
        if (devBps < MIN_DEV_BPS) revert InvalidShares(); // creators can never be zeroed out
        treasuryShareBps = treasuryBps;
        devShareBps = devBps;
        flagshipShareBps = flagshipBps;
        emit FeeSharesSet(treasuryBps, devBps, flagshipBps);
    }

    /// @notice Called by the launchpad right after it mints the LP position
    /// with this locker as the NFT recipient.
    function register(address token, uint256 tokenId, bool tokenIsToken0) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (positions[token].exists) revert AlreadyRegistered();
        positions[token] = LockedPosition({tokenId: tokenId, tokenIsToken0: tokenIsToken0, exists: true});
        emit PositionLocked(token, tokenId, tokenIsToken0);
    }

    /// @notice Collect a token's accrued pool fees. Permissionless — payout
    /// addresses are fixed: WETH splits 25% treasury / 25% dev / 50% flagship
    /// buyback (the flagship slice folds into treasury until the sink is set),
    /// and the token-side fees are burned.
    function claim(address token)
        public
        nonReentrant
        returns (uint256 wethToTreasury, uint256 wethToDev, uint256 wethToFlagship, uint256 tokensBurned)
    {
        return _claim(token, true);
    }

    /// @notice Batch-claim. Unlike calling `claim` in a loop, a token with nothing to claim
    /// (or an unknown token) is skipped rather than reverting the whole batch — so one idle
    /// token can't DoS a keeper's sweep.
    function claimMany(address[] calldata tokens) external nonReentrant {
        for (uint256 i = 0; i < tokens.length; i++) {
            _claim(tokens[i], false);
        }
    }

    function _claim(address token, bool revertOnEmpty)
        internal
        returns (uint256 wethToTreasury, uint256 wethToDev, uint256 wethToFlagship, uint256 tokensBurned)
    {
        LockedPosition memory pos = positions[token];
        if (!pos.exists) {
            if (revertOnEmpty) revert UnknownToken();
            return (0, 0, 0, 0);
        }
        address dev = ICreatorRegistryV3(launchpad).creatorOf(token);
        if (dev == address(0)) {
            if (revertOnEmpty) revert UnknownToken();
            return (0, 0, 0, 0);
        }

        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: pos.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (uint256 tokenAmount, uint256 wethAmount) = pos.tokenIsToken0 ? (amount0, amount1) : (amount1, amount0);
        if (tokenAmount == 0 && wethAmount == 0) {
            if (revertOnEmpty) revert NothingToClaim();
            return (0, 0, 0, 0);
        }

        if (tokenAmount > 0) {
            LaunchToken(token).burn(tokenAmount);
            tokensBurned = tokenAmount;
        }
        if (wethAmount > 0) {
            wethToTreasury = (wethAmount * treasuryShareBps) / BPS;
            wethToDev = (wethAmount * devShareBps) / BPS;
            wethToFlagship = wethAmount - wethToTreasury - wethToDev; // exact remainder (flagship share + dust)
            address sink = flagshipSink;
            if (sink == address(0)) {
                // No flagship yet: fold the buyback slice into treasury (nothing stuck).
                wethToTreasury += wethToFlagship;
                wethToFlagship = 0;
            }
            if (wethToTreasury > 0) weth.safeTransfer(treasury, wethToTreasury);
            if (wethToDev > 0) weth.safeTransfer(dev, wethToDev);
            if (wethToFlagship > 0) weth.safeTransfer(sink, wethToFlagship);
        }
        emit FeesClaimed(token, dev, msg.sender, wethToTreasury, wethToDev, wethToFlagship, tokensBurned);
    }

    /// @notice Accept LP NFTs only from the position manager.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert OnlyLaunchpad();
        return this.onERC721Received.selector;
    }
}
