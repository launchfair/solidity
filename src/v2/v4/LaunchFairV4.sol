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
import {IPerpsVenue} from "./IPerpsVenue.sol";

interface IDistributorV4Register {
    function registerBuyback(address token, address asset, PoolKey calldata key) external;
    function registerBuybackV3(address token, address asset, uint24 fee) external;
    function registerPerps(address token, address venue) external;
    function setPayoutThreshold(address token, uint256 amount) external;
    function setPayoutInterval(address token, uint256 intervalBlocks) external;
    function setLotteryOdds(address token, uint16 missBps, uint16 jackpotBps, uint16 regularShareBps) external;
}

/// LaunchFairV4SwapRouter.buy — used by createAndBuy for an atomic, front-run-proof dev buy.
interface ILaunchFairV4SwapRouter {
    function buy(PoolKey calldata key, uint256 minOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out);
}

/// StockPairRouter.buy — used by createStockAndBuy for an atomic dev buy on a stock-paired token.
interface IStockPairRouter {
    function buy(address token, uint256 minOut, address to, uint256 deadline)
        external
        payable
        returns (uint256 out);
}

/// RouterGateHook.router — the router a gate hook is (immutably) bound to; used to verify the
/// stock router and gate hook are a matched pair before wiring.
interface IRouterGate {
    function router() external view returns (address);
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
    // the first `maxBuySecs` SECONDS after launch (time-based — exact regardless of the
    // chain's block cadence). Owner-settable so the window can be tuned
    // without redeploying (affects tokens created after the change).
    uint16 public maxBuyBps;
    uint32 public maxBuySecs;

    string public officialWebsite;
    uint256 public creationFeeWei = 0.000005 ether;
    /// @notice Optional WETH fee hook. When set (a properly-mined hook address), NEW pools launch
    /// with this hook and a 0 LP fee — the hook charges the fee in WETH on both buys and sells (no
    /// sell pressure). Unset (0) => today's model (no hook, pool LP fee, locker-collected).
    address public feeHook;
    event FeeHookSet(address feeHook);
    /// @notice The stock-perp venue for Mode.Perps tokens (resolves each leg's position token at
    /// launch). Must match the distributor's `perpsVenue`. Owner-settable; 0 => Perps launches revert.
    address public perpsVenue;
    event PerpsVenueSet(address perpsVenue);
    /// @notice Mode-enforced ceiling on a Perps leg's leverage (bps). 50000 = 5x.
    uint16 public constant MAX_LEVERAGE_BPS = 50_000;
    uint256 public constant MAX_CREATION_FEE_WEI = 0.001 ether;
    uint8 public constant MAX_REWARDS = 5; // parallel reward assets (matches LaunchTokenV2)
    /// @notice The V4 swap router used by createAndBuy for the atomic dev buy. Set once by
    /// the owner at deploy (kept off the constructor to avoid a 16-arg signature).
    address public swapRouter;

    // ── Stock-paired launches (additive; existing WETH-paired flow is untouched) ──
    // A new token type whose pool is TOKEN/<stock> (e.g. TOKEN/AAPL) instead of TOKEN/WETH. Users
    // still buy/sell with native ETH via the StockPairRouter (ETH↔WETH↔stock↔TOKEN); the pool is a
    // 0-fee, RouterGateHook-gated pool and the WETH fee is charged at the router, so dev-fee logic is
    // unchanged. v1: stock tokens launch as Base mode only.
    /// @notice The 2-hop router that trades stock-paired tokens with native ETH.
    address public stockPairRouter;
    /// @notice The gate hook attached to every stock pool (reverts non-router swaps).
    address public stockGateHook;
    /// @notice Owner-approved quote (stock) tokens a launch may pair against.
    mapping(address stock => bool) public allowedQuote;
    /// @notice The Uniswap-V3 fee tier of each allowed quote's <stock>/WETH pool (for the router hop).
    mapping(address stock => uint24) public quoteV3Fee;
    /// @notice Per-quote LAUNCH PRICE for stock-paired tokens, in quote-wei per whole token
    /// (0 ⇒ fall back to `initialPriceWethPerToken`). The global default is calibrated for a
    /// WETH quote — reused verbatim it prices a launch at "1.49 units of quote" (~$6k for WETH
    /// but only ~$270 when the quote is NVDA), so each stock gets its own knob targeting a sane
    /// USD launch mcap. Owner-tunable any time; applies to NEW launches only.
    mapping(address stock => uint256) public quoteInitialPrice;
    event QuoteInitialPriceSet(address indexed stock, uint256 quoteWeiPerToken);

