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
import {IPerpsVenue} from "./IPerpsVenue.sol";
import {PerpPositionToken} from "./PerpPositionToken.sol";

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
    address public feeHook;
    /// @notice Every contract authorized to call `notify` (both fee hooks + anything future).
    mapping(address => bool) public isFeeSource;
    /// @notice Ceilings so a creator can't park a payout out of reach.
    uint256 public constant MAX_PAYOUT_THRESHOLD = 100 ether;
    /// ~7 days: `block.number` here tracks L1 (~12s), not the ~100ms L2 block.
    uint256 public constant MAX_PAYOUT_INTERVAL_BLOCKS = 50_400;
    // Mode.Perps: the venue is PINNED per token at launch (via registerPerps) — so a later global
    // change can never brick an existing token, and the launch-time and payout-time venues can't diverge.
    mapping(address token => address) public perpsVenueOf;

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
    /// @notice Lottery only. Each draw rolls `randomness % 10000` (i.e. 0.00–99.99) into one
    /// of three outcomes by these dev-set bands:
    ///   • MISS   — roll < missBps: nobody wins, the pot rolls over and keeps growing.
    ///   • JACKPOT— roll ≥ 10000 - jackpotChanceBps: winner takes the WHOLE pot + jackpot pool.
    ///   • REGULAR— everything in between: winner takes `regularWinShareBps` of the pot, and the
    ///              remainder is skimmed into the jackpot pool (which only pays out on a JACKPOT).
    /// missBps + jackpotChanceBps must be < 10000 (the gap is the regular-win band). Defaults
    /// (set by the launchpad) are 1000 / 200 / 7000 = 10% miss, 2% jackpot, 88% regular @ 70/30.
    mapping(address token => uint16) public jackpotChanceBps;
    mapping(address token => uint16) public missBps;
    mapping(address token => uint16) public regularWinShareBps;
    /// @notice The jackpot pool: skimmed from every regular win, paid out (with the pot) only
    /// on a JACKPOT roll. Separate from `pendingWeth` (the pot funded by trade fees).
    mapping(address token => uint256) public jackpotWeth;

    // ── lottery draws (Mode.Lottery) ────────────────────────────────────────────
    struct Draw {
        uint256 epoch;         // session (token.lotteryEpoch) the winner was drawn from
        uint256 round;         // committed drand round (fixed the seed before it existed)
        bytes32 randomness;    // drand beacon value for `round` (publicly re-verifiable)
        address winner;        // ticket holder who was drawn (address(0) on a rolled-over miss)
        uint256 prize;         // WETH paid to the winner (0 on a miss)
        uint256 totalTickets;  // tickets in play for the epoch
        uint256 winningTicket; // derived on-chain: keccak(randomness,token,round) % totalTickets
        uint256 hitRoll;       // outcome roll: keccak(randomness,token,round,1) % 10000 (0.00–99.99)
        uint8 outcome;         // 0 = miss (rolled over), 1 = regular win, 2 = jackpot
        uint64 timestamp;
    }
    // A committed-but-unsettled draw: its session (epoch) and pot are frozen at
    // commit. `randomness` is delivered by the VRF coordinator (0 until then).
    struct PendingDraw {
        uint256 round;
        uint256 epoch;
        uint256 prize;
        uint256 snapshotBlock; // block whose holdings the winner is drawn from (frozen at commit)
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
        bool ticketReached;     // the winning ticket's holder range has been passed
        address lastHolder;     // last holder counted — the next chunk must exceed it
        address winner;         // first NON-COOLING holder at/after the winning ticket
        address firstEligible;  // first non-cooling holder seen (wrap-around fallback)
        uint256 cumulative;     // tickets counted so far
        uint256 winningTicket;  // cached at start (from the verified randomness)
        bytes32 randomness;     // cached at start (for the Draw record at finalize)
    }

    address public drawOperator; // off-chain keeper that commits/settles draws
    address public vrf; // the shared LaunchFairVRFCoordinator (randomness source)
    mapping(address token => Draw[]) public draws;         // full winner history

    /// @notice Repeat-winner cooldown: a wallet that wins a token's lottery can't win THAT token
    /// again for `winCooldownSecs`. If a draw's winning ticket lands on a still-cooling holder,
    /// the draw is RE-DRAWN past them (the next eligible holder at/after the ticket wins, wrapping
    /// to the first eligible holder), so the pot still pays out and only voids to a miss if EVERY
    /// holder is cooling. Selection stays deterministic from the beacon, so it can't be steered.
    /// NOTE: the cooldown is keyed by winner ADDRESS, so it's a soft deterrent — a winner can move
    /// their balance to a fresh wallet to reset it; do not rely on it as a hard guarantee. Owner-
    /// tunable; 0 disables it. Default 1 hour.
    uint256 public winCooldownSecs = 1 hours;
    mapping(address token => mapping(address wallet => uint64)) public lastWinAt;
    mapping(address token => PendingDraw) public pendingDraw;
    mapping(address token => Settlement) public settlement; // in-progress paginated settle
    mapping(uint256 requestId => address token) public requestToken; // VRF callback routing

    event LockerSet(address locker);
    event FeeHookSet(address feeHook);
    event FeeSourceSet(address indexed source, bool allowed);
    event PendingWethRescued(address indexed token, address indexed to, uint256 amount);
    event PerpsVenueSet(address indexed token, address venue);
    event RegistrarSet(address registrar);
    event ProcessorSet(address indexed processor, bool allowed);
    event BuybackRegistered(address indexed token, uint8 venue);
    event Notified(address indexed token, uint256 amount, uint256 pending);
    event Processed(address indexed token, uint256 wethIn, uint256 assetOut, uint8 mode);
    event PayoutThresholdSet(address indexed token, uint256 threshold);
    event PayoutIntervalSet(address indexed token, uint256 intervalBlocks);
    event LotteryOddsSet(address indexed token, uint16 missBps, uint16 jackpotBps, uint16 regularShareBps);
    event DrawResolved(address indexed token, uint256 indexed epoch, uint8 outcome, address winner, uint256 prize, uint256 hitRoll);
    event DrawOperatorSet(address operator);
    event DrawCommitted(address indexed token, uint256 indexed drawId, uint256 round, uint256 epoch, uint256 prizeSnapshot);
    event DrawSettled(address indexed token, uint256 indexed drawId, uint256 epoch, address indexed winner, uint256 prize, bytes32 randomness, uint256 winningTicket);
    event DrawCanceled(address indexed token, uint256 epoch, uint256 prizeReturned);
    event WinCooldownSet(uint256 secs);
    event VrfSet(address vrf);
    event RandomnessReady(address indexed token, uint256 indexed requestId, bytes32 randomness);

    error OnlyLocker();
    error BadPayoutConfig();
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
    error BadJackpotChance();
    error AlreadySet();
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

    /// @notice Authorize the WethFeeHook as an additional fee source that may `notify()` the pot
    /// (alongside the locker) — so a mode token launched through the hook funds its own mechanism.
    /// Owner-settable (re-settable, since the hook can be re-mined/redeployed); 0 disables it.
    /// Setting a new hook (or 0) REVOKES the previous one: `notify` credits a token's pot without
    /// the WETH having to arrive, and the pot is a single pool shared across all tokens, so a
    /// retired hook the operator believed disabled could otherwise still inflate any token's
    /// balance and drain WETH belonging to others.
    function setFeeHook(address feeHook_) external onlyOwner {
        address prev = feeHook;
        if (prev != address(0) && prev != feeHook_) {
            isFeeSource[prev] = false;
            emit FeeSourceSet(prev, false);
        }
        feeHook = feeHook_;
        if (feeHook_ != address(0)) isFeeSource[feeHook_] = true; // keep the legacy setter working
        emit FeeHookSet(feeHook_);
    }

    /// @notice Authorize (or revoke) a fee source that may call `notify`. There is more than one
    /// hook in the system — WethFeeHook for WETH pairs, StockFeeHook for stock pairs — and the
    /// single `feeHook` slot could only ever hold one of them, so whichever was not set had its
    /// notify REVERT, taking the whole fee distribution down with it (the mechanism slice, and
    /// the treasury/creator/flagship slices in the same call).
    function setFeeSource(address source, bool allowed) external onlyOwner {
        if (source == address(0)) revert ZeroAddress();
        isFeeSource[source] = allowed;
        emit FeeSourceSet(source, allowed);
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

    /// @notice Launchpad marks a Mode.Perps token as processable. It has no Uniswap buyback venue —
    /// its reward assets are the venue's leveraged-position tokens, minted in `process()` via
    /// `perpsVenue.open`, reading each leg's (market, side, leverage) off the position token itself.
    function registerPerps(address token, address venue) external {
        if (msg.sender != registrar) revert OnlyRegistrar();
        registered[token] = true;
        perpsVenueOf[token] = venue; // pin the venue for this token's whole life
        emit PerpsVenueSet(token, venue);
    }

    /// @notice The venue (0 = V4, 1 = V3) a token's reward `asset` is bought on.
    function buybackVenue(address token, address asset) external view returns (uint8) {
        return uint8(_buyback[token][asset].venue);
    }

    /// @notice Recover a token's pending mechanism WETH when its venue is permanently unroutable —
    /// a reward pool whose liquidity was later pulled (`process` then reverts on slippage forever).
    /// Venues are registered once at launch, so without this the WETH is dead: this contract has
    /// no other withdrawal, unlike FlagshipBuyback and SeasonMerkleDistributor.
    ///
    /// GUARDED so a single owner key cannot sweep live user rewards or an in-flight lottery pot:
    ///   - refuses while a draw is committed (`!pendingDraw.active`), so it can't be used to make
    ///     `settleDraw` pay the winner 0 after the fact;
    ///   - only after the payout timer has been stuck for a full interval, so it targets genuinely
    ///     dead funds, never rewards that are actively accruing and payable;
    ///   - bounded by that token's own `pendingWeth`, so it can never touch another token's pot.
    function rescuePendingWeth(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (pendingDraw[token].active) revert DrawActive();
        // "Stuck" = no successful payout for at least one full max interval (~7 days of L1 blocks).
        if (block.number <= lastPayoutBlock[token] + MAX_PAYOUT_INTERVAL_BLOCKS) revert TimerNotElapsed();
        uint256 pend = pendingWeth[token];
        if (amount > pend) amount = pend;
        if (amount == 0) return;
        pendingWeth[token] = pend - amount;
        IERC20(weth).safeTransfer(to, amount);
        emit PendingWethRescued(token, to, amount);
    }

    /// @notice Called by the V4 FeeLocker after forwarding `amount` WETH here.
    function notify(address token, uint256 amount) external {
        if (msg.sender != locker && !isFeeSource[msg.sender]) revert OnlyLocker();
        pendingWeth[token] += amount;
        emit Notified(token, amount, pendingWeth[token]);
    }

    /// @notice The token's dev (creator) — or the launchpad — sets the minimum
    /// pending WETH that must accrue before a payout fires.
    function setPayoutThreshold(address token, uint256 amount) external {
        if (msg.sender != registrar && msg.sender != _creator(token) && msg.sender != owner()) {
            revert NotAuthorized();
        }
        // A creator setting this to type(uint256).max would make process() revert BelowThreshold
        // forever, freezing every holder's rewards (and a lottery's whole pot) with no way out.
        // The owner is now authorized to unstick it, and the value is clamped.
        if (amount > MAX_PAYOUT_THRESHOLD) revert BadPayoutConfig();
        payoutThreshold[token] = amount;
        emit PayoutThresholdSet(token, amount);
    }

    /// @notice The token's dev (creator) — or the launchpad — sets the block-based
    /// timer: minimum L1 blocks between payouts/draws. 0 = fire as soon as ready.
    function setPayoutInterval(address token, uint256 intervalBlocks) external {
        if (msg.sender != registrar && msg.sender != _creator(token) && msg.sender != owner()) {
            revert NotAuthorized();
        }
        // Same hostage problem as the threshold: an enormous interval freezes payouts and draws.
        if (intervalBlocks > MAX_PAYOUT_INTERVAL_BLOCKS) revert BadPayoutConfig();
        payoutIntervalBlocks[token] = intervalBlocks;
        emit PayoutIntervalSet(token, intervalBlocks);
    }

    /// @notice Lottery only: set the three outcome bands + the regular-win split. Set once by
    /// the launchpad at creation — fixed values can't be gamed on holders after a pot builds.
    ///   miss_ + jackpot_ must be < 10000 (the gap is the regular-win band, > 0).
    ///   share_ (1..10000) = the regular winner's cut of the pot; the rest skims to the jackpot.
    function setLotteryOdds(address token, uint16 miss_, uint16 jackpot_, uint16 share_) external {
        if (msg.sender != registrar) revert NotAuthorized();
        if (jackpotChanceBps[token] != 0) revert AlreadySet();
        if (jackpot_ == 0 || uint256(miss_) + jackpot_ >= 10_000) revert BadJackpotChance();
        if (share_ == 0 || share_ > 10_000) revert BadJackpotChance();
        missBps[token] = miss_;
        jackpotChanceBps[token] = jackpot_;
        regularWinShareBps[token] = share_;
        emit LotteryOddsSet(token, miss_, jackpot_, share_);
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
        uint256 prevPayoutBlock = lastPayoutBlock[token];
        lastPayoutBlock[token] = block.number; // reset the dev's timer (restored below if nothing deploys)

        address[] memory assets = t.rewardTokensList();
        if (minOuts.length != assets.length) revert BadMinOuts();

        bool perps = (m == LaunchTokenV2.Mode.Perps);
        address venue = perps ? perpsVenueOf[token] : address(0); // pinned at launch, per token
        uint256 remaining = wethIn;
        uint256 held; // Perps: WETH for closed/failing legs, re-credited to pendingWeth for next cycle
        uint256 deployed; // WETH actually deployed this cycle
        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            // Split by the dev's weight; the last asset takes the remainder (dust-safe).
            uint256 portion = i == assets.length - 1 ? remaining : (wethIn * t.rewardWeightBps(asset)) / 10_000;
            remaining -= portion;
            if (portion == 0) continue;
            uint256 out;
            if (perps) {
                // HOLD this leg's WETH (deploy a later cycle) when its market is closed, its open
                // FAILS (liquidated pool), or it mints too few shares. A single bad leg must NEVER
                // revert the whole batch and brick the token's rewards (mirrors the lottery try/catch).
                if (!IPerpsVenue(venue).marketOpen(PerpPositionToken(asset).market())) {
                    held += portion;
                    continue;
                }
                out = _openPerp(venue, asset, portion); // deposit margin → mint the position token
                if (out == 0 || out < minOuts[i]) {
                    held += portion;
                    continue;
                }
            } else {
                out = _buyAsset(token, asset, portion); // swap WETH → reward asset on its venue
                if (out == 0 || out < minOuts[i]) revert Slippage(); // out==0 would burn WETH on a dead swap
            }
            IERC20(asset).forceApprove(token, out);
            t.fundRewards(asset, out);
            deployed += portion;
            emit Processed(token, portion, out, uint8(m));
        }
        if (held > 0) pendingWeth[token] = held; // closed/failing legs — hold for next cycle
        if (deployed == 0) lastPayoutBlock[token] = prevPayoutBlock; // nothing deployed → don't burn the timer
    }

    /// @dev Deposit `wethIn` as margin into the (market, side, leverage) pool encoded by the position
    /// token `asset`, minting the leveraged-position token to this distributor (then funded to
    /// holders). Config is read off the token — the distributor never chooses direction/leverage. A
    /// venue revert (e.g. a liquidated pool, or a sub-NAV dust deposit) is CAUGHT and returned as 0
    /// shares, so the caller HOLDS that leg instead of reverting the whole payout.
    function _openPerp(address venue, address asset, uint256 wethIn) internal returns (uint256 shares) {
        PerpPositionToken pt = PerpPositionToken(asset);
        weth.forceApprove(venue, wethIn);
        try IPerpsVenue(venue).open(pt.market(), pt.isLong(), pt.leverageBps(), wethIn) returns (address, uint256 s) {
            shares = s;
        } catch {
            weth.forceApprove(venue, 0); // clear the unused approval on a caught failure
            shares = 0;
        }
    }

    // ── lottery (Mode.Lottery) — powerball ($BALL) style, holdings-weighted ─────────
    // The token accrues WETH exactly like a reward token, but instead of a buyback the
    // pot is paid whole to one holder, weighted by holdings. A draw snapshots every
    // holder's balance at its commit block (LaunchTokenV2.balanceOfAt / totalEligibleAt)
    // and is committed to a *future* drand round, so the winner is drawn from holdings
    // frozen BEFORE the randomness exists — nobody can buy to steer a known result. It's
    // settled once that round's beacon is published. Everything needed to re-verify the
    // winner (randomness, round, snapshot block, total, winningTicket) is on-chain.

    function setDrawOperator(address op) external onlyOwner {
        if (op == address(0)) revert ZeroAddress();
        drawOperator = op;
        emit DrawOperatorSet(op);
    }

    /// @notice Set the repeat-winner cooldown (seconds). A winner can't win the same token's
    /// lottery again until it elapses; a re-selected cooling winner voids the draw to a miss.
    /// 0 disables the cooldown.
    function setWinCooldown(uint256 secs) external onlyOwner {
        winCooldownSecs = secs;
        emit WinCooldownSet(secs);
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
    /// to `block.timestamp` via drand's genesis+period). Eligibility for this draw is frozen
    /// at `block.number - 1` (see below); the epoch is NOT advanced here (it advances only when
    /// a jackpot is actually won) and the pot is NOT reserved (a miss rolls it over, and the
    /// winner takes the live pot at settle). Reverts on an empty session.
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
        // Holdings-weighted: the odds pool is every holder's balance at the snapshot.
        //
        // Snapshot the PREVIOUS block, not this one. On this Nitro chain `block.number` is the
        // L1 block number: it advances roughly every 12 seconds while ~120 L2 blocks fit inside
        // one value, and the balance checkpoints are keyed by it, with a repeated key
        // OVERWRITING. Snapshotting `block.number` therefore captures balances at the END of the
        // current 12-second window, not at commit — so anyone watching for `commitDraw` could
        // buy a large multiple of the float in the same window, be recorded at the inflated
        // balance, and sell the moment it ticks over, winning the pot near-arbitrarily for the
        // cost of a round trip. `block.number - 1` is already sealed when this executes.
        if (block.number == 0) revert TimerNotElapsed();
        uint256 snapshotBlock = block.number - 1;
        // Check the SNAPSHOT's supply, not the live one: they differ now that the snapshot is
        // the previous block, and an empty snapshot would otherwise divide by zero at settle
        // (with the draw already committed and the timer reset) instead of failing here.
        if (t.totalEligibleAt(snapshotBlock) == 0) revert NoTickets();

        lastPayoutBlock[token] = block.number;  // reset the timer that paces draw attempts
        // The pot is NOT reserved or zeroed here: on a miss it rolls over and keeps
        // growing; on a hit the winner takes the LIVE pot at settle. The epoch (jackpot
        // session) advances only when a jackpot is actually won.
        uint256 potNow = pendingWeth[token]; // indicative only (emitted below)

        // Ask the shared coordinator for the beacon at this future round; it will
        // push it back via fulfillRandomness (or we pull it at settle).
        uint256 reqId = IVRFCoordinator(vrf).requestRandomness(drandRound);
        requestToken[reqId] = token;
        pendingDraw[token] = PendingDraw({
            round: drandRound,
            epoch: epoch,
            prize: 0, // unused; the paid prize is the live pot at settle (rollover model)
            snapshotBlock: snapshotBlock,
            requestId: reqId,
            randomness: 0,
            active: true
        });
        drawId = draws[token].length;
        emit DrawCommitted(token, drawId, drandRound, epoch, potNow);
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
        uint256 total = t.totalEligibleAt(pd.snapshotBlock); // total held at the commit snapshot

        // Start (or resume) the settlement. On the first chunk, pull + cache the verified
        // randomness and roll for the outcome. A MISS finalizes here (no holders needed); a
        // REGULAR or JACKPOT win begins the paginated weighted winner search.
        Settlement storage s = settlement[token];
        if (!s.active) {
            bytes32 rnd = pd.randomness;
            if (rnd == bytes32(0)) rnd = IVRFCoordinator(vrf).randomnessOf(pd.round); // pull fallback
            if (rnd == bytes32(0)) revert RandomnessNotReady();

            // Outcome roll — from the SAME future beacon as the winner, so it's unknowable at
            // commit and provably fair. A distinct preimage (…, 1) keeps it independent of the
            // winning-ticket derivation. 0.00–99.99 space via % 10000.
            uint256 hitRoll = uint256(keccak256(abi.encode(rnd, token, pd.round, uint256(1)))) % 10_000;
            (uint256 missB,) = _lotteryBands(token);

            if (hitRoll < missB) {
                // MISS → nobody wins; the pot (and jackpot pool) stay and roll over. One call.
                delete pendingDraw[token];
                draws[token].push(Draw({
                    epoch: pd.epoch,
                    round: pd.round,
                    randomness: rnd,
                    winner: address(0),
                    prize: 0,
                    totalTickets: total,
                    winningTicket: 0,
                    hitRoll: hitRoll,
                    outcome: 0,
                    timestamp: uint64(block.timestamp)
                }));
                emit DrawResolved(token, pd.epoch, 0, address(0), 0, hitRoll);
                return 0;
            }

            // REGULAR or JACKPOT → begin the (paginated) weighted winner search.
            s.active = true;
            s.randomness = rnd;
            s.winningTicket = uint256(keccak256(abi.encode(rnd, token, pd.round))) % total;
        }

        // Walk this chunk of the sorted, complete holder set (see _walkHolders); returns true once
        // every ticket is accounted for. A partial chunk persists progress and waits for the next.
        if (!_walkHolders(token, s, pd.snapshotBlock, holders, total)) return 0;

        // Complete → finalize. The winner is the first non-cooling holder at/after the ticket; if
        // the ticket fell on cooling holders through the end of the set, wrap to the first eligible
        // holder. If EVERY holder is on cooldown, `winner` stays 0 → void to a miss (pot rolls over).
        address winner = s.winner;
        if (winner == address(0)) winner = s.firstEligible;
        uint256 winningTicket = s.winningTicket;
        bytes32 randomness = s.randomness;
        uint256 roll = uint256(keccak256(abi.encode(randomness, token, pd.round, uint256(1)))) % 10_000;
        (, uint256 jpB) = _lotteryBands(token);

        if (winner == address(0)) {
            delete settlement[token];
            delete pendingDraw[token];
            draws[token].push(Draw({
                epoch: pd.epoch, round: pd.round, randomness: randomness,
                winner: address(0), prize: 0, totalTickets: total, winningTicket: winningTicket,
                hitRoll: roll, outcome: 0, timestamp: uint64(block.timestamp)
            }));
            emit DrawResolved(token, pd.epoch, 0, address(0), 0, roll);
            return 0;
        }

        uint256 prize;
        uint8 outcome;
        uint256 pot = pendingWeth[token];
        pendingWeth[token] = 0;
        if (roll >= 10_000 - jpB) {
            // JACKPOT → winner takes the whole pot + the accumulated jackpot pool; both reset.
            outcome = 2;
            prize = pot + jackpotWeth[token];
            jackpotWeth[token] = 0;
        } else {
            // REGULAR → winner takes their share of the pot; the rest skims to the jackpot pool.
            outcome = 1;
            prize = (pot * regularWinShareBps[token]) / 10_000;
            jackpotWeth[token] += pot - prize;
        }

        lastWinAt[token][winner] = uint64(block.timestamp); // start this winner's cooldown

        delete settlement[token];
        delete pendingDraw[token];

        draws[token].push(Draw({
            epoch: pd.epoch,
            round: pd.round,
            randomness: randomness,
            winner: winner,
            prize: prize,
            totalTickets: total,
            winningTicket: winningTicket,
            hitRoll: roll,
            outcome: outcome,
            timestamp: uint64(block.timestamp)
        }));

        if (outcome == 2) t.advanceLotteryEpoch(); // jackpot won → open the next session

        if (prize > 0) {
            address prizeToken = t.prizeToken(); // 0 => WETH prize
            if (prizeToken == address(0)) {
                weth.safeTransfer(winner, prize); // WETH: no receiver hook, can't wedge
                prizePaid = prize;
            } else {
                // Token prize: buy + send via a self-call wrapped in try/catch so a broken
                // venue, a sandwich past minPrizeOut, or an un-receivable winner can't wedge
                // this (now un-cancelable) draw (audit L-03) — fall back to paying the WETH pot.
                try this.swapAndSendPrize(token, prizeToken, winner, prize, minPrizeOut) returns (uint256 bought) {
                    prizePaid = bought;
                } catch {
                    weth.safeTransfer(winner, prize);
                    prizePaid = prize;
                }
            }
        }

        emit DrawResolved(token, pd.epoch, outcome, winner, prize, roll);
    }

    /// @dev Lottery outcome bands (bps on the 0.00–99.99 roll): roll < missB = MISS,
    /// roll ≥ 10000 - jpB = JACKPOT, else REGULAR. Unset (jackpotChanceBps 0) => always
    /// JACKPOT (miss 0), so a misconfigured token pays the whole pot and never locks it.
    function _lotteryBands(address token) internal view returns (uint256 missB, uint256 jpB) {
        jpB = jackpotChanceBps[token];
        if (jpB == 0) return (0, 10_000);
        missB = missBps[token];
    }

    /// @dev True while `who` is inside its repeat-winner cooldown for `token` (won within the last
    /// `winCooldownSecs`). A first-ever winner (`lastWinAt == 0`) is never cooling.
    function _isCooling(address token, address who) internal view returns (bool) {
        uint64 wonAt = lastWinAt[token][who];
        return winCooldownSecs != 0 && wonAt != 0 && block.timestamp < uint256(wonAt) + winCooldownSecs;
    }

    /// @dev Walk a chunk of the sorted, complete holder set, accumulating into `s`. `h > lastHolder`
    /// (strict, contiguous across chunks) => sorted + distinct; `tk != 0` => only real holders;
    /// overshooting `total` => a bad set. Winner derivation is the first NON-COOLING holder at/after
    /// the winning ticket (cooldown re-draw), tracking the first eligible holder as a wrap-around
    /// fallback. Uniquely determined by the beacon + the holder set — the caller can't steer it.
    /// Returns true once the cumulative reaches `total` (the set is complete). Split out of
    /// `settleDraw` to keep its stack shallow.
    function _walkHolders(
        address token,
        Settlement storage s,
        uint256 snapshotBlock,
        address[] calldata holders,
        uint256 total
    ) internal returns (bool complete) {
        LaunchTokenV2 t = LaunchTokenV2(token);
        uint256 cumulative = s.cumulative;
        address lastHolder = s.lastHolder;
        address winner = s.winner;
        bool ticketReached = s.ticketReached;
        address firstEligible = s.firstEligible;
        uint256 winningTicket = s.winningTicket;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            if (h <= lastHolder) revert BadHolderSet();
            lastHolder = h;
            uint256 tk = t.balanceOfAt(h, snapshotBlock); // the holder's held balance at the snapshot
            if (tk == 0) revert BadHolderSet();
            bool cooling = _isCooling(token, h);
            if (!cooling && firstEligible == address(0)) firstEligible = h;
            if (winner == address(0)) {
                if (!ticketReached && winningTicket < cumulative + tk) ticketReached = true;
                if (ticketReached && !cooling) winner = h;
            }
            cumulative += tk;
            if (cumulative > total) revert BadHolderSet(); // padded past the real total
        }
        s.cumulative = cumulative;
        s.lastHolder = lastHolder;
        s.winner = winner;
        s.ticketReached = ticketReached;
        s.firstEligible = firstEligible;
        return cumulative == total;
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
    /// so far in the future it'll never settle). The pot is untouched by a draw (it only
    /// leaves pendingWeth on a hit at settle), so cancelling just drops the pending draw and
    /// the pot rolls on. **Only callable BEFORE the committed round's beacon is produced**
    /// (audit M-02): once the beacon exists the outcome is determined, so the operator must
    /// settle to the deterministic result and cannot cancel to veto an unfavorable one.
    function cancelDraw(address token) external {
        if (msg.sender != drawOperator) revert OnlyDrawOperator();
        PendingDraw memory pd = pendingDraw[token];
        if (!pd.active) revert NoDraw();
        // beacon production time = genesis + (round-1)*period; reject once it has passed.
        if (block.timestamp >= DRAND_GENESIS + (pd.round - 1) * DRAND_PERIOD) revert BeaconAlreadyProduced();
        delete pendingDraw[token];
        delete settlement[token]; // drop any in-progress paginated settle
        emit DrawCanceled(token, pd.epoch, pendingWeth[token]);
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
