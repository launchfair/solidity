// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — https://hood.launchfair.app

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {LaunchTokenV2} from "../LaunchTokenV2.sol";
import {IV3SwapRouter} from "../../interfaces/IUniswapV3.sol";

interface ICreatorRegistryV4 {
    function creatorOf(address token) external view returns (address);
}

/// @notice Turns each mode token's accrued buy-side WETH fees into holder rewards.
/// The V4 FeeLocker forwards the mechanism's WETH here; a permissionless
/// `process(token)` buys the token's reward asset, then funds the token's dividend
/// tracker (Reward/Redistribute) or burns it (Burn).
///
/// The buyback runs on whichever venue the reward asset actually lives on: the
/// token's own **V4** pool (Redistribute/Burn), or — for a Reward token whose dev
/// chose an external reward — either a **V4** pool (PoolManager unlock/flash
/// accounting) or a **V3** pool (SwapRouter02 exact-input). Most established tokens
/// on this chain trade on V3, so a reward token is not restricted to V4-only.
///
/// Lottery tokens accrue WETH the same way, but instead of a buyback the whole pot
/// is drawn to one ticket holder. `commitDraw` closes the session (freezes the
/// tickets, reserves the pot) and locks the draw to a *future* drand round;
/// `settleDraw` pays the winner once that beacon is public and records the draw
/// on-chain (verifiable, powerball-style). Ticket sales for the drawn session end
/// at commit — buys after that count toward the next session — so no one can act
/// on the randomness once it's revealed. The prize is the WETH pot, paid as WETH
/// or as a dev-chosen prize token bought with it on the same V3/V4 venue as a
/// reward buyback. See the lottery section below.
contract LaunchFairV4Distributor is Ownable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    IV3SwapRouter public immutable v3Router; // SwapRouter02, for reward tokens on V3
    IERC20 public immutable weth;
    address public registrar; // the launchpad; records buyback pools (owner-settable for wiring)
    address public locker;

    // Where a token's reward asset is bought.
    enum Venue { V4, V3 }
    struct BuybackRoute {
        Venue venue;
        uint24 v3Fee;  // venue == V3: the V3 pool fee tier
        PoolKey v4Key; // venue == V4: the V4 pool key
    }
    mapping(address token => BuybackRoute) internal _buyback;
    mapping(address token => bool) public registered;
    mapping(address token => uint256) public pendingWeth;
    /// @notice Dev-set minimum pending WETH before a payout fires (anti-dust; the
    /// keeper only processes once it's crossed). 0 = fire on any pending.
    mapping(address token => uint256) public payoutThreshold;

    // ── lottery draws (Mode.Lottery) ────────────────────────────────────────────
    struct Draw {
        uint256 epoch;         // session (token.lotteryEpoch) the winner was drawn from
        uint256 round;         // committed drand round (fixed the seed before it existed)
        bytes32 randomness;    // drand beacon value for `round` (publicly re-verifiable)
        address winner;        // ticket holder who was drawn
        uint256 prize;         // WETH paid to the winner
        uint256 totalTickets;  // tickets in play for the epoch
        uint256 winningTicket; // derived on-chain: keccak(randomness,token,round) % totalTickets
        uint64 timestamp;
    }
    // A committed-but-unsettled draw: its session (epoch) and pot are frozen at
    // commit; only the drand beacon for `round` is still outstanding.
    struct PendingDraw { uint256 round; uint256 epoch; uint256 prize; bool active; }

    address public drawOperator; // off-chain keeper that commits/settles draws
    mapping(address token => Draw[]) public draws;         // full winner history
    mapping(address token => PendingDraw) public pendingDraw;

    event LockerSet(address locker);
    event BuybackRegistered(address indexed token, uint8 venue);
    event Notified(address indexed token, uint256 amount, uint256 pending);
    event Processed(address indexed token, uint256 wethIn, uint256 assetOut, uint8 mode);
    event PayoutThresholdSet(address indexed token, uint256 threshold);
    event DrawOperatorSet(address operator);
    event DrawCommitted(address indexed token, uint256 indexed drawId, uint256 round, uint256 epoch, uint256 prizeSnapshot);
    event DrawSettled(address indexed token, uint256 indexed drawId, uint256 epoch, address indexed winner, uint256 prize, bytes32 randomness, uint256 winningTicket);
    event DrawCanceled(address indexed token, uint256 epoch, uint256 prizeReturned);

    error OnlyLocker();
    error OnlyRegistrar();
    error OnlyPoolManager();
    error LockerAlreadySet();
    error NotRegistered();
    error NothingPending();
    error BelowThreshold();
    error NotAuthorized();
    error WrongMode();
    error Slippage();
    error ZeroAddress();
    error OnlyDrawOperator();
    error NotLottery();
    error DrawActive();
    error NoDraw();
    error NoTickets();
    error BadProof();

    constructor(address owner_, IPoolManager pm_, IV3SwapRouter v3Router_, IERC20 weth_, address registrar_)
        Ownable(owner_)
    {
        if (
            address(pm_) == address(0) || address(v3Router_) == address(0) || address(weth_) == address(0)
                || registrar_ == address(0)
        ) revert ZeroAddress();
        poolManager = pm_;
        v3Router = v3Router_;
        weth = weth_;
        registrar = registrar_;
    }

    function setLocker(address locker_) external onlyOwner {
        if (locker != address(0)) revert LockerAlreadySet();
        if (locker_ == address(0)) revert ZeroAddress();
        locker = locker_;
        emit LockerSet(locker_);
    }

    /// @notice Point the distributor at the launchpad (deployed after this).
    function setRegistrar(address registrar_) external onlyOwner {
        if (registrar_ == address(0)) revert ZeroAddress();
        registrar = registrar_;
    }

    /// @notice Launchpad records the **V4** pool where a token's reward asset is bought.
    function registerBuyback(address token, PoolKey calldata key) external {
        if (msg.sender != registrar) revert OnlyRegistrar();
        _buyback[token] = BuybackRoute({venue: Venue.V4, v3Fee: 0, v4Key: key});
        registered[token] = true;
        emit BuybackRegistered(token, uint8(Venue.V4));
    }

    /// @notice Launchpad records that a token's reward asset is bought on a **V3**
    /// pool (WETH/asset at fee tier `fee`) via SwapRouter02.
    function registerBuybackV3(address token, uint24 fee) external {
        if (msg.sender != registrar) revert OnlyRegistrar();
        PoolKey memory empty;
        _buyback[token] = BuybackRoute({venue: Venue.V3, v3Fee: fee, v4Key: empty});
        registered[token] = true;
        emit BuybackRegistered(token, uint8(Venue.V3));
    }

    /// @notice The venue (0 = V4, 1 = V3) a token's reward buyback runs on.
    function buybackVenue(address token) external view returns (uint8) {
        return uint8(_buyback[token].venue);
    }

    /// @notice Called by the V4 FeeLocker after forwarding `amount` WETH here.
    function notify(address token, uint256 amount) external {
        if (msg.sender != locker) revert OnlyLocker();
        pendingWeth[token] += amount;
        emit Notified(token, amount, pendingWeth[token]);
    }

    /// @notice The token's dev (creator) — or the launchpad — sets the minimum
    /// pending WETH that must accrue before a payout fires.
    function setPayoutThreshold(address token, uint256 amount) external {
        if (msg.sender != registrar && msg.sender != _creator(token)) revert NotAuthorized();
        payoutThreshold[token] = amount;
        emit PayoutThresholdSet(token, amount);
    }

    /// @notice True when a payout would succeed — the keeper polls/reacts on this.
    function readyToProcess(address token) external view returns (bool) {
        uint256 p = pendingWeth[token];
        return registered[token] && p > 0 && p >= payoutThreshold[token];
    }

    function _creator(address token) internal view returns (address) {
        try ICreatorRegistryV4(registrar).creatorOf(token) returns (address c) {
            return c;
        } catch {
            return address(0);
        }
    }

    /// @notice Permissionless: buy the token's reward asset with its pending WETH
    /// and distribute (Reward/Redistribute) or burn (Burn). `minOut` guards slippage.
    function process(address token, uint256 minOut) external nonReentrant returns (uint256 out) {
        uint256 wethIn = pendingWeth[token];
        if (wethIn == 0) revert NothingPending();
        if (wethIn < payoutThreshold[token]) revert BelowThreshold();
        if (!registered[token]) revert NotRegistered();
        LaunchTokenV2.Mode m = LaunchTokenV2(token).mode();
        // Base has no mechanism; Lottery uses draw()/settleDraw(), not a buyback.
        if (m == LaunchTokenV2.Mode.Base || m == LaunchTokenV2.Mode.Lottery) revert WrongMode();
        pendingWeth[token] = 0;

        out = _buyAsset(token, LaunchTokenV2(token).distributionAsset(), wethIn);
        if (out < minOut) revert Slippage();

        if (m == LaunchTokenV2.Mode.Burn) {
            LaunchTokenV2(token).fundBurn(out);
        } else {
            IERC20(LaunchTokenV2(token).distributionAsset()).forceApprove(token, out);
            LaunchTokenV2(token).fundRewards(out);
        }
        emit Processed(token, wethIn, out, uint8(m));
    }

    // ── lottery (Mode.Lottery) ──────────────────────────────────────────────────
    // The token accrues WETH exactly like a reward token, but instead of a buyback
    // the pot is paid whole to one ticket holder. Tickets are earned per-buy inside
    // the token (LaunchTokenV2.ticketsOf[epoch]). A draw is committed to a *future*
    // drand round so its randomness can't be known — let alone ground — in advance,
    // then settled once that round's beacon is published. Everything needed to
    // re-verify the winner (randomness, round, epoch, totalTickets, winningTicket)
    // is emitted + stored on-chain, powerball-style.

    function setDrawOperator(address op) external onlyOwner {
        if (op == address(0)) revert ZeroAddress();
        drawOperator = op;
        emit DrawOperatorSet(op);
    }

    /// @notice Number of settled draws for a token (history length; `draws(token,i)`
    /// reads each one — newest at `drawCount-1`).
    function drawCount(address token) external view returns (uint256) {
        return draws[token].length;
    }

    /// @notice Close the current session and commit its draw to drand `drandRound`
    /// (which must not yet have been produced, so the seed can't be known/ground in
    /// advance). Ticket sales for this draw end here: the epoch is advanced so later
    /// buys count toward the next session, and the current pot is reserved as the
    /// prize. Reverts on an empty session so no draw locks with nothing to win.
    function commitDraw(address token, uint256 drandRound) external returns (uint256 drawId) {
        if (msg.sender != drawOperator) revert OnlyDrawOperator();
        LaunchTokenV2 t = LaunchTokenV2(token);
        if (t.mode() != LaunchTokenV2.Mode.Lottery) revert NotLottery();
        if (pendingDraw[token].active) revert DrawActive();

        uint256 epoch = t.lotteryEpoch();
        if (t.totalTickets(epoch) == 0) revert NoTickets();

        uint256 prize = pendingWeth[token];
        pendingWeth[token] = 0;                 // reserve the pot for this draw…
        t.advanceLotteryEpoch();                // …and close ticket sales for `epoch`.

        pendingDraw[token] = PendingDraw({round: drandRound, epoch: epoch, prize: prize, active: true});
        drawId = draws[token].length;
        emit DrawCommitted(token, drawId, drandRound, epoch, prize);
    }

    /// @notice Settle the committed draw. `randomness` is the drand beacon for the
    /// committed round (re-verifiable off-chain against drand's public key). The
    /// winning ticket is derived here on-chain from it (tamper-evident); the caller
    /// supplies `winner` + its `cumulativeStart` (the winner's ticket offset in the
    /// canonical TicketsChanged order) and we prove on-chain the drawn ticket lands
    /// in `[cumulativeStart, cumulativeStart + winnerTickets)`. The session and pot
    /// were frozen at commit, so this pays out the reserved prize and records it.
    ///
    /// The prize is the reserved WETH pot, paid either as WETH (default) or as the
    /// dev-chosen prize token bought with it on the token's registered V3/V4 venue
    /// (`minPrizeOut` guards that swap; ignored for a WETH prize).
    function settleDraw(
        address token,
        bytes32 randomness,
        address winner,
        uint256 cumulativeStart,
        uint256 minPrizeOut
    ) external nonReentrant {
        if (msg.sender != drawOperator) revert OnlyDrawOperator();
        PendingDraw memory pd = pendingDraw[token];
        if (!pd.active) revert NoDraw();

        LaunchTokenV2 t = LaunchTokenV2(token);
        uint256 total = t.totalTickets(pd.epoch); // frozen at commit (epoch already advanced)

        uint256 winningTicket = uint256(keccak256(abi.encode(randomness, token, pd.round))) % total;
        uint256 winnerTickets = t.ticketsOf(pd.epoch, winner);
        // The winner's contiguous ticket range must contain the drawn ticket.
        if (winnerTickets == 0 || winningTicket < cumulativeStart || winningTicket >= cumulativeStart + winnerTickets) {
            revert BadProof();
        }

        delete pendingDraw[token];

        draws[token].push(Draw({
            epoch: pd.epoch,
            round: pd.round,
            randomness: randomness,
            winner: winner,
            prize: pd.prize,
            totalTickets: total,
            winningTicket: winningTicket,
            timestamp: uint64(block.timestamp)
        }));

        if (pd.prize > 0) {
            address prizeToken = t.rewardToken(); // 0 => WETH prize
            if (prizeToken == address(0)) {
                weth.safeTransfer(winner, pd.prize);
            } else {
                uint256 bought = _buyAsset(token, prizeToken, pd.prize);
                if (bought < minPrizeOut) revert Slippage();
                IERC20(prizeToken).safeTransfer(winner, bought);
            }
        }

        emit DrawSettled(token, draws[token].length - 1, pd.epoch, winner, pd.prize, randomness, winningTicket);
    }

    /// @notice Emergency recovery: abandon a committed draw whose beacon can't be
    /// settled (e.g. a bad committed round). Returns the reserved pot to `pendingWeth`
    /// so it rolls into the next draw. The already-closed session is not reopened —
    /// its tickets stay reset — so use only when a draw is genuinely stuck.
    function cancelDraw(address token) external {
        if (msg.sender != drawOperator) revert OnlyDrawOperator();
        PendingDraw memory pd = pendingDraw[token];
        if (!pd.active) revert NoDraw();
        delete pendingDraw[token];
        pendingWeth[token] += pd.prize;
        emit DrawCanceled(token, pd.epoch, pd.prize);
    }

    /// @dev Buy `asset` with `wethIn` on the token's registered buyback venue (V3
    /// SwapRouter02 or V4 PoolManager). The caller enforces slippage on the return.
    /// Used both for reward buybacks and for converting a lottery pot to its prize
    /// token, so the target asset is passed in rather than derived.
    function _buyAsset(address token, address asset, uint256 wethIn) internal returns (uint256 out) {
        return _buyback[token].venue == Venue.V3
            ? _buyV3(token, asset, wethIn)
            : abi.decode(poolManager.unlock(abi.encode(token, asset, wethIn)), (uint256));
    }

    /// @dev Buy `asset` on a Uniswap V3 pool via SwapRouter02 (exact-input single-hop).
    function _buyV3(address token, address asset, uint256 wethIn) internal returns (uint256 out) {
        weth.forceApprove(address(v3Router), wethIn);
        out = v3Router.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: asset,
                fee: _buyback[token].v3Fee,
                recipient: address(this),
                amountIn: wethIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev PoolManager flash-accounting callback: swap WETH -> `asset`, pay the
    /// WETH owed, take the asset bought. Returns the asset amount received.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (address token, address asset, uint256 wethIn) = abi.decode(data, (address, address, uint256));

        PoolKey memory key = _buyback[token].v4Key;
        Currency assetCur = Currency.wrap(asset);
        Currency wethCur = Currency.wrap(address(weth));
        bool zeroForOne = Currency.unwrap(key.currency0) == address(weth); // WETH is the input

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(wethIn), // exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // WETH side is negative (we owe); asset side positive (we receive).
        int128 wethDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 assetDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 wethOwed = uint256(int256(-wethDelta));
        uint256 assetOut = uint256(int256(assetDelta));

        // Pay WETH.
        poolManager.sync(wethCur);
        weth.safeTransfer(address(poolManager), wethOwed);
        poolManager.settle();
        // Take the bought asset.
        poolManager.take(assetCur, address(this), assetOut);

        return abi.encode(assetOut);
    }
}
