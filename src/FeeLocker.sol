// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";
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
///   - buys pay 1% in WETH  -> split 50/50 between treasury and the token's dev
///   - sells pay 1% in token -> BURNED (never paid to anyone, so neither the
///     dev nor the platform can dump fee-tokens on holders)
contract FeeLocker is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyLaunchpad();
    error LaunchpadAlreadySet();
    error UnknownToken();
    error AlreadyRegistered();
    error NothingToClaim();
    error ZeroAddress();

    uint16 public constant BPS = 10_000;
    /// @notice Fixed 50/50 WETH split between treasury and dev (constant on
    /// purpose — cannot be changed retroactively against accrued fees).
    uint16 public constant TREASURY_SHARE_BPS = 5_000;

    INonfungiblePositionManager public immutable positionManager;
    IERC20 public immutable weth;
    address public launchpad;
    address public treasury;

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
        uint256 tokensBurned
    );
    event TreasurySet(address treasury);
    event LaunchpadSet(address launchpad);

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

    /// @notice Called by the launchpad right after it mints the LP position
    /// with this locker as the NFT recipient.
    function register(address token, uint256 tokenId, bool tokenIsToken0) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (positions[token].exists) revert AlreadyRegistered();
        positions[token] = LockedPosition({tokenId: tokenId, tokenIsToken0: tokenIsToken0, exists: true});
        emit PositionLocked(token, tokenId, tokenIsToken0);
    }

    /// @notice Collect a token's accrued pool fees. Permissionless — payout
    /// addresses are fixed: WETH splits 50/50 to treasury and the token's dev,
    /// and the token-side fees are burned.
    function claim(address token)
        public
        nonReentrant
        returns (uint256 wethToTreasury, uint256 wethToDev, uint256 tokensBurned)
    {
        LockedPosition memory pos = positions[token];
        if (!pos.exists) revert UnknownToken();
        address dev = ICreatorRegistryV3(launchpad).creatorOf(token);
        if (dev == address(0)) revert UnknownToken();

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
            LaunchToken(token).burn(tokenAmount);
            tokensBurned = tokenAmount;
        }
        if (wethAmount > 0) {
            wethToTreasury = (wethAmount * TREASURY_SHARE_BPS) / BPS;
            wethToDev = wethAmount - wethToTreasury;
            if (wethToTreasury > 0) weth.safeTransfer(treasury, wethToTreasury);
            if (wethToDev > 0) weth.safeTransfer(dev, wethToDev);
        }
        emit FeesClaimed(token, dev, msg.sender, wethToTreasury, wethToDev, tokensBurned);
    }

    function claimMany(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            claim(tokens[i]);
        }
    }

    /// @notice Accept LP NFTs only from the position manager.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert OnlyLaunchpad();
        return this.onERC721Received.selector;
    }
}
