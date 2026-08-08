// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — Stock-Perps reward mode. See docs/PERPS_REWARD_MODE.md.

/// @notice The contract between the Perps reward mechanism and a stock-perp venue. The reward mode
/// treats a leveraged stock position as a **fungible ERC20 reward asset**: fees are deposited as
/// margin and the venue mints a per-`(market, side, leverage)` position token, which is distributed
/// to holders through the existing reward tracker — hands-off, exactly like any reward token. A
/// holder ends up with a real margined-position token in their wallet to hold, sell, or redeem for
/// its WETH value at NAV.
///
/// The VENUE owns the equity price oracle, liquidations, funding, margin accounting, solvency,
/// market-hours and the regulatory framing — the reward side assumes it is correct and solvent
/// (see the Risk section of the design doc).
interface IPerpsVenue {
    /// @notice ERC20 the venue takes as margin / pays out on redemption (WETH or a stablecoin).
    function marginToken() external view returns (address);

    /// @notice The fungible leveraged-position ERC20 for `(market, isLong, leverageBps)`. Deploys it
    /// on first call and is idempotent thereafter, so the launchpad can resolve + register it as a
    /// token's reward asset at launch (before any margin is deposited).
    function positionTokenFor(bytes32 market, bool isLong, uint16 leverageBps)
        external
        returns (address positionToken);

    /// @notice Deposit `margin` of `marginToken()` (caller must have approved it) into the pooled
    /// leveraged position for `(market, isLong, leverageBps)` and mint the corresponding position
    /// token to the caller. Returns the token and the shares minted.
    function open(bytes32 market, bool isLong, uint16 leverageBps, uint256 margin)
        external
        returns (address positionToken, uint256 shares);

    /// @notice Burn `shares` of `positionToken` from the caller and pay out their current WETH value
    /// (NAV). `minOut` guards slippage. Returns the amount paid.
    function redeem(address positionToken, uint256 shares, uint256 minOut) external returns (uint256 out);

    /// @notice NAV: the current WETH value of `shares` of `positionToken` (0 if the pool is
    /// liquidated / worthless).
    function shareValue(address positionToken, uint256 shares) external view returns (uint256 wethValue);

    /// @notice Market-hours gate — false when the underlying stock market is closed (or unlisted).
    function marketOpen(bytes32 market) external view returns (bool);
}
