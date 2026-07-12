// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — https://hood.launchfair.app
// Mode-token launchpad on Uniswap V4: create a token with a mode + fee tier,
// launch it into a V4 pool as a single-sided locked position, and wire the fee
// locker + reward distributor. Base tokens stay on V1/V3 — V4 is for the mode
// tokens (Reward / Redistribute / Lottery).

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {LaunchTokenV2} from "../LaunchTokenV2.sol";
import {TokenDeployerV2} from "../TokenDeployerV2.sol";
import {LaunchFairV4FeeLocker} from "./LaunchFairV4FeeLocker.sol";
import {LiquidityMath} from "./LiquidityMath.sol";
import {IUniswapV3Factory} from "../../interfaces/IUniswapV3.sol";

interface IDistributorV4Register {
    function registerBuyback(address token, PoolKey calldata key) external;
    function registerBuybackV3(address token, uint24 fee) external;
    function setPayoutThreshold(address token, uint256 amount) external;
    function setPayoutInterval(address token, uint256 intervalBlocks) external;
}

contract LaunchFairV4 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IUniswapV3Factory public immutable v3Factory; // validates V3 reward pools exist
    LaunchFairV4FeeLocker public immutable locker;
    address public immutable distributor;
    TokenDeployerV2 public immutable deployer;
    address public immutable weth;

    uint128 public immutable tokenTotalSupply;
    uint256 public immutable initialPriceWethPerToken;
    int24 public immutable tickSpacing;
    int24 public immutable tickLower0; // single-sided range when token == currency0
    int24 public immutable tickUpper0;
    uint16 public immutable maxBuyBps;
    uint32 public immutable maxBuyBlocks;

    string public officialWebsite;
    uint256 public creationFeeWei = 0.000005 ether;
    uint256 public constant MAX_CREATION_FEE_WEI = 0.001 ether;

    struct Launch {
        address creator;
        PoolKey key;
        uint24 fee;
        bool exists;
    }

    mapping(address token => Launch) internal _launches;

    struct CreateParams {
        string name;
        string symbol;
        LaunchTokenV2.Metadata metadata;
        bytes32 salt;
        LaunchTokenV2.Mode mode; // Reward / Increasing (Redistribute) / Lottery
        uint24 fee; // 30000 / 50000 / 100000
        // The reward asset: required for Reward mode, optional for Lottery (the
        // prize token — 0 pays the pot in WETH). Ignored for Redistribute.
        address rewardToken;
        // Where that asset is bought. `rewardIsV3` picks the venue — a Uniswap V3
        // pool (WETH/asset at `rewardV3Fee`) or a V4 pool (`rewardPoolKey`). Most
        // established tokens on this chain are V3.
        bool rewardIsV3;
        uint24 rewardV3Fee; // V3: the pool fee tier
        PoolKey rewardPoolKey; // V4: the pool to buy the asset on
        uint256 minHold; // min balance to earn rewards
        uint256 payoutThreshold; // min pending WETH before a payout fires
        // Block-based timer (L1 blocks, ~12s): min blocks between payouts/draws.
        // Reward/Lottery set this; Redistribute leaves it 0 ("insta").
        uint256 payoutIntervalBlocks;
    }

    event TokenLaunchedV4(
        address indexed token, address indexed creator, uint24 fee, uint8 mode, address rewardToken, string name, string symbol
    );
    event CreationFeePaid(address indexed creator, address indexed token, uint256 fee);
    event OfficialWebsiteSet(string website);
    event CreationFeeSet(uint256 weiAmount);

    error ZeroAddress();
    error InvalidFee();
    error InvalidMode();
    error InvalidRewardToken();
    error InvalidRewardPool();
    error InvalidMetadata();
    error InsufficientCreationFee();
    error CreationFeeTransferFailed();
    error UnknownToken();

    constructor(
        address owner_,
        IPoolManager pm_,
        IUniswapV3Factory v3Factory_,
        LaunchFairV4FeeLocker locker_,
        address distributor_,
        TokenDeployerV2 deployer_,
        address weth_,
        uint128 supply_,
        uint256 initialPrice_,
        int24 tickSpacing_,
        int24 tickLower0_,
        int24 tickUpper0_,
        uint16 maxBuyBps_,
        uint32 maxBuyBlocks_,
        string memory website_
    ) Ownable(owner_) {
        if (
            address(pm_) == address(0) || address(v3Factory_) == address(0) || address(locker_) == address(0)
                || distributor_ == address(0) || address(deployer_) == address(0) || weth_ == address(0)
        ) revert ZeroAddress();
        poolManager = pm_;
        v3Factory = v3Factory_;
        locker = locker_;
        distributor = distributor_;
        deployer = deployer_;
        weth = weth_;
        tokenTotalSupply = supply_;
        initialPriceWethPerToken = initialPrice_;
        tickSpacing = tickSpacing_;
        tickLower0 = tickLower0_;
        tickUpper0 = tickUpper0_;
        maxBuyBps = maxBuyBps_;
        maxBuyBlocks = maxBuyBlocks_;
        officialWebsite = website_;
    }

    function createToken(CreateParams calldata p) external payable nonReentrant returns (address token) {
        if (msg.value < creationFeeWei) revert InsufficientCreationFee();
        if (!(p.fee == 30_000 || p.fee == 50_000 || p.fee == 100_000)) revert InvalidFee();
        if (p.mode == LaunchTokenV2.Mode.Base) revert InvalidMode(); // Base stays on V1/V3
        _validate(p.name);
        _validate(p.symbol);
        _validate(p.metadata.logoURI);
        _validate(p.metadata.website);
        _validate(p.metadata.telegram);
        _validate(p.metadata.discord);
        _validate(p.metadata.twitter);

        // Reward always distributes an external token; Lottery may optionally pay
        // its pot in one (else the pot is paid in WETH). Validate whichever is set.
        address rewardToken;
        if (p.mode == LaunchTokenV2.Mode.Reward) {
            if (p.rewardToken == address(0) || p.rewardToken == weth) revert InvalidRewardToken();
            rewardToken = p.rewardToken;
        } else if (p.mode == LaunchTokenV2.Mode.Lottery && p.rewardToken != address(0)) {
            if (p.rewardToken == weth) revert InvalidRewardToken();
            rewardToken = p.rewardToken;
        }
        // For a V3 reward/prize, the WETH/asset pool at the chosen fee must exist —
        // otherwise the buyback would be permanently unroutable.
        if (rewardToken != address(0) && p.rewardIsV3 && v3Factory.getPool(weth, rewardToken, p.rewardV3Fee) == address(0))
        {
            revert InvalidRewardPool();
        }

        token = deployer.deploy(
            TokenDeployerV2.Params({
                name: p.name,
                symbol: p.symbol,
                supply: tokenTotalSupply,
                platformWebsite: officialWebsite,
                metadata: p.metadata,
                maxBuyBps: maxBuyBps,
                maxBuyBlocks: maxBuyBlocks,
                mode: p.mode,
                rewardToken: rewardToken,
                rewardPool: address(0), // V4 uses the distributor's registered PoolKey
                minHoldForRewards: p.minHold
            }),
            keccak256(abi.encode(msg.sender, p.salt))
        );

        _launchOnV4(token, p, rewardToken);

        // Creation fee -> treasury; refund the rest.
        uint256 fee = creationFeeWei;
        if (fee > 0) {
            (bool ok,) = locker.treasury().call{value: fee}("");
            if (!ok) revert CreationFeeTransferFailed();
            emit CreationFeePaid(msg.sender, token, fee);
        }
        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool okR,) = msg.sender.call{value: refund}("");
            if (!okR) revert CreationFeeTransferFailed();
        }

        emit TokenLaunchedV4(token, msg.sender, p.fee, uint8(p.mode), rewardToken, p.name, p.symbol);
    }

    /// @dev Initialize the V4 pool, lock the single-sided supply, and wire the
    /// locker + distributor. Split out to keep the stack manageable.
    function _launchOnV4(address token, CreateParams calldata p, address rewardToken) internal {
        LaunchTokenV2 t = LaunchTokenV2(token);
        bool tokenIsCurrency0 = token < weth;
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(token), Currency.wrap(weth))
            : (Currency.wrap(weth), Currency.wrap(token));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: p.fee, tickSpacing: tickSpacing, hooks: IHooks(address(0))});

        poolManager.initialize(key, _sqrtPriceX96For(initialPriceWethPerToken, tokenIsCurrency0));

        (int24 tl, int24 tu) = tokenIsCurrency0 ? (tickLower0, tickUpper0) : (-tickUpper0, -tickLower0);
        uint128 liquidity = tokenIsCurrency0
            ? LiquidityMath.getLiquidityForAmount0(TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), tokenTotalSupply)
            : LiquidityMath.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), tokenTotalSupply);

        // Plumbing: exclude from dividends + exempt from the launch guard.
        t.excludeFromDividends(address(poolManager), true);
        t.excludeFromDividends(address(locker), true);
        t.excludeFromDividends(distributor, true);
        t.setLimitExempt(address(poolManager), true);
        t.setLimitExempt(address(locker), true);

        // Hand the supply to the locker and lock it single-sided forever.
        IERC20(token).safeTransfer(address(locker), tokenTotalSupply);
        locker.lockLiquidity(token, key, tl, tu, liquidity, tokenIsCurrency0);

        if (p.mode == LaunchTokenV2.Mode.Lottery) {
            // Lottery: a buy is the pool handing tokens to the buyer, so tickets
            // accrue on transfers from the PoolManager; the distributor runs the
            // draw and advances each session. The pot is WETH; if the dev picked a
            // prize token, register its V3/V4 venue so the pot can be swapped to it.
            t.setBuySource(address(poolManager));
            t.setLotteryOperator(distributor);
            if (rewardToken != address(0)) _registerRewardVenue(token, p);
        } else if (p.mode == LaunchTokenV2.Mode.Reward) {
            // Reward: buy the dev's reward token on its V3 or V4 pool.
            _registerRewardVenue(token, p);
        } else {
            // Redistribute buys back the token's own V4 pool.
            IDistributorV4Register(distributor).registerBuyback(token, key);
        }
        if (p.payoutThreshold > 0) IDistributorV4Register(distributor).setPayoutThreshold(token, p.payoutThreshold);
        if (p.payoutIntervalBlocks > 0) {
            IDistributorV4Register(distributor).setPayoutInterval(token, p.payoutIntervalBlocks);
        }

        _launches[token] = Launch({creator: msg.sender, key: key, fee: p.fee, exists: true});
    }

    /// @dev Register the distributor's buyback venue for a token's reward/prize
    /// asset: a Uniswap V3 pool (WETH/asset at rewardV3Fee) or a V4 pool.
    function _registerRewardVenue(address token, CreateParams calldata p) internal {
        if (p.rewardIsV3) {
            IDistributorV4Register(distributor).registerBuybackV3(token, p.rewardV3Fee);
        } else {
            IDistributorV4Register(distributor).registerBuyback(token, p.rewardPoolKey);
        }
    }

    // ── views ────────────────────────────────────────────────────────────────
    function creatorOf(address token) external view returns (address) {
        return _launches[token].creator;
    }

    function getLaunch(address token) external view returns (Launch memory) {
        return _launches[token];
    }

    // ── admin ──────────────────────────────────────────────────────────────────
    function setOfficialWebsite(string calldata website_) external onlyOwner {
        officialWebsite = website_;
        emit OfficialWebsiteSet(website_);
    }

    function setCreationFee(uint256 weiAmount) external onlyOwner {
        if (weiAmount > MAX_CREATION_FEE_WEI) revert InsufficientCreationFee();
        creationFeeWei = weiAmount;
        emit CreationFeeSet(weiAmount);
    }

    // ── internals ──────────────────────────────────────────────────────────────
    function _validate(string memory s) internal pure {
        bytes memory b = bytes(s);
        if (b.length > 256) revert InvalidMetadata();
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            if (ch < 0x20 || ch == 0x22 || ch == 0x5C) revert InvalidMetadata();
        }
    }

    function _sqrtPriceX96For(uint256 priceWethPerToken, bool tokenIsCurrency0) internal pure returns (uint160) {
        uint256 ratioX192 = tokenIsCurrency0
            ? Math.mulDiv(priceWethPerToken, 1 << 192, 1e18)
            : Math.mulDiv(1e18, 1 << 192, priceWethPerToken);
        return uint160(Math.sqrt(ratioX192));
    }
}