    /// @notice Set a quote's launch price (quote-wei per whole token; 0 restores the default).
    function setAllowedQuotePrice(address stock, uint256 quoteWeiPerToken) external onlyOwner {
        quoteInitialPrice[stock] = quoteWeiPerToken;
        emit QuoteInitialPriceSet(stock, quoteWeiPerToken);
    }
    event StockPairRouterSet(address router);
    event StockGateHookSet(address hook);
    event AllowedQuoteSet(address indexed stock, bool allowed, uint24 v3Fee);
    event StockTokenLaunched(
        address indexed token, address indexed creator, address indexed quoteToken, string name, string symbol
    );

    struct Launch {
        address creator;
        PoolKey key;
        uint24 fee;
        address quoteToken; // 0 for WETH-paired; the stock token for stock-paired launches
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

    /// @notice One leveraged stock-perp leg (Mode.Perps). Resolves to a venue position token that
    /// holders receive as a reward; the dev picks market/side/leverage + this leg's fee weight.
    struct PerpLeg {
        bytes32 market; // venue stock market id (e.g. keccak256("AAPL"))
        bool isLong; // long or short
        uint16 leverageBps; // e.g. 30000 = 3x, capped by MAX_LEVERAGE_BPS
        uint16 weightBps; // this leg's share of the fee (Σ over legs == 10000)
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
        // Perps mode: 1..5 leveraged stock legs (Σ weight == 10000). Each resolves to a venue
        // position token that holders receive + can hold/sell/redeem.
        PerpLeg[] perps;
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
        // Lottery only (ignored by other modes): the three-outcome odds. Each draw rolls
        // 0.00–99.99; roll < missBps = MISS (pot rolls over), roll ≥ 100-jackpot = JACKPOT
        // (winner takes pot + jackpot pool), else REGULAR (winner takes regularWinShareBps of
        // the pot, the rest skims to the jackpot pool). 0s → launchpad defaults 1000/200/7000
        // (10% miss, 2% jackpot, 88% regular @ 70/30).
        uint16 missBps;
        uint16 jackpotChanceBps;
        uint16 regularWinShareBps;
    }

    event TokenLaunchedV4(
        address indexed token, address indexed creator, uint24 fee, uint8 mode, address rewardToken, string name, string symbol
    );
    event CreationFeePaid(address indexed creator, address indexed token, uint256 fee);
    event OfficialWebsiteSet(string website);
    event CreationFeeSet(uint256 weiAmount);
    event AntiSnipeSet(uint16 maxBuyBps, uint32 maxBuySecs);
    event SwapRouterSet(address router);

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
    error SwapRouterNotSet();
    error AlreadySet();
    error QuoteNotAllowed();
    error StockNotConfigured();

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
        uint32 maxBuySecs_,
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
        maxBuySecs = maxBuySecs_;
        officialWebsite = website_;
    }

    function createToken(CreateParams calldata p) external payable nonReentrant returns (address token) {
        if (msg.value < creationFeeWei) revert InsufficientCreationFee();
        token = _create(p);
        _payCreationFee(token);
        uint256 refund = msg.value - creationFeeWei; // no dev buy → refund any excess
        if (refund > 0) {
            (bool okR,) = msg.sender.call{value: refund}("");
            if (!okR) revert CreationFeeTransferFailed();
        }
    }

