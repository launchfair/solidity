// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 — https://hood.launchfair.app
// Same V3 single-sided hybrid launch as V1, plus token MODES
// (Base/Reward/Increasing/Burn). V1 stays live and untouched — this is a
// parallel deployment.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LaunchTokenV2} from "./LaunchTokenV2.sol";
import {LaunchFairFeeLockerV2} from "./LaunchFairFeeLockerV2.sol";
import {TokenDeployerV2} from "./TokenDeployerV2.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager, IWETH} from "../interfaces/IUniswapV3.sol";

contract LaunchFairV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LaunchInfo {
        address pool;
        address creator;
        bool tokenIsToken0;
        bool graduated;
        uint256 positionTokenId;
        uint256 graduationWethAmount;
    }

    struct PoolConfig {
        uint24 feeTier;
        int24 tickLower0;
        int24 tickUpper0;
        uint128 tokenTotalSupply;
        uint256 initialPriceWethPerToken;
        uint256 graduationWethAmount;
        uint16 maxBuyBps;
        uint32 maxBuyBlocks;
    }

    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager public immutable positionManager;
    LaunchFairFeeLockerV2 public immutable locker;
    address public immutable distributor;
    TokenDeployerV2 public immutable deployer;
    address public immutable weth;

    uint24 public immutable feeTier;
    int24 public immutable tickLower0;
    int24 public immutable tickUpper0;
    uint128 public immutable tokenTotalSupply;
    uint256 public immutable initialPriceWethPerToken;
    uint256 public defaultGraduationWethAmount;
    uint16 public immutable maxBuyBps;
    uint32 public immutable maxBuyBlocks;

    uint160 private constant MIN_SQRT = 4295128740;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    string public officialWebsite;
    uint256 public creationFeeWei = 0.000005 ether;
    uint256 public constant MAX_CREATION_FEE_WEI = 0.001 ether;

    mapping(address token => LaunchInfo) internal _launches;

    event TokenLaunchedV2(
        address indexed token,
        address indexed creator,
        address pool,
        uint256 positionTokenId,
        bool tokenIsToken0,
        uint8 mode,
        address rewardToken,
        string name,
        string symbol,
        LaunchTokenV2.Metadata metadata
    );
    event Graduated(address indexed token, address pool, uint256 wethBonded);
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
    error InsufficientCreationFee();
    error CreationFeeTooHigh();
    error CreationFeeTransferFailed();
    error DevBuyTooLittle();
    error OnlyPool();
    error RewardPoolNotFound();
    error InvalidRewardToken();

    constructor(
        address owner_,
        IUniswapV3Factory factory_,
        INonfungiblePositionManager positionManager_,
        LaunchFairFeeLockerV2 locker_,
        address distributor_,
        TokenDeployerV2 deployer_,
        address weth_,
        PoolConfig memory cfg,
        string memory officialWebsite_
    ) Ownable(owner_) {
        if (
            address(factory_) == address(0) || address(positionManager_) == address(0) || address(locker_) == address(0)
                || distributor_ == address(0) || address(deployer_) == address(0) || weth_ == address(0)
        ) revert ZeroAddress();
        if (
            cfg.tokenTotalSupply == 0 || cfg.initialPriceWethPerToken == 0 || cfg.tickLower0 >= cfg.tickUpper0
                || cfg.graduationWethAmount == 0 || cfg.maxBuyBps > 10_000
        ) revert InvalidPoolConfig();
        factory = factory_;
        positionManager = positionManager_;
        locker = locker_;
        distributor = distributor_;
        deployer = deployer_;
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

    function createToken(
        string calldata name,
        string calldata symbol,
        LaunchTokenV2.Metadata calldata metadata,
        bytes32 salt,
        LaunchTokenV2.Mode mode,
        address rewardToken,
        uint256 minHold
    ) external payable nonReentrant returns (address token) {
        token = _createToken(name, symbol, metadata, salt, mode, rewardToken, minHold, 0, 0);
    }

    function createAndBuy(
        string calldata name,
        string calldata symbol,
        LaunchTokenV2.Metadata calldata metadata,
        bytes32 salt,
        LaunchTokenV2.Mode mode,
        address rewardToken,
        uint256 minHold,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token) {
        if (msg.value <= creationFeeWei) revert InsufficientCreationFee();
        token = _createToken(name, symbol, metadata, salt, mode, rewardToken, minHold, msg.value - creationFeeWei, minTokensOut);
    }

    function _createToken(
        string memory name,
        string memory symbol,
        LaunchTokenV2.Metadata memory metadata,
        bytes32 salt,
        LaunchTokenV2.Mode mode,
        address rewardToken,
        uint256 minHold,
        uint256 devBuyWei,
        uint256 minTokensOut
    ) internal returns (address token) {
        if (msg.value < creationFeeWei) revert InsufficientCreationFee();
        _validateMetadataString(name);
        _validateMetadataString(symbol);
        _validateMetadataString(metadata.logoURI);
        _validateMetadataString(metadata.website);
        _validateMetadataString(metadata.telegram);
        _validateMetadataString(metadata.discord);
        _validateMetadataString(metadata.twitter);

        // Reward mode needs an existing, initialized reward/WETH pool.
        address rewardPool;
        if (mode == LaunchTokenV2.Mode.Reward) {
            if (rewardToken == address(0) || rewardToken == weth) revert InvalidRewardToken();
            rewardPool = _findRewardPool(rewardToken);
        } else {
            rewardToken = address(0);
        }

        token = deployer.deploy(
            TokenDeployerV2.Params({
                name: name,
                symbol: symbol,
                supply: tokenTotalSupply,
                platformWebsite: officialWebsite,
                metadata: metadata,
                maxBuyBps: maxBuyBps,
                maxBuyBlocks: maxBuyBlocks,
                mode: mode,
                rewardToken: rewardToken,
                rewardPool: rewardPool,
                minHoldForRewards: minHold
            }),
            keccak256(abi.encode(msg.sender, salt))
        );

        LaunchTokenV2 t = LaunchTokenV2(token);
        _wirePlumbing(t, address(positionManager));
        _wirePlumbing(t, address(locker));
        _wirePlumbing(t, distributor);

        bool tokenIsToken0 = token < weth;
        uint160 targetSqrtPriceX96 = _sqrtPriceX96For(initialPriceWethPerToken, tokenIsToken0);

        address pool = factory.getPool(token, weth, feeTier);
        if (pool == address(0)) pool = factory.createPool(token, weth, feeTier);
        _wirePlumbing(t, pool);
        t.setPool(pool);

        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (currentSqrtPriceX96 == 0) {
            IUniswapV3Pool(pool).initialize(targetSqrtPriceX96);
        } else {
            bool safe =
                tokenIsToken0 ? currentSqrtPriceX96 <= targetSqrtPriceX96 : currentSqrtPriceX96 >= targetSqrtPriceX96;
            if (!safe) revert PoolPriceUnsafe();
        }

        (int24 tickLower, int24 tickUpper) = tokenIsToken0 ? (tickLower0, tickUpper0) : (-tickUpper0, -tickLower0);
        IERC20(token).forceApprove(address(positionManager), tokenTotalSupply);
        (uint256 positionTokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIsToken0 ? token : weth,
                token1: tokenIsToken0 ? weth : token,
                fee: feeTier,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: tokenIsToken0 ? tokenTotalSupply : 0,
                amount1Desired: tokenIsToken0 ? 0 : tokenTotalSupply,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );

        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) t.burn(dust);

        _launches[token] = LaunchInfo({
            pool: pool,
            creator: msg.sender,
            tokenIsToken0: tokenIsToken0,
            graduated: false,
            positionTokenId: positionTokenId,
            graduationWethAmount: defaultGraduationWethAmount
        });
        locker.register(token, positionTokenId, tokenIsToken0);

        emit TokenLaunchedV2(
            token, msg.sender, pool, positionTokenId, tokenIsToken0, uint8(mode), rewardToken, name, symbol, metadata
        );

        uint256 fee = creationFeeWei;
        if (fee > 0) {
            (bool okFee,) = locker.treasury().call{value: fee}("");
            if (!okFee) revert CreationFeeTransferFailed();
            emit CreationFeePaid(msg.sender, token, fee);
        }
        if (devBuyWei > 0) _devBuy(token, pool, tokenIsToken0, devBuyWei, minTokensOut);
        uint256 refund = msg.value - fee - devBuyWei;
        if (refund > 0) {
            (bool okRefund,) = msg.sender.call{value: refund}("");
            if (!okRefund) revert CreationFeeTransferFailed();
        }
    }

    /// @dev Exempt plumbing from the launch guard AND exclude it from dividends.
    function _wirePlumbing(LaunchTokenV2 t, address account) internal {
        t.setLimitExempt(account, true);
        t.excludeFromDividends(account, true);
    }

    /// @dev First existing, initialized reward/WETH pool across standard tiers.
    function _findRewardPool(address rewardToken) internal view returns (address) {
        uint24[4] memory tiers = [uint24(10_000), 3_000, 500, 100];
        for (uint256 i = 0; i < tiers.length; i++) {
            address p = factory.getPool(rewardToken, weth, tiers[i]);
            if (p != address(0)) {
                (uint160 sp,,,,,,) = IUniswapV3Pool(p).slot0();
                if (sp != 0) return p;
            }
        }
        revert RewardPoolNotFound();
    }

    function _devBuy(address token, address pool, bool tokenIsToken0, uint256 wethIn, uint256 minTokensOut) internal {
        IWETH(weth).deposit{value: wethIn}();
        bool zeroForOne = !tokenIsToken0;
        (int256 amount0, int256 amount1) =
            IUniswapV3Pool(pool).swap(msg.sender, zeroForOne, int256(wethIn), zeroForOne ? MIN_SQRT : MAX_SQRT, abi.encode(token));
        uint256 tokensOut = uint256(-(tokenIsToken0 ? amount0 : amount1));
        if (tokensOut < minTokensOut) revert DevBuyTooLittle();
        emit DevBought(token, msg.sender, wethIn, tokensOut);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        address token = abi.decode(data, (address));
        if (msg.sender != factory.getPool(token, weth, feeTier)) revert OnlyPool();
        if (amount0Delta > 0) IERC20(weth).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(weth).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    // ─────────────────────────────── graduation / views ─────────────────────────

    function checkGraduation(address token) external returns (bool) {
        LaunchInfo storage info = _launches[token];
        if (info.creator == address(0)) revert UnknownToken();
        if (info.graduated) revert AlreadyGraduated();
        uint256 wethBonded = IERC20(weth).balanceOf(info.pool);
        if (wethBonded < info.graduationWethAmount) revert NotEnoughWethBonded();
        info.graduated = true;
        emit Graduated(token, info.pool, wethBonded);
        return true;
    }

    function getLaunch(address token) external view returns (LaunchInfo memory) {
        return _launches[token];
    }

    function creatorOf(address token) external view returns (address) {
        return _launches[token].creator;
    }

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

    // ─────────────────────────────────── admin ────────────────────────────────────

    function setOfficialWebsite(string calldata website_) external onlyOwner {
        officialWebsite = website_;
        emit OfficialWebsiteSet(website_);
    }

    function setCreationFee(uint256 weiAmount) external onlyOwner {
        if (weiAmount > MAX_CREATION_FEE_WEI) revert CreationFeeTooHigh();
        creationFeeWei = weiAmount;
        emit CreationFeeSet(weiAmount);
    }

    function setGraduationWethAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidPoolConfig();
        defaultGraduationWethAmount = amount;
        emit GraduationWethAmountSet(amount);
    }

    // ────────────────────────────────── internals ─────────────────────────────────

    function _validateMetadataString(string memory s) internal pure {
        bytes memory b = bytes(s);
        if (b.length > 256) revert InvalidMetadata();
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            if (ch < 0x20 || ch == 0x22 || ch == 0x5C) revert InvalidMetadata();
        }
    }

    function _sqrtPriceX96For(uint256 priceWethPerToken, bool tokenIsToken0) internal pure returns (uint160) {
        uint256 ratioX192 = tokenIsToken0
            ? Math.mulDiv(priceWethPerToken, 1 << 192, 1e18)
            : Math.mulDiv(1e18, 1 << 192, priceWethPerToken);
        return uint160(Math.sqrt(ratioX192));
    }
}
