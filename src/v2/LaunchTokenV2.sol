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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice LaunchFair V2 token: base fair-launch mechanics plus an optional,
/// V4-safe dividend tracker (Reward/Increasing) or a lottery.
contract LaunchTokenV2 is ERC20Burnable, ReentrancyGuard {
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
    error BadRewardConfig();
    error NotRewardAsset();

    address public immutable launchpad;

    /// @notice The token's mode, fixed at creation.
    Mode public immutable mode;
    /// @notice Lottery mode: the optional prize token bought with the pot (0 = WETH
    /// pot). NOT a dividend asset — the Reward/Increasing distribution assets are in
    /// `rewardTokens` below.
    address public immutable prizeToken;
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

    // ── multi-asset dividend tracker (Reward & Increasing) ────────────────────
    // Magnified-dividend-per-share accounting, PER reward asset. `share` == a
    // holder's balance (shared across all reward assets), excluding protocol
    // plumbing. Updating shares on transfer never changes amounts, so the pool is
    // unaffected. Reward mode distributes up to MAX_REWARDS dev-chosen tokens in
    // parallel, each with its own per-share tracker; Increasing distributes THIS
    // token (a single asset = address(this)).
    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint8 public constant MAX_REWARDS = 5;

    /// @notice The distribution assets holders earn. Increasing: [address(this)].
    /// Reward: the dev's 1..MAX_REWARDS tokens. Base/Lottery: empty.
    address[] public rewardTokens;
    /// @notice Dev fee allocation per reward asset, in bps (sum == 10000). Fixed at
    /// creation. For Increasing the single asset carries 10000.
    mapping(address asset => uint16) public rewardWeightBps;
    /// @notice Whether an address is one of this token's reward assets.
    mapping(address asset => bool) public isRewardAsset;

    // Per-asset accounting; `shareOf`/`totalShares` are shared across assets.
    mapping(address asset => uint256) internal magnifiedDividendPerShare;
    mapping(address asset => mapping(address holder => int256)) internal magnifiedCorrections;
    mapping(address asset => mapping(address holder => uint256)) internal withdrawnDividends;
    /// @notice Total of each asset ever distributed to holders.
    mapping(address asset => uint256) public totalDistributedOf;

    mapping(address => uint256) internal shareOf;
    uint256 public totalShares;

    /// @notice Excluded from dividends (does not accrue as a holder).
    mapping(address => bool) public excludedFromDividends;
    /// @notice Increasing mode only: THIS-token held by the contract as the
    /// un-realized reflection pool. It's netted out of `balanceOf(this)` so the
    /// accrued-but-unrealized amount isn't double-counted (Σ balanceOf <= supply).
    uint256 internal _reflectionHeld;

    event ExcludedFromDividends(address indexed account, bool excluded);
    event DividendsDistributed(address indexed asset, uint256 amount);
    event DividendClaimed(address indexed account, address indexed asset, uint256 amount);
    event RewardTokensSet(address[] assets, uint16[] weightsBps);

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
        address[] memory rewardTokens_, // Reward: 1..MAX_REWARDS dividend assets
        uint16[] memory rewardWeights_, // Reward: bps per asset (sum == 10000)
        address prizeToken_, // Lottery: optional prize (0 = WETH pot)
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
        prizeToken = prizeToken_;
        minHoldForRewards = minHoldForRewards_;

        // Set up the distribution assets + their fee weights.
        if (mode_ == Mode.Increasing) {
            // Auto-compound: the single asset is THIS token, 100% of the fee.
            _addRewardAsset(address(this), 10_000);
        } else if (mode_ == Mode.Reward) {
            uint256 n = rewardTokens_.length;
            if (n == 0 || n > MAX_REWARDS || rewardWeights_.length != n) revert BadRewardConfig();
            uint256 sum;
            for (uint256 i; i < n; i++) {
                _addRewardAsset(rewardTokens_[i], rewardWeights_[i]);
                sum += rewardWeights_[i];
            }
            if (sum != 10_000) revert BadRewardConfig();
            emit RewardTokensSet(rewardTokens_, rewardWeights_);
        }
        // Base / Lottery: no dividend assets.

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

    /// @dev Register a distribution asset with its fee weight (bps). Distinct, non-zero.
    function _addRewardAsset(address asset, uint16 weight) internal {
        if (asset == address(0) || isRewardAsset[asset] || weight == 0) revert BadRewardConfig();
        isRewardAsset[asset] = true;
        rewardWeightBps[asset] = weight;
        rewardTokens.push(asset);
    }

    /// @notice The distribution assets holders earn (Reward: 1..5; Increasing: [this]).
    function rewardTokensList() external view returns (address[] memory) {
        return rewardTokens;
    }

    /// @notice Number of distribution assets.
    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
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
        // Launch guard: cap non-exempt wallets during the launch window (raw balance).
        if (limitActive() && to != address(0) && !limitExempt[to] && super.balanceOf(to) + value > maxWalletAmount) {
            revert MaxBuyExceeded();
        }

        // Increasing (auto-compound): realize the sender's accrued reflection into
        // its real balance first, so its full (grown) balanceOf is transferable and
        // the reward compounds into the share it keeps.
        if (mode == Mode.Increasing && from != address(0) && !excludedFromDividends[from]) {
            _realize(from);
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
            // `buySource != 0` so the constructor mint (from == 0 == unset buySource) can
            // never mint tickets before the pool is wired.
            if (from == buySource && buySource != address(0)) {
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

    // ── dividend accounting (multi-asset) ─────────────────────────────────────
    function _syncShare(address account) internal {
        // Share tracks the REALIZED (raw) balance; the pending reflection is derived
        // from it, so using the raw balance here avoids a circular definition.
        uint256 bal = super.balanceOf(account);
        // Below the dev-set minimum (or excluded) → no share, earns nothing.
        uint256 newShare = (excludedFromDividends[account] || bal < minHoldForRewards) ? 0 : bal;
        uint256 old = shareOf[account];
        if (newShare == old) return;
        // Update the correction for EVERY reward asset (so the holder's accrued amount
        // of each is preserved across the share change).
        address[] memory assets = rewardTokens;
        if (newShare > old) {
            uint256 add = newShare - old;
            totalShares += add;
            for (uint256 i; i < assets.length; i++) {
                magnifiedCorrections[assets[i]][account] -= int256(magnifiedDividendPerShare[assets[i]] * add);
            }
        } else {
            uint256 sub = old - newShare;
            totalShares -= sub;
            for (uint256 i; i < assets.length; i++) {
                magnifiedCorrections[assets[i]][account] += int256(magnifiedDividendPerShare[assets[i]] * sub);
            }
        }
        shareOf[account] = newShare;
    }

    /// @notice Fund holder rewards for a specific reward `asset`. Pulls `amount` of it
    /// from the caller and credits it pro-rata to holders. Permissionless — anyone
    /// (typically the keeper after a fee buyback) may fund; funding only ever *adds*
    /// claimable value. For Reward tokens the distributor calls this once per asset.
    function fundRewards(address asset, uint256 amount) external nonReentrant {
        if (!isRewardAsset[asset]) revert NotRewardAsset();
        if (amount == 0) return;
        // Credit the amount ACTUALLY received, so a fee-on-transfer / rebasing reward
        // token can't over-credit holders and strand the last claimers.
        IERC20 a = IERC20(asset);
        uint256 balBefore = a.balanceOf(address(this));
        a.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = a.balanceOf(address(this)) - balBefore;
        if (received == 0) return;
        // Re-read shares AFTER the transfer (Increasing: a non-excluded funder's own
        // share drops; a sole shareholder funding their whole balance would div-by-zero).
        uint256 shares = totalShares;
        if (shares == 0) revert NoShares();
        // Increasing: the pulled THIS-token is the reflection pool (netted out of
        // balanceOf(this)); holders' balances grow immediately, no push needed.
        if (asset == address(this)) _reflectionHeld += received;
        magnifiedDividendPerShare[asset] += (received * MAGNITUDE) / shares;
        totalDistributedOf[asset] += received;
        emit DividendsDistributed(asset, received);
    }

    function accumulativeDividendOf(address asset, address account) public view returns (uint256) {
        return uint256(int256(magnifiedDividendPerShare[asset] * shareOf[account]) + magnifiedCorrections[asset][account]) / MAGNITUDE;
    }

    /// @notice Amount of reward `asset` currently claimable by `account`.
    function withdrawableDividendOf(address asset, address account) public view returns (uint256) {
        return accumulativeDividendOf(asset, account) - withdrawnDividends[asset][account];
    }

    /// @notice Total claimable across all reward assets — a cheap "is anything owed"
    /// probe for the keeper (amounts are in mixed asset units; treat as a boolean-ish).
    function totalWithdrawableOf(address account) external view returns (uint256 total) {
        address[] memory assets = rewardTokens;
        for (uint256 i; i < assets.length; i++) {
            total += withdrawableDividendOf(assets[i], account);
        }
    }

    /// @notice ERC20 balance. For **Increasing** (auto-compounding) mode the accrued
    /// reflection is folded straight in — `balanceOf` grows on each buyback, no claim.
    /// The contract's own reflection pool is netted out so the accrued-but-unrealized
    /// tokens aren't double-counted (Σ balanceOf stays <= totalSupply); excluded/plumbing
    /// accounts (incl. the V4 pool) read their raw balance. Other modes are the plain
    /// ERC20 balance.
    function balanceOf(address account) public view override returns (uint256) {
        if (mode != Mode.Increasing) return super.balanceOf(account);
        if (account == address(this)) {
            uint256 raw = super.balanceOf(account);
            return raw > _reflectionHeld ? raw - _reflectionHeld : 0;
        }
        if (excludedFromDividends[account]) return super.balanceOf(account);
        return super.balanceOf(account) + withdrawableDividendOf(address(this), account);
    }

    /// @dev Increasing mode: fold `account`'s accrued reflection (of THIS token) into
    /// its real balance. Uses super._update so it doesn't re-enter this override; the
    /// caller syncs the share afterwards.
    function _realize(address account) internal {
        uint256 amount = withdrawableDividendOf(address(this), account);
        if (amount == 0) return;
        withdrawnDividends[address(this)][account] += amount;
        _reflectionHeld -= amount;
        super._update(address(this), account, amount);
        emit DividendClaimed(account, address(this), amount);
    }

    /// @notice Realize `account`'s accrued rewards. Permissionless and safe: only ever
    /// credits a holder their OWN owed amounts, bookkeeping updated before any transfer
    /// (CEI). **Reward** delivers each owed reward token to the wallet; **Increasing**
    /// folds the reflection into the balance. Returns the summed amount realized.
    function processAccount(address account) public returns (uint256 total) {
        if (mode == Mode.Increasing) {
            total = withdrawableDividendOf(address(this), account);
            if (total == 0) return 0;
            _realize(account);
            _syncShare(account); // the realize grew the raw balance; sync its share
            return total;
        }
        // Reward: pay out every owed reward asset.
        address[] memory assets = rewardTokens;
        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            uint256 amt = withdrawableDividendOf(asset, account);
            if (amt == 0) continue;
            withdrawnDividends[asset][account] += amt;
            IERC20(asset).safeTransfer(account, amt);
            emit DividendClaimed(account, asset, amt);
            total += amt;
        }
    }

    /// @notice Push payouts to a batch of holders — called by the keeper (with
    /// the holder list from the indexer) so rewards land in wallets AUTOMATICALLY,
    /// no claim required. Skips zero-owed accounts cheaply. Each account is wrapped in
    /// try/catch so one recipient whose reward-token transfer reverts (e.g. a blacklist)
    /// can't block the whole batch; that account can still `claim()` later.
    function processAccounts(address[] calldata accounts) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            try this.processAccount(accounts[i]) {} catch {}
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