    /// @notice Create a mode token AND buy some in the SAME transaction — an atomic, front-run-proof
    /// dev buy. `msg.value` = creationFeeWei + the buy amount; the bought tokens go straight to the
    /// creator, respecting the launch-window wallet cap. If the buy would breach the cap (or otherwise
    /// fails), the token is still created and the buy amount is refunded. `minTokensOut` guards the swap.
    function createAndBuy(CreateParams calldata p, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (msg.value < creationFeeWei) revert InsufficientCreationFee();
        if (swapRouter == address(0)) revert SwapRouterNotSet();
        token = _create(p);
        _payCreationFee(token);
        uint256 buyAmount = msg.value - creationFeeWei;
        if (buyAmount > 0) {
            try ILaunchFairV4SwapRouter(swapRouter).buy{value: buyAmount}(
                _launches[token].key, minTokensOut, msg.sender, block.timestamp
            ) {
                // A partial fill refunds unspent ETH to us (the caller) — forward any leftover on.
                uint256 leftover = address(this).balance;
                if (leftover > 0) {
                    (bool okL,) = msg.sender.call{value: leftover}("");
                    if (!okL) revert CreationFeeTransferFailed();
                }
            } catch {
                // Buy failed (e.g. exceeds the launch cap) — the token is live; refund the buy.
                (bool okB,) = msg.sender.call{value: buyAmount}("");
                if (!okB) revert CreationFeeTransferFailed();
            }
        }
    }

