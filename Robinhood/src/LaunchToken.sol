// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @notice ERC20 launched straight into a Uniswap V3 pool (noxa-style hybrid).
/// Freely transferable from creation — the pool IS the market from block one,
/// which is what makes the token visible to every DEX terminal without paid
/// data integrations. No owner, no mint, no fee knobs, no blacklist.
contract LaunchToken is ERC20Burnable {
    /// @notice Creator-supplied token metadata, immutable after creation.
    /// The launchpad validates every field (no quotes/backslashes/control
    /// chars) so these strings are safe to embed in `contractURI()` JSON.
    struct Metadata {
        string logoURI; // e.g. ipfs://<CID> — creator pins the image (Pinata etc.)
        string website;
        string telegram;
        string discord;
        string twitter; // X
    }

    error OnlyLaunchpad();
    error MaxBuyExceeded();

    address public immutable launchpad;

    /// @notice Anti-sniper launch guard: while `block.number < limitEndBlock`,
    /// no non-exempt wallet may hold more than `maxWalletAmount` (e.g. 2% of
    /// supply for the first 360 blocks). Fixed at creation, auto-expires, and
    /// nobody can extend, tighten, or re-enable it. Zero values = no limit.
    uint256 public immutable maxWalletAmount;
    uint256 public immutable limitEndBlock;

    /// @notice Protocol plumbing excluded from the launch guard (pool,
    /// position manager, fee locker, launchpad). Only set by the launchpad's
    /// immutable creation code.
    mapping(address => bool) public limitExempt;

    event LimitExemptSet(address indexed account, bool exempt);

    /// @notice Official website of the deploying platform, stamped at creation
    /// so explorers and trackers can attribute the token to its launchpad.
    string public platformWebsite;

    // Creator-supplied metadata (see Metadata struct).
    string public logoURI;
    string public website;
    string public telegram;
    string public discord;
    string public twitter;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        string memory platformWebsite_,
        Metadata memory meta,
        uint16 maxBuyBps_,
        uint32 maxBuyBlocks_
    ) ERC20(name_, symbol_) {
        launchpad = msg.sender;
        platformWebsite = platformWebsite_;
        logoURI = meta.logoURI;
        website = meta.website;
        telegram = meta.telegram;
        discord = meta.discord;
        twitter = meta.twitter;
        maxWalletAmount = maxBuyBps_ == 0 ? 0 : (supply_ * maxBuyBps_) / 10_000;
        limitEndBlock = maxBuyBlocks_ == 0 ? 0 : block.number + maxBuyBlocks_;
        limitExempt[msg.sender] = true;
        _mint(msg.sender, supply_);
    }

    /// @notice Explicit zero owner so explorers report the token as renounced.
    function owner() external pure returns (address) {
        return address(0);
    }

    /// @notice Whether the launch guard is currently enforced.
    function limitActive() public view returns (bool) {
        return maxWalletAmount != 0 && block.number < limitEndBlock;
    }

    /// @notice Launchpad-only; called during token creation to exempt the
    /// pool, position manager, and fee locker.
    function setLimitExempt(address account, bool exempt) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        limitExempt[account] = exempt;
        emit LimitExemptSet(account, exempt);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Launch guard: cap non-exempt wallet balances during the first blocks
        // after launch. Sells always work (the pool is exempt); burns too.
        if (limitActive() && to != address(0) && !limitExempt[to] && balanceOf(to) + value > maxWalletAmount) {
            revert MaxBuyExceeded();
        }
        super._update(from, to, value);
    }

    /// @notice ERC-7572 contract-level metadata, built fully on-chain.
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
            '"}}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
