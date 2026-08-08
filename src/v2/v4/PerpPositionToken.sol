// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — Stock-Perps reward mode. See docs/PERPS_REWARD_MODE.md.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A fungible leveraged-position share token for one `(market, isLong, leverageBps)` on the
/// venue. Minted/burned only by the venue; each share is a pro-rata claim on the pooled leveraged
/// position's WETH value (NAV). Holders can hold it, transfer/sell it, or redeem it for WETH at NAV
/// **on the venue** (`IPerpsVenue.redeem`). This is the actual margined position that lands in a
/// reward recipient's wallet — no per-holder position management, fully fungible.
contract PerpPositionToken is ERC20 {
    address public immutable venue;
    bytes32 public immutable market;
    bool public immutable isLong;
    uint16 public immutable leverageBps;

    error OnlyVenue();

    modifier onlyVenue() {
        if (msg.sender != venue) revert OnlyVenue();
        _;
    }

    constructor(string memory name_, string memory symbol_, bytes32 market_, bool isLong_, uint16 leverageBps_)
        ERC20(name_, symbol_)
    {
        venue = msg.sender;
        market = market_;
        isLong = isLong_;
        leverageBps = leverageBps_;
    }

    function mint(address to, uint256 amount) external onlyVenue {
        _mint(to, amount);
    }

    /// @dev Burns from `from` — only ever called by the venue with `from == msg.sender` of a redeem,
    /// so a holder only ever burns their own shares (no third-party burn).
    function burn(address from, uint256 amount) external onlyVenue {
        _burn(from, amount);
    }
}
