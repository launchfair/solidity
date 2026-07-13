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
import {IRandomnessConsumer} from "./LaunchFairVRFCoordinator.sol";

interface ICreatorRegistryV4 {
    function creatorOf(address token) external view returns (address);
}

interface IVRFCoordinator {
    function requestRandomness(uint256 round) external returns (uint256 requestId);
    function randomnessOf(uint256 round) external view returns (bytes32);
}

/// @notice Turns each mode token's accrued buy-side WETH fees into holder rewards.
/// The V4 FeeLocker forwards the mechanism's WETH here; a permissionless
/// `process(token)` buys the token's reward asset, then funds the token's dividend
/// tracker (Reward/Redistribute).
///
/// The buyback runs on whichever venue the reward asset actually lives on: the
/// token's own **V4** pool (Redistribute), or — for a Reward token whose dev
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
contract LaunchFairV4Distributor is Ownable, ReentrancyGuard, IUnlockCallback, IRandomnessConsumer {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    IV3SwapRouter public immutable v3Router; // SwapRouter02, for reward tokens on V3
    IERC20 public immutable weth;
    address public registrar; // the launchpad; records buyback pools (set-once after deploy)
    bool public registrarLocked; // registrar is frozen after the first post-deploy set (L-03)
    address public locker;

    // Where a token's reward asset is bought. Keyed by (token, asset) so a Reward token
    // can distribute up to 5 different reward assets, each on its own venue.
    enum Venue { V4, V3 }
    struct BuybackRoute {
        Venue venue;
        uint24 v3Fee;  // venue == V3: the V3 pool fee tier
        PoolKey v4Key; // venue == V4: the V4 pool key
    }
    mapping(address token => mapping(address asset => BuybackRoute)) internal _buyback;
    mapping(address token => mapping(address asset => bool)) internal _assetRegistered;
    mapping(address token => bool) public registered;
    /// @notice Addresses allowed to call process() (the keeper). The owner is always
    /// allowed. Gating this closes the permissionless-minOut sandwich vector (M-02):
    /// only a trusted caller passing a real quoted minOut can trigger a buyback.
    mapping(address caller => bool) public isProcessor;
    mapping(address token => uint256) public pendingWeth;
    /// @notice Dev-set minimum pending WETH before a payout fires (anti-dust; the
    /// keeper only processes once it's crossed). 0 = fire on any pending.
    mapping(address token => uint256) public payoutThreshold;
    /// @notice Dev-set minimum blocks between payouts/draws (a block-based timer).
    /// Measured in L1 blocks (~12s). 0 = no timer (fire as soon as ready) — which is
    /// what Redistribute uses ("insta"); Reward/Lottery set an interval.
    mapping(address token => uint256) public payoutIntervalBlocks;
    /// @notice L1 block of the token's last payout/draw (the timer's anchor).
    mapping(address token => uint256) public lastPayoutBlock;

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
    // commit. `randomness` is delivered by the VRF coordinator (0 until then).
    struct PendingDraw {
        uint256 round;
        uint256 epoch;
        uint256 prize;
        uint256 requestId; // the coordinator request this draw waits on
        bytes32 randomness; // pushed by the coordinator (or pulled at settle)
        bool active;
    }
    // Progress of a (possibly multi-transaction) settlement. `settleDraw` can be fed
    // the sorted holder set in chunks so an arbitrarily large lottery can always be
    // settled within block limits; this accumulates the running total + winner across
    // chunks and finalizes once every ticket is accounted for.
    struct Settlement {
        bool active;            // a settlement is in progress
        address lastHolder;     // last holder counted — the next chunk must exceed it
        address winner;         // set once the winning ticket falls in a holder's range
        uint256 cumulative;     // tickets counted so far
        uint256 winningTicket;  // cached at start (from the verified randomness)
        bytes32 randomness;     // cached at start (for the Draw record at finalize)
    }

    address public drawOperator; // off-chain keeper that commits/settles draws
    address public vrf; // the shared LaunchFairVRFCoordinator (randomness source)
    mapping(address token => Draw[]) public draws;         // full winner history
    mapping(address token => PendingDraw) public pendingDraw;
    mapping(address token => Settlement) public settlement; // in-progress paginated settle
    mapping(uint256 requestId => address token) public requestToken; // VRF callback routing

    event LockerSet(address locker);
    event RegistrarSet(address registrar);
    event ProcessorSet(address indexed processor, bool allowed);
    event BuybackRegistered(address indexed token, uint8 venue);
    event Notified(address indexed token, uint256 amount, uint256 pending);
    event Processed(address indexed token, uint256 wethIn, uint256 assetOut, uint8 mode);
    event PayoutThresholdSet(address indexed token, uint256 threshold);
    event PayoutIntervalSet(address indexed token, uint256 intervalBlocks);
    event DrawOperatorSet(address operator);
    event DrawCommitted(address indexed token, uint256 indexed drawId, uint256 round, uint256 epoch, uint256 prizeSnapshot);
    event DrawSettled(address indexed token, uint256 indexed drawId, uint256 epoch, address indexed winner, uint256 prize, bytes32 randomness, uint256 winningTicket);
    event DrawCanceled(address indexed token, uint256 epoch, uint256 prizeReturned);
    event VrfSet(address vrf);
    event RandomnessReady(address indexed token, uint256 indexed requestId, bytes32 randomness);

    error OnlyLocker();
    error OnlyRegistrar();
    error OnlyPoolManager();
    error LockerAlreadySet();
    error RegistrarLocked();
    error AlreadyRegistered();
    error NotProcessor();
    error NotRegistered();
    error NothingPending();
    error BelowThreshold();
    error TimerNotElapsed();
    error NotAuthorized();
    error WrongMode();
    error Slippage();
    error ZeroAddress();
    error OnlyDrawOperator();
    error NotLottery();
    error DrawActive();
    error NoDraw();
    error NoTickets();
    error BadHolderSet();
    error IncompleteHolderSet();
    error OnlyVrf();
    error VrfNotSet();
    error VrfAlreadySet();
    error RandomnessNotReady();
    error RoundNotFuture();
    error BeaconAlreadyProduced();
    error BadMinOuts();

    // drand quicknet timing (genesis unix time + round period), for the future-round
    // check that stops a malicious drawOperator grinding an already-produced beacon to
    // choose the winner (audit C-01). Matches the quicknet chain DrandBLS verifies.
    uint256 private constant DRAND_GENESIS = 1_692_803_367;
    uint256 private constant DRAND_PERIOD = 3;
    bool public vrfLocked; // vrf is set-once (audit M-01): owner can't swap the randomness source

    /// @dev The drand round currently being produced (per this chain's clock). A round
    /// strictly greater than this cannot have its beacon known yet.
    function _currentDrandRound() internal view returns (uint256) {
        if (block.timestamp <= DRAND_GENESIS) return 0;
        return (block.timestamp - DRAND_GENESIS) / DRAND_PERIOD + 1;
    }

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

    /// @notice Point the distributor at the launchpad (deployed after this). Set-once:
    /// the very first post-deploy call wires the real launchpad and then freezes it,
    /// so the owner can't later re-point the registrar to hijack buyback venues (L-03).
    function setRegistrar(address registrar_) external onlyOwner {
        if (registrarLocked) revert RegistrarLocked();
        if (registrar_ == address(0)) revert ZeroAddress();
        registrar = registrar_;
        registrarLocked = true;
        emit RegistrarSet(registrar_);
    }

    /// @notice Owner-manage the keeper allowlist that may call process() (M-02).
    function setProcessor(address processor, bool allowed) external onlyOwner {
        if (processor == address(0)) revert ZeroAddress();
        isProcessor[processor] = allowed;
        emit ProcessorSet(processor, allowed);
    }

    /// @notice Launchpad records the **V4** pool where a token's reward asset is bought.
    /// Each (token, asset) venue is registered once at launch and then frozen (L-03).
    function registerBuyback(address token, address asset, PoolKey calldata key) external {
        if (msg.sender != registrar) revert OnlyRegistrar();
        if (_assetRegistered[token][asset]) revert AlreadyRegistered();
        _buyback[token][asset] = BuybackRoute({venue: Venue.V4, v3Fee: 0, v4Key: key});
        _assetRegistered[token][asset] = true;
        registered[token] = true;
        emit BuybackRegistered(token, uint8(Venue.V4));
    }

    /// @notice Launchpad records that a token's reward `asset` is bought on a **V3**
    /// pool (WETH/asset at fee tier `fee`) via SwapRouter02. Registered once, then frozen.
    function registerBuybackV3(address token, address asset, uint24 fee) external {
        if (msg.sender != registrar) revert OnlyRegistrar();
        if (_assetRegistered[token][asset]) revert AlreadyRegistered();
        PoolKey memory empty;
        _buyback[token][asset] = BuybackRoute({venue: Venue.V3, v3Fee: fee, v4Key: empty});
        _assetRegistered[token][asset] = true;
        registered[token] = true;
        emit BuybackRegistered(token, uint8(Venue.V3));
    }

    /// @notice The venue (0 = V4, 1 = V3) a token's reward `asset` is bought on.
    function buybackVenue(address token, address asset) external view returns (uint8) {
        return uint8(_buyback[token][asset].venue);
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

    /// @notice The token's dev (creator) — or the launchpad — sets the block-based
    /// timer: minimum L1 blocks between payouts/draws. 0 = fire as soon as ready.
    function setPayoutInterval(address token, uint256 intervalBlocks) external {
        if (msg.sender != registrar && msg.sender != _creator(token)) revert NotAuthorized();
        payoutIntervalBlocks[token] = intervalBlocks;
        emit PayoutIntervalSet(token, intervalBlocks);
    }

    /// @notice Whether the token's block-timer has elapsed since its last payout.
    function timerElapsed(address token) public view returns (bool) {
        return block.number >= lastPayoutBlock[token] + payoutIntervalBlocks[token];
    }

    /// @notice True when a payout would succeed — the keeper polls/reacts on this.
    /// Gated by both the dev's pending-WETH threshold and the block timer.
    function readyToProcess(address token) external view returns (bool) {
        uint256 p = pendingWeth[token];
        return registered[token] && p > 0 && p >= payoutThreshold[token] && timerElapsed(token);
    }

    function _creator(address token) internal view returns (address) {
        try ICreatorRegistryV4(registrar).creatorOf(token) returns (address c) {
            return c;
        } catch {
            return address(0);
        }
    }

    /// @notice Buy the token's reward asset(s) with its pending WETH and distribute to
    /// holders (Reward / Redistribute). The pending WETH is split across the token's
    /// reward assets by the dev's fee weights; each portion buys its asset on that
    /// asset's venue and funds that asset's tracker. `minOuts[i]` guards slippage for
    /// asset `i` (aligned with `rewardTokensList()`). Restricted to the owner or an
    /// allowlisted keeper (M-02) so an untrusted caller can't force a `minOut=0` buyback.
    function process(address token, uint256[] calldata minOuts) external nonReentrant {
        if (msg.sender != owner() && !isProcessor[msg.sender]) revert NotProcessor();
        uint256 wethIn = pendingWeth[token];
        if (wethIn == 0) revert NothingPending();
        if (wethIn < payoutThreshold[token]) revert BelowThreshold();
        if (!timerElapsed(token)) revert TimerNotElapsed();
        if (!registered[token]) revert NotRegistered();
        LaunchTokenV2 t = LaunchTokenV2(token);
        LaunchTokenV2.Mode m = t.mode();
        // Base has no mechanism; Lottery uses draw()/settleDraw(), not a buyback.
        if (m == LaunchTokenV2.Mode.Base || m == LaunchTokenV2.Mode.Lottery) revert WrongMode();
        pendingWeth[token] = 0;
        lastPayoutBlock[token] = block.number; // reset the dev's block timer

        address[] memory assets = t.rewardTokensList();
        if (minOuts.length != assets.length) revert BadMinOuts();

        uint256 remaining = wethIn;
        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            // Split by the dev's weight; the last asset takes the remainder (dust-safe).
            uint256 portion = i == assets.length - 1 ? remaining : (wethIn * t.rewardWeightBps(asset)) / 10_000;
            remaining -= portion;
            if (portion == 0) continue;
            uint256 out = _buyAsset(token, asset, portion);
            if (out == 0 || out < minOuts[i]) revert Slippage(); // out==0 would burn WETH on a dead swap
            IERC20(asset).forceApprove(token, out);
            t.fundRewards(asset, out);
            emit Processed(token, portion, out, uint8(m));
        }
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

    /// @notice Point the distributor at the shared VRF coordinator (randomness source).
    /// **Set-once** (audit M-01): once wired, the owner cannot swap the randomness source
    /// for one it controls, so it can't rig lottery outcomes.
    function setVrf(address vrf_) external onlyOwner {
        if (vrfLocked) revert VrfAlreadySet();
        if (vrf_ == address(0)) revert ZeroAddress();
        vrf = vrf_;
        vrfLocked = true;
        emit VrfSet(vrf_);
    }

    /// @notice VRF coordinator push: deliver the drand beacon for a committed draw.
    /// Best-effort — if this ever reverts, settleDraw pulls the value directly.
    function fulfillRandomness(uint256 requestId, bytes32 randomness) external {
        if (msg.sender != vrf) revert OnlyVrf();
        address token = requestToken[requestId];
        if (token == address(0)) return;
        PendingDraw storage pd = pendingDraw[token];
        if (pd.active && pd.requestId == requestId && pd.randomness == bytes32(0)) {
            pd.randomness = randomness;
            emit RandomnessReady(token, requestId, randomness);
        }
    }

    /// @notice Number of settled draws for a token (history length; `draws(token,i)`
    /// reads each one — newest at `drawCount-1`).
    function drawCount(address token) external view returns (uint256) {
        return draws[token].length;
    }

    /// @notice Close the current session and commit its draw to a **future** drand
    /// `drandRound`. The future-round requirement is enforced ON-CHAIN (audit C-01): a
    /// round whose beacon is already produced could be ground by the operator to choose
    /// the winner, so `drandRound` must exceed the round currently being produced (bound
    /// to `block.timestamp` via drand's genesis+period). Ticket sales for this draw end
    /// here: the epoch is advanced so later buys count toward the next session, and the
    /// current pot is reserved as the prize. Reverts on an empty session.
    function commitDraw(address token, uint256 drandRound) external returns (uint256 drawId) {
        if (msg.sender != drawOperator) revert OnlyDrawOperator();
        LaunchTokenV2 t = LaunchTokenV2(token);
        if (t.mode() != LaunchTokenV2.Mode.Lottery) revert NotLottery();
        if (vrf == address(0)) revert VrfNotSet();
        if (pendingDraw[token].active) revert DrawActive();
        if (!timerElapsed(token)) revert TimerNotElapsed();
        // The committed round's beacon must not exist yet — otherwise the operator could
        // pick a past round whose (public) beacon makes its chosen holder win.
        if (drandRound <= _currentDrandRound()) revert RoundNotFuture();

        uint256 epoch = t.lotteryEpoch();
        if (t.totalTickets(epoch) == 0) revert NoTickets();

        lastPayoutBlock[token] = block.number;  // reset the dev's block timer
        uint256 prize = pendingWeth[token];
        pendingWeth[token] = 0;                 // reserve the pot for this draw…
        t.advanceLotteryEpoch();                // …and close ticket sales for `epoch`.

        // Ask the shared coordinator for the beacon at this future round; it will
        // push it back via fulfillRandomness (or we pull it at settle).
        uint256 reqId = IVRFCoordinator(vrf).requestRandomness(drandRound);
        requestToken[reqId] = token;
        pendingDraw[token] =
            PendingDraw({round: drandRound, epoch: epoch, prize: prize, requestId: reqId, randomness: 0, active: true});
        drawId = draws[token].length;
        emit DrawCommitted(token, drawId, drandRound, epoch, prize);
    }

    /// @notice Settle the committed draw. The drand beacon comes from the VRF
    /// coordinator — which only stores a value whose BLS signature it verified — so the
    /// seed is provably the real beacon and the winning ticket is derived on-chain from
    /// it. The winner is then derived on-chain too, with **no operator discretion**:
    /// the caller supplies the epoch's ticket-holders as `holders`, sorted strictly
    /// ascending by address. Strict-ascending order makes them distinct and defines a
    /// canonical partition of `[0, totalTickets)`; requiring the holders' stored ticket
    /// counts to sum to exactly `totalTickets` forces the set to be COMPLETE (any
    /// omission undershoots, any padding with a non-holder is rejected). The drawn ticket
    /// therefore lands in exactly one holder's range — the winner.
    ///
    /// **Paginated:** the sorted set can be fed across multiple calls, so a lottery with
    /// any number of holders can always be settled within block limits. Each call must
    /// continue strictly after the previous call's last holder; progress accumulates in
    /// `settlement[token]` and the draw finalizes on the call whose cumulative reaches
    /// `totalTickets`. A partial call returns 0 and records no draw yet. (`resetSettlement`
    /// restarts a botched sequence; `cancelDraw` abandons the whole draw.)
    ///
    /// The prize is the reserved WETH pot, paid on finalization either as WETH (default)
    /// or as the dev-chosen prize token bought with it on the token's registered V3/V4
    /// venue (`minPrizeOut` guards that swap; ignored for a WETH prize / partial calls).
    ///
    /// Returns the amount paid to the winner on the finalizing call (0 for a partial
    /// call), so the keeper can `eth_call` the final chunk with `minPrizeOut = 0` to
    /// quote the swap, then re-send with a real slippage bound.
    function settleDraw(
        address token,
        address[] calldata holders,
        uint256 minPrizeOut
    ) external nonReentrant returns (uint256 prizePaid) {
        if (msg.sender != drawOperator) revert OnlyDrawOperator();
        PendingDraw memory pd = pendingDraw[token];
        if (!pd.active) revert NoDraw();

        LaunchTokenV2 t = LaunchTokenV2(token);
        uint256 total = t.totalTickets(pd.epoch); // frozen at commit (epoch already advanced)

        // Start (or resume) the settlement. On the first chunk, pull + cache the verified
        // randomness and derive the winning ticket once.
        Settlement storage s = settlement[token];
        if (!s.active) {
            bytes32 rnd = pd.randomness;
            if (rnd == bytes32(0)) rnd = IVRFCoordinator(vrf).randomnessOf(pd.round); // pull fallback
            if (rnd == bytes32(0)) revert RandomnessNotReady();
            s.active = true;
            s.randomness = rnd;
            s.winningTicket = uint256(keccak256(abi.encode(rnd, token, pd.round))) % total;
        }

        // Walk this chunk of the sorted, complete holder set. `h > lastHolder` (strict,
        // and contiguous across chunks) => sorted + distinct; `tk != 0` => only real
        // holders; overshooting `total` => a bad set. The winner is whoever's cumulative
        // range owns the winning ticket — uniquely determined, the caller can't steer it.
        uint256 cumulative = s.cumulative;
        address lastHolder = s.lastHolder;
        address winner = s.winner;
        uint256 winningTicket = s.winningTicket;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            if (h <= lastHolder) revert BadHolderSet();
            lastHolder = h;
            uint256 tk = t.ticketsOf(pd.epoch, h);
            if (tk == 0) revert BadHolderSet();
            if (winner == address(0) && winningTicket < cumulative + tk) winner = h;
            cumulative += tk;
            if (cumulative > total) revert BadHolderSet(); // padded past the real total
        }

        if (cumulative < total) {
            // More holders to come — persist progress and wait for the next chunk.
            s.cumulative = cumulative;
            s.lastHolder = lastHolder;
            s.winner = winner;
            return 0;
        }
        // cumulative == total: the set is complete → finalize.
        if (winner == address(0)) revert IncompleteHolderSet(); // unreachable; defensive
        bytes32 randomness = s.randomness;

        delete settlement[token];
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
            address prizeToken = t.prizeToken(); // 0 => WETH prize
            if (prizeToken == address(0)) {
                weth.safeTransfer(winner, pd.prize); // WETH: no receiver hook, can't wedge
                prizePaid = pd.prize;
            } else {
                // Token prize: buy + send via a self-call wrapped in try/catch so a broken
                // venue, a sandwich past minPrizeOut, or an un-receivable winner can't wedge
                // this (now un-cancelable) draw (audit L-03) — fall back to paying the WETH pot.
                try this.swapAndSendPrize(token, prizeToken, winner, pd.prize, minPrizeOut) returns (uint256 bought) {
                    prizePaid = bought;
                } catch {
                    weth.safeTransfer(winner, pd.prize);
                    prizePaid = pd.prize;
                }
            }
        }

        emit DrawSettled(token, draws[token].length - 1, pd.epoch, winner, pd.prize, randomness, winningTicket);
    }

    /// @dev Self-only helper (so it can be `try`/`catch`ed from settleDraw): swap the pot
    /// to the prize token and send it to the winner. Reverts on slippage / bad venue /
    /// un-receivable winner, which settleDraw catches and pays out in WETH instead.
    function swapAndSendPrize(address token, address prizeToken, address winner, uint256 potWeth, uint256 minPrizeOut)
        external
        returns (uint256 bought)
    {
        if (msg.sender != address(this)) revert NotAuthorized();
        bought = _buyAsset(token, prizeToken, potWeth);
        if (bought < minPrizeOut) revert Slippage();
        IERC20(prizeToken).safeTransfer(winner, bought);
    }

    /// @notice Emergency recovery: abandon a committed draw whose round is bad (e.g. one
    /// so far in the future it'll never settle). Returns the reserved pot to `pendingWeth`.
    /// **Only callable BEFORE the committed round's beacon is produced** (audit M-02):
    /// once the beacon exists the outcome is determined, so the operator must settle to
    /// the deterministic winner and cannot cancel to veto/resample an unfavorable result.
    function cancelDraw(address token) external {
        if (msg.sender != drawOperator) revert OnlyDrawOperator();
        PendingDraw memory pd = pendingDraw[token];
        if (!pd.active) revert NoDraw();
        // beacon production time = genesis + (round-1)*period; reject once it has passed.
        if (block.timestamp >= DRAND_GENESIS + (pd.round - 1) * DRAND_PERIOD) revert BeaconAlreadyProduced();
        delete pendingDraw[token];
        delete settlement[token]; // drop any in-progress paginated settle
        pendingWeth[token] += pd.prize;
        emit DrawCanceled(token, pd.epoch, pd.prize);
    }

    /// @notice Discard an in-progress paginated settlement so it can be restarted from
    /// the first chunk — recovery if a chunk was submitted out of order (e.g. a holder
    /// was skipped, leaving the running total unable to reach `totalTickets`). The draw
    /// itself stays committed; only the partial progress is cleared.
    function resetSettlement(address token) external {
        if (msg.sender != drawOperator) revert OnlyDrawOperator();
        delete settlement[token];
    }

    /// @dev Buy `asset` with `wethIn` on the token's registered buyback venue (V3
    /// SwapRouter02 or V4 PoolManager). The caller enforces slippage on the return.
    /// Used both for reward buybacks and for converting a lottery pot to its prize
    /// token, so the target asset is passed in rather than derived.
    function _buyAsset(address token, address asset, uint256 wethIn) internal returns (uint256 out) {
        return _buyback[token][asset].venue == Venue.V3
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
                fee: _buyback[token][asset].v3Fee,
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

        PoolKey memory key = _buyback[token][asset].v4Key;
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
