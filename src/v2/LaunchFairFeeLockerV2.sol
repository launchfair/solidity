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
        uint256 creatorHalf,
        uint256 tokensBurned
    );
    event TreasurySet(address treasury);
    event LaunchpadSet(address launchpad);
    event DistributorSet(address distributor);

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
        returns (uint256 wethToTreasury, uint256 creatorHalf, uint256 tokensBurned)
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
            wethToTreasury = (wethAmount * TREASURY_SHARE_BPS) / BPS;
            creatorHalf = wethAmount - wethToTreasury;
            if (wethToTreasury > 0) weth.safeTransfer(treasury, wethToTreasury);

            if (creatorHalf > 0) {
                if (m == LaunchTokenV2.Mode.Base) {
                    address dev = ICreatorRegistryV2(launchpad).creatorOf(token);
                    weth.safeTransfer(dev == address(0) ? treasury : dev, creatorHalf);
                } else {
                    // Mode token: fund the reward/burn mechanism.
                    weth.safeTransfer(distributor, creatorHalf);
                    IDistributorV2(distributor).notify(token, creatorHalf);
                }
            }
        }
        emit FeesClaimed(token, uint8(m), msg.sender, wethToTreasury, creatorHalf, tokensBurned);
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
