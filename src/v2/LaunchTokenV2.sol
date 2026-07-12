// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 — https://hood.launchfair.app
// Every token of this contract is launched exclusively through LaunchFair V2 at
// https://hood.launchfair.app (traceable on-chain via `website()` and the
// `platformWebsite` field). V2 adds token MODES on top of the base V3 launch:
//   Base       — plain fair launch (identical to V1).
//   Reward     — holders earn a dev-chosen external token, funded by LP fees.
//   Increasing — holders earn THIS token back (pro-rata), funded by LP fees.
//   Lottery    — buys earn tickets; a random holder wins the accrued pot.
// A keeper batches the fee buybacks and funds the on-chain dividend tracker below.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice LaunchFair V2 token: base fair-launch mechanics plus an optional,
/// V4-safe dividend tracker (Reward/Increasing) or a lottery.
contract LaunchTokenV2 is ERC20Burnable {
    using SafeERC20 for IERC20;

    /// @notice Human-readable version tag so explorers/terminals attribute the
    /// token (and its trades) to us.
    string public constant VERSION = "LaunchFair V2";
    /// @notice Canonical site — surfaced for scrapers that read a `website()`.
    string public constant SITE = "https://hood.launchfair.app";

    enum Mode {
        Base, // 0 — plain fair launch
        Reward, // 1 — distribute an external reward token to holders
        Increasing, // 2 — auto-compounding: distribute THIS token to holders (balance grows)
        Lottery // 3 — buys earn tickets (lost on sell); a random holder takes the pot
    }

    struct Metadata {
        string logoURI;
        string website;
        string telegram;
        string discord;
        string twitter;
    }

    error OnlyLaunchpad();
    error MaxBuyExceeded();
    error WrongMode();
    error NoShares();
    error NotAuthorized();

    address public immutable launchpad;

    /// @notice The token's mode, fixed at creation.
    Mode public immutable mode;
    /// @notice For Reward mode, the external token holders earn. Zero otherwise.
    /// For Increasing mode the distributed asset is THIS token (address(this)).
    address public immutable rewardToken;
    /// @notice The reward token's WETH pool (Reward mode) — where the keeper
    /// buys the reward token. Validated by the launchpad at creation.
    address public immutable rewardPool;
    /// @notice This token's own WETH pool (buyback venue for Increasing).
    /// Set once by the launchpad right after the pool is created.
    address public pool;
    /// @notice Minimum balance a holder must keep to earn rewards (dev-set at
    /// creation; 0 = no minimum). Below it an account accrues nothing until it
    /// tops back up — keeps dust wallets out and cheapens the keeper's pushes.
    uint256 public immutable minHoldForRewards;

    // ── launch guard (unchanged from V1) ─────────────────────────────────────
    uint256 public immutable maxWalletAmount;
    uint256 public immutable limitEndBlock;
    mapping(address => bool) public limitExempt;
    event LimitExemptSet(address indexed account, bool exempt);

    // ── creator/platform metadata ────────────────────────────────────────────
    string public platformWebsite;
    string public logoURI;
    string public website;
    string public telegram;
    string public discord;
    string public twitter;

    // ── dividend tracker (Reward & Increasing) ───────────────────────────────
    // Magnified-dividend-per-share accounting. `share` == a holder's balance,
    // excluding protocol plumbing (pool, position manager, locker, launchpad,
    // distributor, this contract). Updating shares on transfer never changes
    // amounts, so the V3 pool is unaffected.
    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedCorrections;
    mapping(address => uint256) internal withdrawnDividends;
    mapping(address => uint256) internal shareOf;
    uint256 public totalShares;

    /// @notice Excluded from dividends (does not accrue as a holder).
    mapping(address => bool) public excludedFromDividends;
    /// @notice Total distribution-asset ever distributed to holders.
    uint256 public totalDistributed;

    event ExcludedFromDividends(address indexed account, bool excluded);
    event DividendsDistributed(uint256 amount);
    event DividendClaimed(address indexed account, uint256 amount);

    // ── lottery (Mode.Lottery) ───────────────────────────────────────────────
    /// @notice The pool tokens are bought from — a transfer FROM here to a real
    /// wallet is a "buy" that earns lottery tickets. Set once by the launchpad.
    address public buySource;
    /// @notice The lottery distributor allowed to close a session after a draw.
    address public lotteryOperator;
    /// @notice Current lottery session. Tickets reset each draw via a fresh epoch.
    uint256 public lotteryEpoch;
    /// @notice tickets[epoch][holder] — tokens the holder BOUGHT this session and
    /// STILL HOLDS. Buys add tickets; any move out (sell/transfer/burn) removes
    /// them, so selling drops your odds to zero and a buy→sell round-trip nets none.
    mapping(uint256 => mapping(address => uint256)) public ticketsOf;
    /// @notice Total tickets in a session (the odds denominator).
    mapping(uint256 => uint256) public totalTickets;

    event TicketsChanged(uint256 indexed epoch, address indexed holder, uint256 newTickets);
    event LotterySessionAdvanced(uint256 indexed closedEpoch, uint256 newEpoch);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        string memory platformWebsite_,
        Metadata memory meta,
        uint16 maxBuyBps_,
        uint32 maxBuyBlocks_,
        Mode mode_,
        address rewardToken_,
        address rewardPool_,
        uint256 minHoldForRewards_,
        address launchpad_
    ) ERC20(name_, symbol_) {
        launchpad = launchpad_;
        platformWebsite = platformWebsite_;
        logoURI = meta.logoURI;
        website = meta.website;
        telegram = meta.telegram;
        discord = meta.discord;
        twitter = meta.twitter;
        maxWalletAmount = maxBuyBps_ == 0 ? 0 : (supply_ * maxBuyBps_) / 10_000;
        limitEndBlock = maxBuyBlocks_ == 0 ? 0 : block.number + maxBuyBlocks_;
        mode = mode_;
        rewardToken = rewardToken_;
        rewardPool = rewardPool_;
        minHoldForRewards = minHoldForRewards_;

        // Plumbing never earns dividends. The launchpad (msg.sender) holds the
        // full supply only momentarily before it goes into the pool; pool / PM /
        // locker / distributor are excluded by the launchpad post-creation via
        // excludeFromDividends().
        excludedFromDividends[address(this)] = true;
        excludedFromDividends[address(0)] = true;
        excludedFromDividends[launchpad_] = true;
        limitExempt[launchpad_] = true;

        _mint(launchpad_, supply_);
    }

    /// @notice Explicit zero owner so explorers report the token as renounced.
    function owner() external pure returns (address) {
        return address(0);
    }

    /// @notice Canonical site, exposed as a top-level getter for DEX terminals.
    function url() external pure returns (string memory) {
        return SITE;
    }

    // ── launch guard ─────────────────────────────────────────────────────────
    function limitActive() public view returns (bool) {
        return maxWalletAmount != 0 && block.number < limitEndBlock;
    }

    function setLimitExempt(address account, bool exempt) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        limitExempt[account] = exempt;
        emit LimitExemptSet(account, exempt);
    }

    /// @notice Launchpad-only; records this token's own WETH pool (once) so the
    /// distributor knows where to buy back for Increasing.
    function setPool(address pool_) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (pool == address(0)) pool = pool_;
    }

    /// @notice Launchpad-only (once): the pool address a buy comes FROM, so the
    /// token can credit lottery tickets on buys.
    function setBuySource(address src) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (buySource == address(0)) buySource = src;
    }

    /// @notice Launchpad-only (once): the lottery distributor allowed to close a
    /// session after settling a draw.
    function setLotteryOperator(address op) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (lotteryOperator == address(0)) lotteryOperator = op;
    }

    /// @notice Close the current lottery session and start a fresh one (tickets
    /// reset). Called by the lottery distributor immediately after a draw is
    /// settled, so the winner is picked from the just-closed session.
    function advanceLotteryEpoch() external returns (uint256 closed) {
        if (msg.sender != lotteryOperator) revert NotAuthorized();
        closed = lotteryEpoch;
        lotteryEpoch = closed + 1;
        emit LotterySessionAdvanced(closed, lotteryEpoch);
    }

    /// @notice Launchpad-only; exclude protocol plumbing from dividends.
    function excludeFromDividends(address account, bool excluded) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (excludedFromDividends[account] == excluded) return;
        excludedFromDividends[account] = excluded;
        _syncShare(account);
        emit ExcludedFromDividends(account, excluded);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Launch guard: cap non-exempt wallets during the launch window.
        if (limitActive() && to != address(0) && !limitExempt[to] && balanceOf(to) + value > maxWalletAmount) {
            revert MaxBuyExceeded();
        }
        super._update(from, to, value);

        // Keep dividend shares in sync (only matters for reward-bearing modes).
        if (mode == Mode.Reward || mode == Mode.Increasing) {
            if (from != address(0)) _syncShare(from);
            if (to != address(0)) _syncShare(to);
        }

        // Lottery tickets track tokens BOUGHT this session and STILL HELD:
        //   • a buy (tokens leaving the pool to a wallet) ADDS tickets;
        //   • any move OUT of a wallet — sell (to the pool), transfer, or burn —
        //     REMOVES tickets (down to zero).
        // So selling drops your odds to zero, a buy→sell round-trip nets nothing,
        // and moving tokens to another wallet can't launder tickets (the receiver
        // only earns tickets by buying from the pool). Tickets are per-session and
        // reset when the draw advances the epoch.
        if (mode == Mode.Lottery && value > 0) {
            uint256 e = lotteryEpoch;
            if (from == buySource) {
                if (to != address(0) && !excludedFromDividends[to]) {
                    uint256 nt = ticketsOf[e][to] + value;
                    ticketsOf[e][to] = nt;
                    totalTickets[e] += value;
                    emit TicketsChanged(e, to, nt);
                }
            } else if (from != address(0)) {
                uint256 held = ticketsOf[e][from];
                if (held > 0) {
                    uint256 cut = value < held ? value : held;
                    uint256 nt = held - cut;
                    ticketsOf[e][from] = nt;
                    totalTickets[e] -= cut;
                    emit TicketsChanged(e, from, nt);
                }
            }
        }
    }

    // ── dividend accounting ──────────────────────────────────────────────────
    function _syncShare(address account) internal {
        uint256 bal = balanceOf(account);
        // Below the dev-set minimum (or excluded) → no share, earns nothing.
        uint256 newShare = (excludedFromDividends[account] || bal < minHoldForRewards) ? 0 : bal;
        uint256 old = shareOf[account];
        if (newShare == old) return;
        if (newShare > old) {
            uint256 add = newShare - old;
            totalShares += add;
            magnifiedCorrections[account] -= int256(magnifiedDividendPerShare * add);
        } else {
            uint256 sub = old - newShare;
            totalShares -= sub;
            magnifiedCorrections[account] += int256(magnifiedDividendPerShare * sub);
        }
        shareOf[account] = newShare;
    }

    /// @notice The asset holders receive: the reward token (Reward) or THIS
    /// token (Increasing).
    function distributionAsset() public view returns (address) {
        return mode == Mode.Reward ? rewardToken : address(this);
    }

    /// @notice Fund holder rewards (Reward/Increasing). Pulls `amount` of the
    /// distribution asset from the caller and credits it pro-rata to holders.
    /// Permissionless — anyone (typically our keeper after a fee buyback) may
    /// fund; funding only ever *adds* claimable value to holders.
    function fundRewards(uint256 amount) external {
        if (mode != Mode.Reward && mode != Mode.Increasing) revert WrongMode();
        if (totalShares == 0) revert NoShares();
        if (amount == 0) return;
        IERC20(distributionAsset()).safeTransferFrom(msg.sender, address(this), amount);
        magnifiedDividendPerShare += (amount * MAGNITUDE) / totalShares;
        totalDistributed += amount;
        emit DividendsDistributed(amount);
    }

    function accumulativeDividendOf(address account) public view returns (uint256) {
        return uint256(int256(magnifiedDividendPerShare * shareOf[account]) + magnifiedCorrections[account]) / MAGNITUDE;
    }

    /// @notice Distribution asset currently claimable by `account`.
    function withdrawableDividendOf(address account) public view returns (uint256) {
        return accumulativeDividendOf(account) - withdrawnDividends[account];
    }

    /// @notice Pay out `account`'s accrued rewards TO `account`. Permissionless
    /// and safe: it only ever sends a holder their OWN owed rewards, and the
    /// bookkeeping is updated before the transfer (CEI), so it can't double-pay.
    /// This is what makes rewards automatic — our keeper pushes payouts so
    /// holders never have to claim. Returns the amount paid.
    function processAccount(address account) public returns (uint256 amount) {
        amount = withdrawableDividendOf(account);
        if (amount == 0) return 0;
        withdrawnDividends[account] += amount;
        IERC20(distributionAsset()).safeTransfer(account, amount);
        emit DividendClaimed(account, amount);
    }

    /// @notice Push payouts to a batch of holders — called by the keeper (with
    /// the holder list from the indexer) so rewards land in wallets AUTOMATICALLY,
    /// no claim required. Skips zero-owed accounts cheaply.
    function processAccounts(address[] calldata accounts) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            processAccount(accounts[i]);
        }
    }

    /// @notice Self-service claim — a trustless fallback if you'd rather not wait
    /// for the automatic keeper push (or if the keeper is ever down).
    function claim() external returns (uint256) {
        return processAccount(msg.sender);
    }

    /// @notice ERC-7572 contract metadata as a PLAIN, bot-readable https URL — no
    /// base64 to decode. Points at the token's page on the platform
    /// (`<platformWebsite>/token/<address>`), which carries Open Graph
    /// name/image/description tags. Every field (name/symbol/socials/
    /// platformWebsite) is ALSO a plain public getter, so bots can read everything
    /// directly on-chain without even fetching the URL.
    function contractURI() external view returns (string memory) {
        return string.concat(platformWebsite, "/token/", Strings.toHexString(uint256(uint160(address(this))), 20));
    }

    /// @notice The platform's site — a plain getter for bots/terminals.
    function platformSite() external view returns (string memory) {
        return platformWebsite;
    }
}
