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
    function registerBuyback(address token, address asset, PoolKey calldata key) external;
    function registerBuybackV3(address token, address asset, uint24 fee) external;
    function setPayoutThreshold(address token, uint256 amount) external;
    function setPayoutInterval(address token, uint256 intervalBlocks) external;
    function setJackpotChance(address token, uint16 chanceBps) external;
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
    // Anti-snipe launch guard applied to each new token: a `maxBuyBps` wallet cap for
    // the first `maxBuyBlocks` L1 blocks. Owner-settable so the window can be tuned
    // without redeploying (affects tokens created after the change).
    uint16 public maxBuyBps;
    uint32 public maxBuyBlocks;

    string public officialWebsite;
    uint256 public creationFeeWei = 0.000005 ether;
    uint256 public constant MAX_CREATION_FEE_WEI = 0.001 ether;
    uint8 public constant MAX_REWARDS = 5; // parallel reward assets (matches LaunchTokenV2)

    struct Launch {
        address creator;
        PoolKey key;
        uint24 fee;
        bool exists;
    }

    mapping(address token => Launch) internal _launches;

    /// @notice One reward asset + its fee weight + its buyback venue (Reward mode).
    struct RewardVenue {
        address token; // the reward asset holders earn
        uint16 weightBps; // this asset's share of the fee (weights sum to 10000)
        bool isV3; // venue: a Uniswap V3 pool (else V4)
        uint24 v3Fee; // V3: the pool fee tier (e.g. 10000)
        PoolKey v4Key; // V4: the pool to buy the asset on
    }

    struct CreateParams {
        string name;
        string symbol;
        LaunchTokenV2.Metadata metadata;
        bytes32 salt;
        LaunchTokenV2.Mode mode; // Reward / Increasing (Redistribute) / Lottery
        uint24 fee; // 30000 / 50000 / 100000
        // Reward mode: 1..5 reward assets, each with a fee weight (sum 10000) + venue.
        RewardVenue[] rewards;
        // Lottery mode: an optional prize token (0 = WETH pot) + its buyback venue.
        address prizeToken;
        bool prizeIsV3;
        uint24 prizeV3Fee;
        PoolKey prizePoolKey;
        uint256 minHold; // min balance to earn rewards
        uint256 payoutThreshold; // min pending WETH before a payout fires
        // Block-based timer (L1 blocks, ~12s): min blocks between payouts/draws.
        // Reward/Lottery set this; Redistribute leaves it 0 ("insta").
        uint256 payoutIntervalBlocks;
        // Lottery only: per-draw chance (bps, 1..10000) the jackpot is won. On a miss the
        // pot rolls over and grows; on a hit the winner takes the whole pot. Ignored by
        // other modes. 200 = 1-in-50 default.
        uint16 jackpotChanceBps;
    }

    event TokenLaunchedV4(
        address indexed token, address indexed creator, uint24 fee, uint8 mode, address rewardToken, string name, string symbol
    );
    event CreationFeePaid(address indexed creator, address indexed token, uint256 fee);
    event OfficialWebsiteSet(string website);
    event CreationFeeSet(uint256 weiAmount);
    event AntiSnipeSet(uint16 maxBuyBps, uint32 maxBuyBlocks);

    error ZeroAddress();
    error InvalidFee();
    error InvalidMode();
    error InvalidRewardToken();
    error InvalidRewardPool();
    error BadRewardConfig(); // wrong reward count / weights don't sum to 10000 / duplicate asset
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

        // Build the token's reward-asset config from the mode:
        //  • Reward     — 1..MAX_REWARDS dev-chosen assets, each with a fee weight
        //                 (weights sum to 10000) + a buyback venue. Distributed in parallel.
        //  • Lottery    — an optional single prize token (0 => the pot stays WETH).
        //  • Redistribute — no external asset (buys back the token's own pool).
        address[] memory rewardTokens;
        uint16[] memory rewardWeights;
        address prizeToken;

        if (p.mode == LaunchTokenV2.Mode.Reward) {
            uint256 n = p.rewards.length;
            if (n == 0 || n > MAX_REWARDS) revert BadRewardConfig();
            rewardTokens = new address[](n);
            rewardWeights = new uint16[](n);
            uint256 weightSum;
            for (uint256 i; i < n; i++) {
                RewardVenue calldata rv = p.rewards[i];
                address a = rv.token;
                if (a == address(0) || a == weth) revert InvalidRewardToken();
                // Reject duplicate assets — the token registers one dividend bucket per
                // asset, and a repeat would double-register its venue / split weight twice.
                for (uint256 j; j < i; j++) {
                    if (rewardTokens[j] == a) revert BadRewardConfig();
                }
                if (rv.weightBps == 0) revert BadRewardConfig();
                _validateVenue(a, rv.isV3, rv.v3Fee, rv.v4Key);
                rewardTokens[i] = a;
                rewardWeights[i] = rv.weightBps;
                weightSum += rv.weightBps;
            }
            if (weightSum != 10_000) revert BadRewardConfig();
        } else if (p.mode == LaunchTokenV2.Mode.Lottery && p.prizeToken != address(0)) {
            if (p.prizeToken == weth) revert InvalidRewardToken();
            _validateVenue(p.prizeToken, p.prizeIsV3, p.prizeV3Fee, p.prizePoolKey);
            prizeToken = p.prizeToken;
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
                rewardTokens: rewardTokens,
                rewardWeights: rewardWeights,
                prizeToken: prizeToken,
                minHoldForRewards: p.minHold
            }),
            keccak256(abi.encode(msg.sender, p.salt))
        );

        _launchOnV4(token, p, prizeToken);

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

        // Representative reward asset for the event/indexer: the first reward token
        // (Reward), the prize token (Lottery), or 0 (Redistribute). The full reward
        // set is readable on-chain via LaunchTokenV2.rewardTokensList().
        address primaryReward = rewardTokens.length > 0 ? rewardTokens[0] : prizeToken;
        emit TokenLaunchedV4(token, msg.sender, p.fee, uint8(p.mode), primaryReward, p.name, p.symbol);
    }

    /// @dev Initialize the V4 pool, lock the single-sided supply, and wire the
    /// locker + distributor. Split out to keep the stack manageable.
    function _launchOnV4(address token, CreateParams calldata p, address prizeToken) internal {
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
            // Lottery: holdings-weighted. The token checkpoints every holder's balance,
            // and the distributor snapshots holdings at each draw's commit block to pick
            // a weighted-random winner. The pot is WETH; if the dev picked a prize token,
            // register its V3/V4 venue so the pot can be swapped to it.
            t.setLotteryOperator(distributor);
            // Powerball-style: a hard, per-draw chance the jackpot is won; on a miss the pot
            // rolls over and grows. Default to 1-in-50 (200 bps) when the dev leaves it 0.
            uint16 chanceBps = p.jackpotChanceBps == 0 ? 200 : p.jackpotChanceBps;
            IDistributorV4Register(distributor).setJackpotChance(token, chanceBps);
            if (prizeToken != address(0)) {
                _registerVenue(token, prizeToken, p.prizeIsV3, p.prizeV3Fee, p.prizePoolKey);
            }
        } else if (p.mode == LaunchTokenV2.Mode.Reward) {
            // Reward: register one buyback venue per reward asset. The distributor
            // splits each fee batch by weight and buys every asset in parallel.
            for (uint256 i; i < p.rewards.length; i++) {
                RewardVenue calldata rv = p.rewards[i];
                _registerVenue(token, rv.token, rv.isV3, rv.v3Fee, rv.v4Key);
            }
        } else {
            // Redistribute buys back the token's own V4 pool (asset == token).
            IDistributorV4Register(distributor).registerBuyback(token, token, key);
        }
        if (p.payoutThreshold > 0) IDistributorV4Register(distributor).setPayoutThreshold(token, p.payoutThreshold);
        if (p.payoutIntervalBlocks > 0) {
            IDistributorV4Register(distributor).setPayoutInterval(token, p.payoutIntervalBlocks);
        }

        _launches[token] = Launch({creator: msg.sender, key: key, fee: p.fee, exists: true});
    }

    /// @dev A reward/prize venue must actually route WETH -> asset, else the
    /// distributor's buyback would be permanently unroutable (V3) or would create
    /// an unsettleable non-WETH debt / route to a rigged pool (V4, audit L-02).
    function _validateVenue(address asset, bool isV3, uint24 v3Fee, PoolKey calldata key) internal view {
        if (isV3) {
            if (v3Factory.getPool(weth, asset, v3Fee) == address(0)) revert InvalidRewardPool();
        } else {
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            if (!((c0 == weth && c1 == asset) || (c0 == asset && c1 == weth))) revert InvalidRewardPool();
        }
    }

    /// @dev Register the distributor's buyback venue for one reward/prize asset:
    /// a Uniswap V3 pool (WETH/asset at v3Fee) or a V4 pool.
    function _registerVenue(address token, address asset, bool isV3, uint24 v3Fee, PoolKey calldata key) internal {
        if (isV3) {
            IDistributorV4Register(distributor).registerBuybackV3(token, asset, v3Fee);
        } else {
            IDistributorV4Register(distributor).registerBuyback(token, asset, key);
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

    /// @notice Tune the anti-snipe launch guard for FUTURE tokens: a `bps` wallet cap
    /// for the first `blocks` L1 blocks after launch (either 0 disables that part).
    function setAntiSnipe(uint16 bps, uint32 blocks) external onlyOwner {
        if (bps > 10_000) revert InvalidFee();
        maxBuyBps = bps;
        maxBuyBlocks = blocks;
        emit AntiSnipeSet(bps, blocks);
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
