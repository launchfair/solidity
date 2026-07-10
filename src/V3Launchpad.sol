// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LaunchToken} from "./LaunchToken.sol";
import {FeeLocker} from "./FeeLocker.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager, IWETH} from "./interfaces/IUniswapV3.sol";

/// @notice V3 single-sided hybrid launchpad: every token launches straight into a
/// REAL Uniswap V3 pool as a single-sided range order (full supply), so DEX
/// terminals (GMGN, DexScreener, ...) index it from block one — no bonding
/// curve phase, no custom data integration needed.
///
/// - The LP NFT is minted directly to the FeeLocker and locked forever.
/// - The pool's fee tier (e.g. 1%) replaces curve fees: buys pay WETH fees
///   (50/50 treasury/dev via FeeLocker.claim), sells pay token fees (burned).
/// - The single-sided position IS the bonding curve: a V3 range order is
///   mathematically a virtual-reserve constant-product curve, so traders get
///   the classic deterministic price ladder (see curveProgress) while
///   terminals just see a normal pool.
/// - "Graduation" is pure gamification: a permissionless milestone check that
///   fires an event when the pool price crosses the graduation price. Nothing
///   migrates; liquidity never moves.
contract V3Launchpad is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LaunchInfo {
        address pool;
        address creator; // the token's dev — receives the dev share of WETH fees
        bool tokenIsToken0;
        bool graduated;
        uint256 positionTokenId;
        uint256 graduationWethAmount; // WETH-to-bond, snapshotted at creation (never retroactive)
    }

    struct PoolConfig {
        uint24 feeTier; // e.g. 10_000 = 1% per swap, the "1%/1% both ends" analog
        int24 tickLower0; // range start when token is token0 (must be > initial tick)
        int24 tickUpper0; // range end when token is token0
        uint128 tokenTotalSupply;
        uint256 initialPriceWethPerToken; // WETH wei per 1e18 token units at launch
        uint256 graduationWethAmount; // WETH raised into the pool that bonds/graduates a token
        uint16 maxBuyBps; // anti-sniper wallet cap during launch, e.g. 200 = 2% (0 = off)
        uint32 maxBuyBlocks; // how many blocks the cap lasts, e.g. 360 (0 = off)
    }

    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager public immutable positionManager;
    FeeLocker public immutable locker;
    address public immutable weth;

    uint24 public immutable feeTier;
    int24 public immutable tickLower0;
    int24 public immutable tickUpper0;
    uint128 public immutable tokenTotalSupply;
    uint256 public immutable initialPriceWethPerToken;
    /// @notice Default WETH-to-bond for NEW tokens — the manual "weth to bond"
    /// knob. Owner-settable (setGraduationWethAmount) but changes ONLY affect
    /// future tokens: each token snapshots its own target at creation, so a
    /// change is never retroactive. Measured as WETH held by the pool.
    uint256 public defaultGraduationWethAmount;
    uint16 public immutable maxBuyBps;
    uint32 public immutable maxBuyBlocks;

    // Uniswap V3 price bounds for an unconstrained dev-buy swap
    // (TickMath.MIN_SQRT_RATIO + 1 / MAX_SQRT_RATIO - 1).
    uint160 private constant MIN_SQRT = 4295128740;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    /// @notice Platform website stamped into each token at creation.
    string public officialWebsite;

    /// @notice Flat fee (wei) charged to the dev at token creation and
    /// forwarded to the treasury (locker.treasury()). Default 0.000005 ETH.
    uint256 public creationFeeWei = 0.000005 ether;
    /// @notice Hard cap so the owner can never set an abusive creation fee.
    uint256 public constant MAX_CREATION_FEE_WEI = 0.001 ether;

    mapping(address token => LaunchInfo) internal _launches;

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address pool,
        uint256 positionTokenId,
        bool tokenIsToken0,
        string name,
        string symbol,
        LaunchToken.Metadata metadata
    );
    event Graduated(address indexed token, address pool, uint256 wethBonded);
    event CreatorTransferred(address indexed token, address indexed oldCreator, address indexed newCreator);
    event OfficialWebsiteSet(string website);
    event GraduationWethAmountSet(uint256 amount);
    event CreationFeePaid(address indexed creator, address indexed token, uint256 fee);
    event CreationFeeSet(uint256 weiAmount);
    event DevBought(address indexed token, address indexed buyer, uint256 wethIn, uint256 tokensOut);

    error ZeroAddress();
    error InvalidPoolConfig();
    error InvalidMetadata();
    error UnknownToken();
    error AlreadyGraduated();
    error NotEnoughWethBonded();
    error PoolPriceUnsafe();
    error OnlyTreasury();
    error InsufficientCreationFee();
    error CreationFeeTooHigh();
    error CreationFeeTransferFailed();
    error DevBuyTooLittle();
    error OnlyPool();

    constructor(
        address owner_,
        IUniswapV3Factory factory_,
        INonfungiblePositionManager positionManager_,
        FeeLocker locker_,
        address weth_,
        PoolConfig memory cfg,
        string memory officialWebsite_
    ) Ownable(owner_) {
        if (
            address(factory_) == address(0) || address(positionManager_) == address(0) || address(locker_) == address(0)
                || weth_ == address(0)
        ) revert ZeroAddress();
        if (
            cfg.tokenTotalSupply == 0 || cfg.initialPriceWethPerToken == 0 || cfg.tickLower0 >= cfg.tickUpper0
                || cfg.graduationWethAmount == 0 || cfg.maxBuyBps > 10_000
        ) revert InvalidPoolConfig();

        factory = factory_;
        positionManager = positionManager_;
        locker = locker_;
        weth = weth_;
        feeTier = cfg.feeTier;
        tickLower0 = cfg.tickLower0;
        tickUpper0 = cfg.tickUpper0;
        tokenTotalSupply = cfg.tokenTotalSupply;
        initialPriceWethPerToken = cfg.initialPriceWethPerToken;
        defaultGraduationWethAmount = cfg.graduationWethAmount;
        maxBuyBps = cfg.maxBuyBps;
        maxBuyBlocks = cfg.maxBuyBlocks;
        officialWebsite = officialWebsite_;
    }

    // ─────────────────────────────── token launch ───────────────────────────────

    function createToken(string calldata name, string calldata symbol)
        external
        payable
        nonReentrant
        returns (address token)
    {
        LaunchToken.Metadata memory empty;
        token = _createToken(name, symbol, empty, bytes32(0), 0, 0);
    }

    /// @param salt Client-chosen entropy. If a griefer poisons the predicted
    /// pool (see below), retry with a fresh salt for a fresh token address.
    function createToken(
        string calldata name,
        string calldata symbol,
        LaunchToken.Metadata calldata metadata,
        bytes32 salt
    ) external payable nonReentrant returns (address token) {
        token = _createToken(name, symbol, metadata, salt, 0, 0);
    }

    /// @notice Create a token AND buy some of it in the SAME transaction. Send
    /// `msg.value = creationFeeWei + <ETH to spend>`; everything above the fee is
    /// swapped through the new pool for tokens sent to you. `minTokensOut` guards
    /// slippage. The buy is still capped at 2% of supply during the launch window.
    function createAndBuy(
        string calldata name,
        string calldata symbol,
        LaunchToken.Metadata calldata metadata,
        bytes32 salt,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token) {
        if (msg.value <= creationFeeWei) revert InsufficientCreationFee();
        token = _createToken(name, symbol, metadata, salt, msg.value - creationFeeWei, minTokensOut);
    }

    function _createToken(
        string memory name,
        string memory symbol,
        LaunchToken.Metadata memory metadata,
        bytes32 salt,
        uint256 devBuyWei,
        uint256 minTokensOut
    ) internal returns (address token) {
        // Flat creation fee (charged in the native token, forwarded to treasury
        // after the token is live; excess is refunded).
        if (msg.value < creationFeeWei) revert InsufficientCreationFee();

        _validateMetadataString(name);
        _validateMetadataString(symbol);
        _validateMetadataString(metadata.logoURI);
        _validateMetadataString(metadata.website);
        _validateMetadataString(metadata.telegram);
        _validateMetadataString(metadata.discord);
        _validateMetadataString(metadata.twitter);

        // CREATE2 scoped to the creator: a griefer who poisons the pool of a
        // predicted token address only blocks that one (creator, salt) combo,
        // and each attack costs them more gas than the creator's retry.
        token = address(
            new LaunchToken{salt: keccak256(abi.encode(msg.sender, salt))}(
                name, symbol, tokenTotalSupply, officialWebsite, metadata, maxBuyBps, maxBuyBlocks
            )
        );
        // Exempt protocol plumbing from the launch guard before any transfers.
        LaunchToken(token).setLimitExempt(address(positionManager), true);
        LaunchToken(token).setLimitExempt(address(locker), true);

        bool tokenIsToken0 = token < weth;
        uint160 targetSqrtPriceX96 = _sqrtPriceX96For(initialPriceWethPerToken, tokenIsToken0);

        // Handle third parties pre-creating (or pre-initializing) the pool:
        // - not created           -> create + initialize at the launch price
        // - created, uninitialized-> initialize at the launch price
        // - initialized at/below our launch price -> harmless, the single-sided
        //   order still mints entirely in tokens; proceed
        // - initialized above it  -> the mint would need WETH we don't provide;
        //   revert so the creator retries with a new salt
        address pool = factory.getPool(token, weth, feeTier);
        if (pool == address(0)) pool = factory.createPool(token, weth, feeTier);
        LaunchToken(token).setLimitExempt(pool, true);
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (currentSqrtPriceX96 == 0) {
            IUniswapV3Pool(pool).initialize(targetSqrtPriceX96);
        } else {
            bool safe =
                tokenIsToken0 ? currentSqrtPriceX96 <= targetSqrtPriceX96 : currentSqrtPriceX96 >= targetSqrtPriceX96;
            if (!safe) revert PoolPriceUnsafe();
        }

        // Single-sided range order: the full supply sits just above the initial
        // price; buyers pull tokens out, WETH accumulates into the position.
        (int24 tickLower, int24 tickUpper) = tokenIsToken0 ? (tickLower0, tickUpper0) : (-tickUpper0, -tickLower0);

        IERC20(token).forceApprove(address(positionManager), tokenTotalSupply);
        (uint256 positionTokenId,, uint256 amount0Used, uint256 amount1Used) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIsToken0 ? token : weth,
                token1: tokenIsToken0 ? weth : token,
                fee: feeTier,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: tokenIsToken0 ? tokenTotalSupply : 0,
                amount1Desired: tokenIsToken0 ? 0 : tokenTotalSupply,
                amount0Min: 0, // pool is initialized atomically above; no price gap
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );
        // solhint-disable-next-line no-unused-vars
        (amount0Used, amount1Used); // amounts implied by the position; dust handled below

        // Burn any rounding dust the position manager didn't take.
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) LaunchToken(token).burn(dust);

        _launches[token] = LaunchInfo({
            pool: pool,
            creator: msg.sender,
            tokenIsToken0: tokenIsToken0,
            graduated: false,
            positionTokenId: positionTokenId,
            graduationWethAmount: defaultGraduationWethAmount // frozen for this token
        });
        locker.register(token, positionTokenId, tokenIsToken0);

        emit TokenLaunched(token, msg.sender, pool, positionTokenId, tokenIsToken0, name, symbol, metadata);

        // Collect the flat creation fee to the treasury; refund any overpayment.
        // Done last (CEI) and guarded by nonReentrant on the external entrypoints.
        uint256 fee = creationFeeWei;
        if (fee > 0) {
            (bool okFee,) = locker.treasury().call{value: fee}("");
            if (!okFee) revert CreationFeeTransferFailed();
            emit CreationFeePaid(msg.sender, token, fee);
        }
        // Atomic dev buy: swap the caller's extra ETH for tokens delivered to the
        // creator (still subject to the 2% launch cap — the creator isn't exempt).
        if (devBuyWei > 0) {
            _devBuy(token, pool, tokenIsToken0, devBuyWei, minTokensOut);
        }
        uint256 refund = msg.value - fee - devBuyWei;
        if (refund > 0) {
            (bool okRefund,) = msg.sender.call{value: refund}("");
            if (!okRefund) revert CreationFeeTransferFailed();
        }
    }

    /// @dev Wrap `wethIn` ETH and swap it through the token's pool for tokens,
    /// delivered to the creator (msg.sender of the enclosing create). Reverts if
    /// the output is below `minTokensOut`.
    function _devBuy(address token, address pool, bool tokenIsToken0, uint256 wethIn, uint256 minTokensOut) internal {
        IWETH(weth).deposit{value: wethIn}();
        bool zeroForOne = !tokenIsToken0; // WETH is the input asset
        (int256 amount0, int256 amount1) = IUniswapV3Pool(pool).swap(
            msg.sender, zeroForOne, int256(wethIn), zeroForOne ? MIN_SQRT : MAX_SQRT, abi.encode(token)
        );
        uint256 tokensOut = uint256(-(tokenIsToken0 ? amount0 : amount1));
        if (tokensOut < minTokensOut) revert DevBuyTooLittle();
        emit DevBought(token, msg.sender, wethIn, tokensOut);
    }

    /// @notice Uniswap V3 swap callback — pays the WETH owed for a dev buy. Only
    /// the token's canonical pool can invoke it (prevents spoofed calls).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        address token = abi.decode(data, (address));
        if (msg.sender != factory.getPool(token, weth, feeTier)) revert OnlyPool();
        if (amount0Delta > 0) IERC20(weth).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(weth).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    // ─────────────────────────────── graduation (gamification) ───────────────────

    /// @notice Permissionless milestone poke: marks the token graduated once the
    /// pool has bonded at least `graduationWethAmount` of WETH (net of sells).
    /// Purely cosmetic — liquidity never moves; frontends/indexers use the event
    /// for badges and sorting.
    function checkGraduation(address token) external returns (bool graduated) {
        LaunchInfo storage info = _launches[token];
        if (info.creator == address(0)) revert UnknownToken();
        if (info.graduated) revert AlreadyGraduated();

        uint256 wethBonded = IERC20(weth).balanceOf(info.pool);
        if (wethBonded < info.graduationWethAmount) revert NotEnoughWethBonded();

        info.graduated = true;
        emit Graduated(token, info.pool, wethBonded);
        return true;
    }

    // ──────────────────────────────────── views ───────────────────────────────────

    function getLaunch(address token) external view returns (LaunchInfo memory) {
        return _launches[token];
    }

    function creatorOf(address token) external view returns (address) {
        return _launches[token].creator;
    }

    /// @notice Bonding progress toward graduation in bps (0 = nothing bonded,
    /// 10_000 = at/above graduationWethAmount). The progress bar for frontends,
    /// measured against the WETH raised into the pool.
    function curveProgress(address token) external view returns (uint256 bps) {
        LaunchInfo storage info = _launches[token];
        if (info.creator == address(0)) revert UnknownToken();
        if (info.graduated) return 10_000;

        uint256 grad = info.graduationWethAmount;
        if (grad == 0) return 0;
        uint256 wethBonded = IERC20(weth).balanceOf(info.pool);
        if (wethBonded >= grad) return 10_000;
        return (wethBonded * 10_000) / grad;
    }

    /// @notice Pool sqrt price encoding `priceWethPerToken` for either ordering.
    function _sqrtPriceX96For(uint256 priceWethPerToken, bool tokenIsToken0) internal pure returns (uint160) {
        // pool price = token1 raw units per token0 raw unit
        // tokenIsToken0:  price = priceWethPerToken / 1e18
        // else (inverted): price = 1e18 / priceWethPerToken
        uint256 ratioX192 = tokenIsToken0
            ? Math.mulDiv(priceWethPerToken, 1 << 192, 1e18)
            : Math.mulDiv(1e18, 1 << 192, priceWethPerToken);
        return uint160(Math.sqrt(ratioX192));
    }

    // ─────────────────────────────────── admin ────────────────────────────────────

    /// @notice Update the platform website stamped into FUTURE tokens.
    function setOfficialWebsite(string calldata website_) external onlyOwner {
        officialWebsite = website_;
        emit OfficialWebsiteSet(website_);
    }

    /// @notice Update the flat creation fee (capped at MAX_CREATION_FEE_WEI).
    /// Applies to future creations; the destination is always locker.treasury().
    function setCreationFee(uint256 weiAmount) external onlyOwner {
        if (weiAmount > MAX_CREATION_FEE_WEI) revert CreationFeeTooHigh();
        creationFeeWei = weiAmount;
        emit CreationFeeSet(weiAmount);
    }

    /// @notice Manually set the default WETH-to-bond for FUTURE tokens. Existing
    /// tokens keep the target snapshotted at their creation — never retroactive.
    function setGraduationWethAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidPoolConfig();
        defaultGraduationWethAmount = amount;
        emit GraduationWethAmountSet(amount);
    }

    /// @notice Let a token's dev hand fee rights to a new address.
    /// @notice CTO / community-takeover reassignment: the platform TREASURY
    /// assigns (or reassigns) a token's creator — and thus its dev WETH-fee
    /// stream going forward — to any address it sees fit (e.g. a community
    /// takeover of an abandoned token). Only the treasury (`locker.treasury()`)
    /// may call this; the treasury's own 50% fee split is unchanged. There is no
    /// dev-initiated transfer — creator assignment is treasury-controlled.
    function transferCreatorByTreasury(address token, address newCreator) external {
        LaunchInfo storage info = _launches[token];
        if (info.creator == address(0)) revert UnknownToken();
        if (msg.sender != locker.treasury()) revert OnlyTreasury();
        if (newCreator == address(0)) revert ZeroAddress();
        emit CreatorTransferred(token, info.creator, newCreator);
        info.creator = newCreator;
    }

    // ────────────────────────────────── internals ─────────────────────────────────

    /// @dev Allows any UTF-8 (emoji included); rejects only `"`, `\` and
    /// control characters, which could inject into contractURI() JSON.
    function _validateMetadataString(string memory s) internal pure {
        bytes memory b = bytes(s);
        if (b.length > 256) revert InvalidMetadata();
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            if (ch < 0x20 || ch == 0x22 || ch == 0x5C) revert InvalidMetadata();
        }
    }
}
