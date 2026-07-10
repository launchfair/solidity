// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 — https://hood.launchfair.app
// Every token of this contract is launched exclusively through LaunchFair V2 at
// https://hood.launchfair.app (traceable on-chain via `website()` and the
// `platformWebsite` field). V2 adds token MODES on top of the base V3 launch:
//   Base       — plain fair launch (identical to V1).
//   Reward     — holders earn a dev-chosen external token, funded by LP fees.
//   Increasing — holders earn THIS token back (pro-rata), funded by LP fees.
//   Burn       — LP fees buy back and burn THIS token (deflationary).
// Rewards are CLAIMABLE (V3 can't rebase balances); a keeper batches the fee
// buybacks and funds the on-chain dividend tracker below.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @notice LaunchFair V2 token: base fair-launch mechanics plus an optional,
/// V3-safe dividend tracker (Reward/Increasing) or buyback-burn (Burn).
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
        Increasing, // 2 — distribute THIS token to holders (pro-rata)
        Burn // 3 — buy back and burn THIS token
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

    address public immutable launchpad;

    /// @notice The token's mode, fixed at creation.
    Mode public immutable mode;
    /// @notice For Reward mode, the external token holders earn. Zero otherwise.
    /// For Increasing mode the distributed asset is THIS token (address(this)).
    address public immutable rewardToken;
    /// @notice The reward token's WETH pool (Reward mode) — where the keeper
    /// buys the reward token. Validated by the launchpad at creation.
    address public immutable rewardPool;
    /// @notice This token's own WETH pool (buyback venue for Increasing/Burn).
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
    /// @notice Total THIS-token ever burned by the Burn mechanism.
    uint256 public totalBurned;

    event ExcludedFromDividends(address indexed account, bool excluded);
    event DividendsDistributed(uint256 amount);
    event DividendClaimed(address indexed account, uint256 amount);
    event MechanismBurn(uint256 amount);

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
    /// distributor knows where to buy back for Increasing/Burn.
    function setPool(address pool_) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (pool == address(0)) pool = pool_;
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

    /// @notice Burn `amount` of THIS token for the Burn mechanism (pulled from
    /// the caller — our keeper, after buying back with LP fees). Tracked
    /// separately from V3 sell-fee burns via `MechanismBurn`.
    function fundBurn(uint256 amount) external {
        if (mode != Mode.Burn) revert WrongMode();
        if (amount == 0) return;
        _burn(msg.sender, amount);
        totalBurned += amount;
        emit MechanismBurn(amount);
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

    // ── ERC-7572 contract metadata (with mode/version + site) ────────────────
    function contractURI() external view returns (string memory) {
        string memory link = bytes(website).length > 0 ? website : platformWebsite;
        string memory json = string.concat(
            '{"name":"',
            name(),
            '","symbol":"',
            symbol(),
            '","image":"',
            logoURI,
            '","external_link":"',
            link,
            '","extensions":{"website":"',
            website,
            '","telegram":"',
            telegram,
            '","discord":"',
            discord,
            '","x":"',
            twitter,
            '","platform_website":"',
            platformWebsite,
            '","launchfair_version":"',
            VERSION,
            '"}}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
