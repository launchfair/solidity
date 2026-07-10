// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — https://hood.launchfair.app

/// @notice The 3 custom fee types for V4 mode tokens and how the collected fee
/// (always converted to WETH first) is split. By rule treasury == dev and BOTH
/// are paid in WETH; the remainder funds the reward/burn mechanism. Higher fee
/// tiers hand holders a bigger share.
///
///   pool fee   dev     treasury   rewards   (as % of the trade)
///   3%         0.5%    0.5%       2.0%
///   5%         0.75%   0.75%      3.5%
///   10%        1.0%    1.0%       8.0%
///
/// Stored as per-side bps OF THE COLLECTED FEE (treasury == dev == side):
///   3%  -> 1667  (16.67% of the 3% fee  = 0.5%  of the trade)
///   5%  -> 1500  (15%    of the 5% fee  = 0.75% of the trade)
///   10% -> 1000  (10%    of the 10% fee = 1%    of the trade)
/// Owner-adjustable per type; the mechanism always keeps >= 20%.
abstract contract FeeSplitConfig {
    uint16 internal constant BPS = 10_000;

    // The three supported V4 pool fees (uint24, Uniswap fee units = 1e-6).
    uint24 public constant FEE_3PCT = 30_000;
    uint24 public constant FEE_5PCT = 50_000;
    uint24 public constant FEE_10PCT = 100_000;

    /// @notice Per-side share (treasury == dev) of the collected fee, per tier.
    mapping(uint24 => uint16) public sideBps;

    error UnsupportedFee();
    error InvalidSplit();

    event SideBpsSet(uint24 indexed fee, uint16 sideBps);

    constructor() {
        sideBps[FEE_3PCT] = 1_667; // 0.5% of the trade
        sideBps[FEE_5PCT] = 1_500; // 0.75%
        sideBps[FEE_10PCT] = 1_000; // 1%
    }

    function isSupportedFee(uint24 fee) public pure returns (bool) {
        return fee == FEE_3PCT || fee == FEE_5PCT || fee == FEE_10PCT;
    }

    /// @dev treasury == dev == `side`; the mechanism keeps the rest (>= 20%).
    function _setSideBps(uint24 fee, uint16 side) internal {
        if (!isSupportedFee(fee)) revert UnsupportedFee();
        if (uint256(side) * 2 > 8_000) revert InvalidSplit();
        sideBps[fee] = side;
        emit SideBpsSet(fee, side);
    }

    /// @notice Split a WETH `amount` for a `fee`-tier pool. treasury ALWAYS
    /// equals dev; mechanism gets the remainder.
    function splitOf(uint24 fee, uint256 amount)
        public
        view
        returns (uint256 treasury, uint256 dev, uint256 mechanism)
    {
        if (!isSupportedFee(fee)) revert UnsupportedFee();
        treasury = (amount * sideBps[fee]) / BPS;
        dev = treasury; // treasury is always equal to dev
        mechanism = amount - treasury - dev;
    }
}