    /// @notice Create a **stock-paired** token: its pool is TOKEN/`quoteToken` (an allowed stock),
    /// traded with native ETH via the StockPairRouter. v1: `p.mode` must be Base.
    function createStockToken(CreateParams calldata p, address quoteToken)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (msg.value < creationFeeWei) revert InsufficientCreationFee();
        token = _createStock(p, quoteToken);
        _payCreationFee(token);
        uint256 refund = msg.value - creationFeeWei; // no dev buy → refund any excess
        if (refund > 0) {
            (bool okR,) = msg.sender.call{value: refund}("");
            if (!okR) revert CreationFeeTransferFailed();
        }
    }

    /// @notice Create a stock-paired token AND buy some in the same tx (atomic dev buy, routed
    /// through the StockPairRouter). Same refund-on-failure semantics as `createAndBuy`.
    function createStockAndBuy(CreateParams calldata p, address quoteToken, uint256 minOut)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (msg.value < creationFeeWei) revert InsufficientCreationFee();
        if (stockPairRouter == address(0)) revert StockNotConfigured();
        token = _createStock(p, quoteToken);
        _payCreationFee(token);
        uint256 buyAmount = msg.value - creationFeeWei;
        if (buyAmount > 0) {
            try IStockPairRouter(stockPairRouter).buy{value: buyAmount}(token, minOut, msg.sender, block.timestamp) {
                uint256 leftover = address(this).balance;
                if (leftover > 0) {
                    (bool okL,) = msg.sender.call{value: leftover}("");
                    if (!okL) revert CreationFeeTransferFailed();
                }
            } catch {
                (bool okB,) = msg.sender.call{value: buyAmount}("");
                if (!okB) revert CreationFeeTransferFailed();
            }
        }
    }

    /// @dev Pay the creation fee to the treasury.
    function _payCreationFee(address token) internal {
        uint256 fee = creationFeeWei;
        if (fee > 0) {
            (bool ok,) = locker.treasury().call{value: fee}("");
            if (!ok) revert CreationFeeTransferFailed();
            emit CreationFeePaid(msg.sender, token, fee);
        }
    }

    /// @dev Core creation: validate, deploy, launch on V4, emit. No `msg.value` handling — the
    /// public wrappers (createToken / createAndBuy) pay the fee and refund or dev-buy the rest.
    function _create(CreateParams calldata p) internal returns (address token) {
        if (!(p.fee == 30_000 || p.fee == 50_000 || p.fee == 100_000)) revert InvalidFee();
        // Base/plain tokens are allowed on V4 ONLY with the WETH fee hook set — the hook routes a
        // plain token's "mechanism" fee slice to the flagship (it has no reward/lottery of its own).
        // Without the hook their mechanism slice would strand in the distributor, so require it.
        if (p.mode == LaunchTokenV2.Mode.Base && feeHook == address(0)) revert InvalidMode();
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

        if (p.mode == LaunchTokenV2.Mode.Perps) {
            // Perps: 1..5 leveraged stock legs. Each resolves to the venue's fungible position token,
            // which is registered as a reward asset and distributed exactly like a Reward token.
            if (perpsVenue == address(0)) revert InvalidMode();
            uint256 n = p.perps.length;
            if (n == 0 || n > MAX_REWARDS) revert BadRewardConfig();
            rewardTokens = new address[](n);
            rewardWeights = new uint16[](n);
            uint256 weightSum;
            for (uint256 i; i < n; i++) {
                PerpLeg calldata leg = p.perps[i];
                if (leg.weightBps == 0 || leg.leverageBps == 0 || leg.leverageBps > MAX_LEVERAGE_BPS) {
                    revert BadRewardConfig();
                }
                address posTok = IPerpsVenue(perpsVenue).positionTokenFor(leg.market, leg.isLong, leg.leverageBps);
                for (uint256 j; j < i; j++) {
                    if (rewardTokens[j] == posTok) revert BadRewardConfig(); // duplicate leg
                }
                rewardTokens[i] = posTok;
                rewardWeights[i] = leg.weightBps;
                weightSum += leg.weightBps;
            }
            if (weightSum != 10_000) revert BadRewardConfig();
        } else {
            (rewardTokens, rewardWeights, prizeToken) = _modeAssets(p);
        }

        token = deployer.deploy(
            TokenDeployerV2.Params({
                name: p.name,
                symbol: p.symbol,
                supply: tokenTotalSupply,
                platformWebsite: officialWebsite,
                metadata: p.metadata,
                maxBuyBps: maxBuyBps,
                maxBuySecs: maxBuySecs,
                mode: p.mode,
                rewardTokens: rewardTokens,
                rewardWeights: rewardWeights,
                prizeToken: prizeToken,
                minHoldForRewards: p.minHold
            }),
            keccak256(abi.encode(msg.sender, p.salt))
        );

        _launchOnV4(token, p, prizeToken);

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
        // When a WETH fee hook is configured, launch with it + a 0 LP fee (the hook IS the fee,
        // charged in WETH both ways). Otherwise the classic LP-fee model (no hook).
        address hook = feeHook;
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: hook != address(0) ? uint24(0) : p.fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

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

        _registerMode(token, key, p, prizeToken);

        _launches[token] = Launch({creator: msg.sender, key: key, fee: p.fee, quoteToken: address(0), exists: true});
    }

    /// @dev Wire a launched token's mode mechanism into the distributor. Shared by the WETH
    /// (`_launchOnV4`) and stock (`_createStock`) paths — `key` is the token's own pool (only
    /// Redistribute uses it, and the stock path never reaches that branch: see `_createStock`).
    function _registerMode(address token, PoolKey memory key, CreateParams calldata p, address prizeToken) internal {
        if (p.mode == LaunchTokenV2.Mode.Lottery) {
            // Lottery: holdings-weighted. The token checkpoints every holder's balance,
            // and the distributor snapshots holdings at each draw's commit block to pick
            // a weighted-random winner. The pot is WETH; if the dev picked a prize token,
            // register its V3/V4 venue so the pot can be swapped to it.
            LaunchTokenV2(token).setLotteryOperator(distributor);
            // Powerball-style three outcomes per draw. Defaults (dev leaves a field 0):
            // 10% miss, 2% jackpot, 88% regular paying the winner 70% (30% skims to jackpot).
            uint16 missB = p.missBps == 0 ? 1000 : p.missBps;
            uint16 jackpotB = p.jackpotChanceBps == 0 ? 200 : p.jackpotChanceBps;
            uint16 shareB = p.regularWinShareBps == 0 ? 7000 : p.regularWinShareBps;
            IDistributorV4Register(distributor).setLotteryOdds(token, missB, jackpotB, shareB);
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
        } else if (p.mode == LaunchTokenV2.Mode.Perps) {
            // Perps: no Uniswap buyback venue — the distributor mints the position tokens via the
            // perp venue in process(). Pin THIS launchpad's venue for the token so its payout-time
            // and launch-time venues can never diverge.
            IDistributorV4Register(distributor).registerPerps(token, perpsVenue);
        } else if (p.mode == LaunchTokenV2.Mode.Increasing) {
            // Redistribute buys back the token's own V4 pool (asset == token).
            IDistributorV4Register(distributor).registerBuyback(token, token, key);
        }
        // Base: no mechanism — nothing to register.
        if (p.payoutThreshold > 0) IDistributorV4Register(distributor).setPayoutThreshold(token, p.payoutThreshold);
        if (p.payoutIntervalBlocks > 0) {
            IDistributorV4Register(distributor).setPayoutInterval(token, p.payoutIntervalBlocks);
        }
    }

    /// @dev Reward/Lottery asset building shared by the WETH (`_create`) and stock
    /// (`_createStock`) paths. Perps stays inline in `_create` (WETH-only mode); Base and
    /// Redistribute have no external assets and fall through with empties.
    function _modeAssets(CreateParams calldata p)
        internal
        returns (address[] memory rewardTokens, uint16[] memory rewardWeights, address prizeToken)
    {
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
    }

    /// @dev Core stock-token creation: validate, deploy the token with its MODE intact, launch it
    /// into a TOKEN/`quoteToken` pool. Kept separate from `_create` so the WETH path is untouched.
    ///
    /// Modes on stock pairs (v2 — was Base-only):
    ///   • Base    — no mechanism; the hook folds its mechanism fee slice to the flagship.
    ///   • Reward  — reward assets buy via THEIR OWN WETH venues, so the mechanism works exactly
    ///               as on WETH pairs once the hook's distribute() forwards the mechanism slice
    ///               (in WETH) to the distributor.
    ///   • Lottery — the pot is WETH (prize venue optional), equally quote-agnostic.
    ///   • Redistribute (Increasing) — REJECTED: its buyback venue is the token's own pool, which
    ///     is stock-quoted here; the distributor can only spend WETH, so the buyback would be
    ///     unroutable. Pair Redistribute tokens with ETH instead.
    ///   • Perps — REJECTED (WETH-only mode, unchanged).
    function _createStock(CreateParams calldata p, address quoteToken) internal returns (address token) {
        if (!allowedQuote[quoteToken]) revert QuoteNotAllowed();
        if (stockPairRouter == address(0) || stockGateHook == address(0)) revert StockNotConfigured();
        if (p.mode == LaunchTokenV2.Mode.Increasing || p.mode == LaunchTokenV2.Mode.Perps) revert InvalidMode();
        _validate(p.name);
        _validate(p.symbol);
        _validate(p.metadata.logoURI);
        _validate(p.metadata.website);
        _validate(p.metadata.telegram);
        _validate(p.metadata.discord);
        _validate(p.metadata.twitter);

        (address[] memory rewardTokens, uint16[] memory rewardWeights, address prizeToken) = _modeAssets(p);
        token = deployer.deploy(
            TokenDeployerV2.Params({
                name: p.name,
                symbol: p.symbol,
                supply: tokenTotalSupply,
                platformWebsite: officialWebsite,
                metadata: p.metadata,
                maxBuyBps: maxBuyBps,
                maxBuySecs: maxBuySecs,
                mode: p.mode,
                rewardTokens: rewardTokens,
                rewardWeights: rewardWeights,
                prizeToken: prizeToken,
                minHoldForRewards: p.minHold
            }),
            keccak256(abi.encode(msg.sender, p.salt))
        );

        _launchStockOnV4(token, quoteToken);
        // Mode mechanism (no-op for Base). The pool key passed is the token's stock pool purely
        // for signature symmetry — the Redistribute branch that would use it is unreachable here.
        _registerMode(token, _launches[token].key, p, prizeToken);
        emit StockTokenLaunched(token, msg.sender, quoteToken, p.name, p.symbol);
    }

    /// @dev Launch a stock-paired token: a TOKEN/`quoteToken` V4 pool at fee 0 with the gate hook,
    /// the full supply locked single-sided. The pool price reuses `initialPriceWethPerToken` as
    /// quote-per-token (both stock and WETH are 18-dp, so the math is identical); the resulting USD
    /// launch mcap tracks the stock's price — a per-quote price knob can be added later if desired.
    function _launchStockOnV4(address token, address quoteToken) internal {
        LaunchTokenV2 t = LaunchTokenV2(token);
        bool tokenIsCurrency0 = token < quoteToken;
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(token), Currency.wrap(quoteToken))
            : (Currency.wrap(quoteToken), Currency.wrap(token));
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 0, // no LP fee — the fee is taken in WETH at the StockPairRouter
            tickSpacing: tickSpacing,
            hooks: IHooks(stockGateHook)
        });

        // Shift the single-sided range by the quote's launch-price knob (the range BOTTOM is the
        // effective launch price), and initialize the pool at the SAME shifted offset. Shifting
        // the init price together with the range (rather than leaving it at the WETH-calibrated
        // default) is what lets the knob go DOWN as well as up — a low-decimals quote like USDG
        // (6-dp) needs a launch price ~9 decimal orders BELOW the 18-dp default, and the init
        // price must follow the range there or the single-sided liquidity math breaks. The
        // init-at-or-past-the-range-edge invariant holds identically in both orientations
        // because init and range move by the same tick delta.
        int24 shift = _quoteTickShift(quoteToken);
        int24 tInit = TickMath.getTickAtSqrtPrice(_sqrtPriceX96For(initialPriceWethPerToken, true)) + shift;
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(tokenIsCurrency0 ? tInit : -tInit));
        (int24 tl, int24 tu) = tokenIsCurrency0
            ? (tickLower0 + shift, tickUpper0 + shift)
            : (-(tickUpper0 + shift), -(tickLower0 + shift));
        uint128 liquidity = tokenIsCurrency0
            ? LiquidityMath.getLiquidityForAmount0(TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), tokenTotalSupply)
            : LiquidityMath.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), tokenTotalSupply);

        // Plumbing: exclude from dividends + exempt from the launch guard. The stock router holds
        // tokens transiently while executing a sell, so it must be limit-exempt too. The
        // distributor is excluded like on WETH pairs — stock tokens can be Reward/Lottery now.
        t.excludeFromDividends(address(poolManager), true);
        t.excludeFromDividends(address(locker), true);
        t.excludeFromDividends(stockPairRouter, true);
        t.excludeFromDividends(distributor, true);
        t.setLimitExempt(address(poolManager), true);
        t.setLimitExempt(address(locker), true);
        t.setLimitExempt(stockPairRouter, true);

        IERC20(token).safeTransfer(address(locker), tokenTotalSupply);
        locker.lockLiquidity(token, key, tl, tu, liquidity, tokenIsCurrency0);

        _launches[token] = Launch({creator: msg.sender, key: key, fee: 0, quoteToken: quoteToken, exists: true});
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

    /// @notice Set the V4 swap router used by createAndBuy (set once, at deploy).
    function setSwapRouter(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        if (swapRouter != address(0)) revert AlreadySet();
        swapRouter = r;
        emit SwapRouterSet(r);
    }

    /// @notice Set the WETH fee hook for FUTURE tokens (a properly-mined hook address). Once set,
    /// new pools launch with this hook and a 0 LP fee. Set to 0 to revert to the LP-fee model.
    function setFeeHook(address hook) external onlyOwner {
        feeHook = hook;
        emit FeeHookSet(hook);
    }

    /// @notice Set the stock-pair router used to trade stock-paired tokens (and by createStockAndBuy).
    /// Set-once: the gate hook baked into every stock pool is immutably bound to this router, so
    /// changing it would orphan (permanently un-trade) all existing stock pools. Migrate by
    /// redeploying the launchpad (immutable-stack model).
    function setStockPairRouter(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        if (stockPairRouter != address(0)) revert AlreadySet();
        stockPairRouter = r;
        emit StockPairRouterSet(r);
    }

    /// @notice Set the gate hook attached to new stock pools (a properly-mined `RouterGateHook`
    /// bound to `stockPairRouter`). Set-once and consistency-checked so hook and router can never be
    /// a mismatched pair (which would brick swaps). Set the router first.
    function setStockGateHook(address hook) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        if (stockGateHook != address(0)) revert AlreadySet();
        if (stockPairRouter == address(0) || IRouterGate(hook).router() != stockPairRouter) revert StockNotConfigured();
        stockGateHook = hook;
        emit StockGateHookSet(hook);
    }

    /// @notice Allow/deny a quote (stock) token and record its <stock>/WETH V3 fee tier for routing.
    function setAllowedQuote(address stock, bool allowed, uint24 v3Fee) external onlyOwner {
        if (stock == address(0) || stock == weth) revert QuoteNotAllowed();
        allowedQuote[stock] = allowed;
        quoteV3Fee[stock] = v3Fee;
        emit AllowedQuoteSet(stock, allowed, v3Fee);
    }

    /// @notice Set the stock-perp venue for Mode.Perps launches. The venue is pinned per token at
    /// launch (`registerPerps`), so changing this only affects FUTURE launches. Guarded so the
    /// venue's margin token must be this stack's WETH (else process()/open would pull a token the
    /// distributor never holds).
    function setPerpsVenue(address venue) external onlyOwner {
        if (venue != address(0) && IPerpsVenue(venue).marginToken() != weth) revert InvalidMode();
        perpsVenue = venue;
        emit PerpsVenueSet(venue);
    }

    /// @notice Tune the anti-snipe launch guard for FUTURE tokens: a `bps` wallet cap
    /// for the first `blocks` L1 blocks after launch (either 0 disables that part).
    function setAntiSnipe(uint16 bps, uint32 secs) external onlyOwner {
        if (bps > 10_000) revert InvalidFee();
        maxBuyBps = bps;
        maxBuySecs = secs;
        emit AntiSnipeSet(bps, secs);
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

    /// @dev Tick delta (rounded to tickSpacing) lifting the launch range from the WETH-calibrated
    /// default price to the quote's configured launch price. 0 when unset or not higher — the
    /// range is only ever RAISED, so the default init price stays valid below it.
    function _quoteTickShift(address quoteToken) internal view returns (int24) {
        uint256 p = quoteInitialPrice[quoteToken];
        // Signed both ways: a knob ABOVE the default raises the launch price (deep-priced stocks
        // like NVDA), a knob BELOW lowers it (low-decimals quotes like 6-dp USDG, whose sane
        // quote-wei price is ~9 orders under the 18-dp default). _launchStockOnV4 shifts the pool
        // init price by the same delta, so both directions keep the single-sided invariant.
        if (p == 0 || p == initialPriceWethPerToken) return 0;
        int24 tDefault = TickMath.getTickAtSqrtPrice(_sqrtPriceX96For(initialPriceWethPerToken, true));
        int24 tWanted = TickMath.getTickAtSqrtPrice(_sqrtPriceX96For(p, true));
        return ((tWanted - tDefault) / tickSpacing) * tickSpacing;
    }
}
