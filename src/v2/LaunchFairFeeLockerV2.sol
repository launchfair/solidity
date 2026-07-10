// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 — https://hood.launchfair.app

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {INonfungiblePositionManager} from "../interfaces/IUniswapV3.sol";
import {LaunchTokenV2} from "./LaunchTokenV2.sol";

interface ICreatorRegistryV2 {
    function creatorOf(address token) external view returns (address);
}

interface IDistributorV2 {
    function notify(address token, uint256 amount) external;
}

/// @notice Locks each V2 token's Uniswap V3 LP position forever and routes
/// claimed fees. The NFT can never leave and liquidity can never be decreased.
///
/// WETH split on `claim`:
///   - treasury ALWAYS gets 50%.
///   - creator-half (50%): Base -> dev (or treasury if no dev); Reward /
///     Increasing / Burn -> the distributor, which turns it into holder rewards
///     or a burn. Token-side (sell) fees are burned, exactly like V1.
contract LaunchFairFeeLockerV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyLaunchpad();
    error LaunchpadAlreadySet();
    error DistributorAlreadySet();
    error UnknownToken();
    error AlreadyRegistered();
    error NothingToClaim();
    error ZeroAddress();

    uint16 public constant BPS = 10_000;
    /// @notice Fixed 50% treasury share — constant on purpose (never retroactive).
    uint16 public constant TREASURY_SHARE_BPS = 5_000;

    INonfungiblePositionManager public immutable positionManager;
    IERC20 public immutable weth;
    address public launchpad;
    address public distributor;
    address public treasury;

    struct LockedPosition {
        uint256 tokenId;
        bool tokenIsToken0;
        bool exists;
    }

    mapping(address token => LockedPosition) public positions;

    event PositionLocked(address indexed token, uint256 indexed tokenId, bool tokenIsToken0);
    event FeesClaimed(
        address indexed token,
        uint8 mode,
        address caller,
        uint256 wethToTreasury,
        uint256 wethToDev,
        uint256 wethToMechanism,
        uint256 tokensBurned
    );
    event TreasurySet(address treasury);
    event LaunchpadSet(address launchpad);
    event DistributorSet(address distributor);
    event ModeSplitSet(uint16 treasuryBps, uint16 devBps, uint16 mechanismBps);

    /// @notice WETH split for MODE tokens (Reward/Increasing/Burn), owner-tunable
    /// and applied at claim time. treasury + dev + mechanism = 10000. The rest
    /// (mechanism) funds holder rewards / buyback-burn. Base tokens ignore this
    /// and always split 50/50 treasury/dev.
    ///
    /// Default 1:1:4 (dev 0.5% / treasury 0.5% / rewards 2% at a 3% pool; or
    /// ~0.17/0.17/0.67 at the current 1% pool). Capped so treasury+dev can't
    /// starve the mechanism, and the mechanism can't take everything.
    uint16 public modeTreasuryBps = 1_667;
    uint16 public modeDevBps = 1_666;

    error InvalidSplit();

    function modeMechanismBps() public view returns (uint16) {
        return BPS - modeTreasuryBps - modeDevBps;
    }

    constructor(address owner_, INonfungiblePositionManager pm_, IERC20 weth_, address treasury_) Ownable(owner_) {
        if (address(pm_) == address(0) || address(weth_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        positionManager = pm_;
        weth = weth_;
        treasury = treasury_;
    }

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

    /// @notice Tune the MODE-token WETH split (applies to future claims). The
    /// mechanism always keeps at least 20% so a mode token can't stop rewarding
    /// holders. Base tokens are unaffected (always 50/50).
    function setModeSplit(uint16 treasuryBps, uint16 devBps) external onlyOwner {
        if (uint256(treasuryBps) + devBps > 8_000) revert InvalidSplit();
        modeTreasuryBps = treasuryBps;
        modeDevBps = devBps;
        emit ModeSplitSet(treasuryBps, devBps, BPS - treasuryBps - devBps);
    }

    function register(address token, uint256 tokenId, bool tokenIsToken0) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (positions[token].exists) revert AlreadyRegistered();
        positions[token] = LockedPosition({tokenId: tokenId, tokenIsToken0: tokenIsToken0, exists: true});
        emit PositionLocked(token, tokenId, tokenIsToken0);
    }

    /// @notice Collect a token's accrued pool fees and route them. Permissionless.
    function claim(address token)
        public
        nonReentrant
        returns (uint256 wethToTreasury, uint256 wethToDev, uint256 wethToMechanism, uint256 tokensBurned)
    {
        LockedPosition memory pos = positions[token];
        if (!pos.exists) revert UnknownToken();

        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: pos.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (uint256 tokenAmount, uint256 wethAmount) = pos.tokenIsToken0 ? (amount0, amount1) : (amount1, amount0);
        if (tokenAmount == 0 && wethAmount == 0) revert NothingToClaim();

        if (tokenAmount > 0) {
            LaunchTokenV2(token).burn(tokenAmount);
            tokensBurned = tokenAmount;
        }

        LaunchTokenV2.Mode m = LaunchTokenV2(token).mode();
        if (wethAmount > 0) {
            if (m == LaunchTokenV2.Mode.Base) {
                // Base: 50/50 treasury/dev (dev share -> treasury if no dev).
                wethToTreasury = (wethAmount * TREASURY_SHARE_BPS) / BPS;
                wethToDev = wethAmount - wethToTreasury;
            } else {
                // Mode token: owner-tuned split; the remainder funds the mechanism.
                wethToTreasury = (wethAmount * modeTreasuryBps) / BPS;
                wethToDev = (wethAmount * modeDevBps) / BPS;
                wethToMechanism = wethAmount - wethToTreasury - wethToDev;
            }

            if (wethToTreasury > 0) weth.safeTransfer(treasury, wethToTreasury);
            if (wethToDev > 0) {
                address dev = ICreatorRegistryV2(launchpad).creatorOf(token);
                weth.safeTransfer(dev == address(0) ? treasury : dev, wethToDev);
            }
            if (wethToMechanism > 0) {
                weth.safeTransfer(distributor, wethToMechanism);
                IDistributorV2(distributor).notify(token, wethToMechanism);
            }
        }
        emit FeesClaimed(token, uint8(m), msg.sender, wethToTreasury, wethToDev, wethToMechanism, tokensBurned);
    }

    function claimMany(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            claim(tokens[i]);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert OnlyLaunchpad();
        return this.onERC721Received.selector;
    }
}
