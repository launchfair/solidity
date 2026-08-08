// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Per-season Merkle distributor for the LaunchFair flagship flywheel.
/// Each weekly "season" the buyback keeper funds the season with the flagship it
/// bought and publishes a Merkle root of (index, account, amount) leaves — each
/// wallet's cut, pro-rata by season points. Users CLAIM directly with a proof; the
/// backend is never in the claim path.
///
/// Leaves are OpenZeppelin StandardMerkleTree-compatible:
///   leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))
/// so the off-chain builder can use the openzeppelin/merkle-tree JS library.
///
/// Safety model:
///   - Prefer `fundAndPublish` (keeper's path): funding + root are ONE atomic tx, so
///     there is never a funded-but-unrooted window, and a retry reverts on set-once —
///     no double-funding.
///   - Each season's total payout is hard-capped at the published `seasonTotal` (which
///     is itself ≤ `deposited`), so even a bad/over-allocated root can never pay out
///     more than intended, nor reach another season.
///   - `fundSeason` measures the actual balance delta (fee-on-transfer / rebasing safe).
///   - Recoverability ("nothing frozen"): the owner can rescue funds — but ONLY to the
///     immutable `treasury` (no setter, so a leaked owner key cannot redirect them) —
///     roll a stale season's unclaimed balance into a future (unpublished) season, or
///     override a root BEFORE any claim. NOTE: the owner is still a fully-trusted role
///     (it can rescue all undistributed funds); this is transparent + admin-recoverable,
///     NOT trustless.
contract SeasonMerkleDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The platform (flagship) token distributed to season participants.
    IERC20 public immutable flagship;
    /// @notice Immutable safe rescue destination — set once at deploy, no setter, so
    /// rescued funds can ONLY ever reach this address (a leaked owner key can't redirect).
    address public immutable treasury;
    /// @notice The only address allowed to publish roots in the normal flow.
    address public rootPublisher;

    mapping(uint256 season => bytes32) public root; // 0 => not published yet
    mapping(uint256 season => uint256) public deposited; // flagship funded for the season
    mapping(uint256 season => uint256) public seasonTotal; // Σ leaf allocations of the published root
    mapping(uint256 season => uint256) public claimed; // flagship claimed so far
    mapping(uint256 season => bool) public frozen; // rolled-away seasons can't be claimed
    mapping(uint256 season => mapping(uint256 word => uint256)) private claimedBitMap;

    error NotPublisher();
    error RootAlreadySet();
    error RootNotSet();
    error ZeroRoot();
    error ZeroAmount();
    error ExceedsTotal();
    error ExceedsDeposit();
    error AlreadyClaimed();
    error ClaimsStarted();
    error InvalidProof();
    error SeasonFrozen();
    error SameSeason();
    error ZeroAddress();

    event RootPublisherSet(address indexed rootPublisher);
    event SeasonFunded(uint256 indexed season, address indexed from, uint256 amount);
    event SeasonRootSet(uint256 indexed season, bytes32 root, uint256 total);
    event RootOverridden(uint256 indexed season, bytes32 root, uint256 total);
    event Claimed(uint256 indexed season, uint256 index, address indexed account, uint256 amount);
    event RolledUnclaimed(uint256 indexed fromSeason, uint256 indexed toSeason, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyRootPublisher() {
        if (msg.sender != rootPublisher) revert NotPublisher();
        _;
    }

    constructor(address owner_, IERC20 flagship_, address treasury_, address rootPublisher_) Ownable(owner_) {
        if (address(flagship_) == address(0) || treasury_ == address(0) || rootPublisher_ == address(0)) {
            revert ZeroAddress();
        }
        flagship = flagship_;
        treasury = treasury_;
        rootPublisher = rootPublisher_;
    }

    // ── admin wiring ──────────────────────────────────────────────────────────
    /// @notice Rotate the single root publisher (owner-only).
    function setRootPublisher(address publisher) external onlyOwner {
        if (publisher == address(0)) revert ZeroAddress();
        rootPublisher = publisher;
        emit RootPublisherSet(publisher);
    }

    // ── funding + roots ─────────────────────────────────────────────────────────
    /// @dev Pull `amount` flagship and credit the ACTUAL received delta (fee-on-transfer
    /// / rebasing safe), so `deposited` never overstates the real balance.
    function _pull(uint256 season, uint256 amount) private returns (uint256 credited) {
        if (amount == 0) return 0;
        uint256 pre = flagship.balanceOf(address(this));
        flagship.safeTransferFrom(msg.sender, address(this), amount);
        credited = flagship.balanceOf(address(this)) - pre;
        deposited[season] += credited;
        emit SeasonFunded(season, msg.sender, credited);
    }

    function _setRoot(uint256 season, bytes32 merkleRoot, uint256 total) private {
        if (merkleRoot == bytes32(0)) revert ZeroRoot(); // a 0 root would leave the season re-publishable
        if (root[season] != bytes32(0)) revert RootAlreadySet();
        if (total > deposited[season]) revert ExceedsDeposit();
        root[season] = merkleRoot;
        seasonTotal[season] = total;
        emit SeasonRootSet(season, merkleRoot, total);
    }

    /// @notice Add flagship to a season's pool. Restricted to the publisher so no one can
    /// inflate an arbitrary season's `deposited` (the keeper funds via `fundAndPublish`).
    function fundSeason(uint256 season, uint256 amount) external onlyRootPublisher nonReentrant {
        _pull(season, amount);
    }

    /// @notice Publish a season's Merkle root (single-publisher, set-once, capped at funded).
    function setSeasonRoot(uint256 season, bytes32 merkleRoot, uint256 total) external onlyRootPublisher {
        _setRoot(season, merkleRoot, total);
    }

    /// @notice Atomic fund + publish — the keeper's primary path. No funded-but-unrooted
    /// window (so a compromised publisher can't grab a "funded-but-open" season), and a
    /// retry after success reverts on set-once (no double-funding).
    function fundAndPublish(uint256 season, uint256 amount, bytes32 merkleRoot, uint256 total)
        external
        onlyRootPublisher
        nonReentrant
    {
        _pull(season, amount);
        _setRoot(season, merkleRoot, total);
    }

    // ── claim ────────────────────────────────────────────────────────────────────
    function isClaimed(uint256 season, uint256 index) public view returns (bool) {
        return (claimedBitMap[season][index / 256] & (uint256(1) << (index % 256))) != 0;
    }

    function _setClaimed(uint256 season, uint256 index) private {
        claimedBitMap[season][index / 256] |= (uint256(1) << (index % 256));
    }

    /// @notice Claim a season allocation. Permissionless (the proof authorizes); the
    /// flagship always goes to `account`.
    function claim(uint256 season, uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        if (frozen[season]) revert SeasonFrozen();
        bytes32 r = root[season];
        if (r == bytes32(0)) revert RootNotSet();
        if (isClaimed(season, index)) revert AlreadyClaimed();
        if (amount == 0) revert ZeroAmount(); // a 0-amount claim would set a bit without moving `claimed`

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        if (!MerkleProof.verifyCalldata(proof, r, leaf)) revert InvalidProof();

        // Hard cap at the published total — a bad/over-allocated root can never pay out
        // more than was committed, so it can't drain dust / rolled-in / other seasons.
        if (claimed[season] + amount > seasonTotal[season]) revert ExceedsTotal();

        _setClaimed(season, index);
        claimed[season] += amount;
        flagship.safeTransfer(account, amount);
        emit Claimed(season, index, account, amount);
    }

    // ── admin recovery ────────────────────────────────────────────────────────────
    /// @notice Rescue tokens to the immutable `treasury` ONLY. There is no destination
    /// argument and no `setTreasury`, so a leaked owner key cannot redirect rescued funds.
    function rescueTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(treasury, amount);
        emit Rescued(token, treasury, amount);
    }

    /// @notice Move a stale season's remaining (unclaimed) allocation into another,
    /// NOT-yet-published season and FREEZE the source. The keeper then publishes the
    /// destination against its (now larger) `deposited`, so the rolled funds are
    /// redistributed rather than stranded.
    function rollUnclaimed(uint256 fromSeason, uint256 toSeason) external onlyOwner {
        if (fromSeason == toSeason) revert SameSeason();
        if (frozen[fromSeason] || frozen[toSeason]) revert SeasonFrozen();
        if (root[toSeason] != bytes32(0)) revert RootAlreadySet(); // dest must be unpublished
        uint256 remaining = deposited[fromSeason] - claimed[fromSeason];
        frozen[fromSeason] = true;
        deposited[fromSeason] = claimed[fromSeason];
        deposited[toSeason] += remaining;
        emit RolledUnclaimed(fromSeason, toSeason, remaining);
    }

    /// @notice Emergency override of a mis-published root — allowed ONLY before any claim
    /// on that season (so it can't double-pay or brick claimants via the persisted
    /// bitmap). Emits a distinct event for auditability.
    function adminSetRoot(uint256 season, bytes32 merkleRoot, uint256 total) external onlyOwner {
        if (merkleRoot == bytes32(0)) revert ZeroRoot();
        if (claimed[season] != 0) revert ClaimsStarted();
        if (total > deposited[season]) revert ExceedsDeposit();
        root[season] = merkleRoot;
        seasonTotal[season] = total;
        emit RootOverridden(season, merkleRoot, total);
    }
}
