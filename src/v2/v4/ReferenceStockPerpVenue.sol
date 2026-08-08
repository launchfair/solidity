// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 (V4) — Stock-Perps reward mode. See docs/PERPS_REWARD_MODE.md + AUDIT_PERPS_MODE.md.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IPerpsVenue} from "./IPerpsVenue.sol";
import {PerpPositionToken} from "./PerpPositionToken.sol";

/// @notice A **reference** stock-perp venue implementing `IPerpsVenue`: margin in WETH, an
/// operator-set equity oracle + market-hours, one pooled leveraged position per
/// `(market, isLong, leverageBps)`, and a fungible share token (`PerpPositionToken`) minted at NAV.
/// A holder who receives shares owns a real margined-position token they can hold, sell, or redeem
/// for WETH at NAV. Positive PnL on redemption is paid from a segregated **house** balance.
///
/// NOT PRODUCTION / NOT AUDITED as a venue. A real venue MUST replace the operator-set oracle with a
/// genuine push oracle (Chainlink/Pyth) + staleness/deviation guards and add funding + liquidation
/// keepers — the operator here can set marks arbitrarily (documented trust boundary). This reference
/// has been hardened per AUDIT_PERPS_MODE.md so it can be safely exercised on a testnet/staging:
///   - `open` is gated to authorized depositors (the fee distributor), so the oracle-latency
///     "free option" can't be farmed by arbitrary MEV (audit HIGH-1). `redeem` stays open (holders).
///   - PnL is paid from a **segregated `houseBalance`**, never another pool's collateral: a
///     profitable redeem that would exceed the house reverts `InsufficientHouse` (audit HIGH-2) —
///     the venue is solvent by construction (WETH balance == Σ pool collateral + houseBalance).
///   - `open` rejects sub-NAV dust (`ZeroShares`); redeem rounds the removed size UP (favors the
///     house); reentrancy-guarded; owner can withdraw only the house surplus.
/// The reward side never touches holder principal — the margin is fees.
contract ReferenceStockPerpVenue is IPerpsVenue, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint256 private constant ONE = 1e18;

    address public immutable override marginToken; // WETH
    /// @notice WETH set aside to back positive PnL — kept separate from pool collateral so a
    /// profitable redeem can never be paid out of another pool's margin.
    uint256 public houseBalance;
    /// @notice Addresses allowed to `open` (deposit margin). The fee distributor is authorized;
    /// keeping `open` gated closes the oracle-latency farming vector while `redeem` stays open.
    mapping(address opener => bool) public isOpener;

    struct Market {
        bool listed;
        bool open;
        string symbol; // e.g. "AAPL" — for the share-token name
        uint256 price; // 1e18 fixed point (WETH per share, abstract but consistent)
    }

    struct Pool {
        address shareToken;
        bytes32 market;
        bool isLong;
        uint16 leverageBps;
        uint256 collateral; // WETH margin currently in the pool
        uint256 size; // units (1e18); notional = size * price / 1e18
        uint256 entryPrice; // 1e18 size-weighted avg entry
    }

    mapping(bytes32 market => Market) public markets;
    mapping(bytes32 poolId => Pool) internal _pools;
    mapping(address shareToken => bytes32 poolId) public poolOf;

    error NotListed();
    error MarketClosed();
    error BadPrice();
    error ZeroMargin();
    error ZeroShares();
    error BadLeverage();
    error PoolLiquidated();
    error UnknownToken();
    error Slippage();
    error NotOpener();
    error InsufficientHouse();

    event MarketListed(bytes32 indexed market, string symbol);
    event MarkPrice(bytes32 indexed market, uint256 price);
    event MarketOpenSet(bytes32 indexed market, bool open);
    event OpenerSet(address indexed opener, bool allowed);
    event PositionTokenCreated(bytes32 indexed market, bool isLong, uint16 leverageBps, address token);
    event Opened(address indexed token, address indexed to, uint256 margin, uint256 shares);
    event Redeemed(address indexed token, address indexed from, uint256 shares, uint256 out);
    event HouseFunded(address indexed from, uint256 amount);
    event HouseWithdrawn(address indexed to, uint256 amount);

    constructor(address owner_, address marginToken_) Ownable(owner_) {
        marginToken = marginToken_;
    }

    // ── operator: the venue's oracle + market hours + house liquidity + opener allowlist ──────
    function listMarket(bytes32 market, string calldata symbol, uint256 price, bool isOpen) external onlyOwner {
        markets[market] = Market({listed: true, open: isOpen, symbol: symbol, price: price});
        emit MarketListed(market, symbol);
        emit MarkPrice(market, price);
        emit MarketOpenSet(market, isOpen);
    }

    function setMarkPrice(bytes32 market, uint256 price) external onlyOwner {
        if (!markets[market].listed) revert NotListed();
        markets[market].price = price;
        emit MarkPrice(market, price);
    }

    function setMarketOpen(bytes32 market, bool isOpen) external onlyOwner {
        if (!markets[market].listed) revert NotListed();
        markets[market].open = isOpen;
        emit MarketOpenSet(market, isOpen);
    }

    /// @notice Authorize/deauthorize an address to `open` (deposit margin) — the fee distributor.
    function setOpener(address opener, bool allowed) external onlyOwner {
        isOpener[opener] = allowed;
        emit OpenerSet(opener, allowed);
    }

    /// @notice Deposit WETH into the segregated house balance that backs positive-PnL redemptions.
    function fundLiquidity(uint256 amount) external nonReentrant {
        houseBalance += amount;
        IERC20(marginToken).safeTransferFrom(msg.sender, address(this), amount);
        emit HouseFunded(msg.sender, amount);
    }

    /// @notice Withdraw from the house surplus only — never touches pool collateral (bounded by
    /// `houseBalance`, which is decremented before the transfer).
    function withdrawHouse(uint256 amount, address to) external onlyOwner nonReentrant {
        houseBalance -= amount; // reverts on underflow → can't pull pool collateral
        IERC20(marginToken).safeTransfer(to, amount);
        emit HouseWithdrawn(to, amount);
    }

    // ── IPerpsVenue ────────────────────────────────────────────────────────────────
    function marketOpen(bytes32 market) public view override returns (bool) {
        Market storage m = markets[market];
        return m.listed && m.open && m.price > 0;
    }

    function positionTokenFor(bytes32 market, bool isLong, uint16 leverageBps)
        public
        override
        returns (address positionToken)
    {
        if (!markets[market].listed) revert NotListed();
        if (leverageBps == 0) revert BadLeverage();
        bytes32 poolId = _poolId(market, isLong, leverageBps);
        Pool storage p = _pools[poolId];
        if (p.shareToken != address(0)) return p.shareToken;

        string memory sym = markets[market].symbol;
        string memory lev = Strings.toString(uint256(leverageBps) / BPS);
        PerpPositionToken tok = new PerpPositionToken(
            string.concat("LF Perp ", sym, " ", isLong ? "Long " : "Short ", lev, "x"),
            string.concat("pp", sym, isLong ? "L" : "S", lev),
            market,
            isLong,
            leverageBps
        );
        p.shareToken = address(tok);
        p.market = market;
        p.isLong = isLong;
        p.leverageBps = leverageBps;
        poolOf[address(tok)] = poolId;
        emit PositionTokenCreated(market, isLong, leverageBps, address(tok));
        return address(tok);
    }

    function open(bytes32 market, bool isLong, uint16 leverageBps, uint256 margin)
        external
        override
        nonReentrant
        returns (address positionToken, uint256 shares)
    {
        if (!isOpener[msg.sender] && msg.sender != owner()) revert NotOpener();
        if (margin == 0) revert ZeroMargin();
        if (!marketOpen(market)) revert MarketClosed();
        positionToken = positionTokenFor(market, isLong, leverageBps);
        Pool storage p = _pools[_poolId(market, isLong, leverageBps)];

        uint256 price = markets[market].price;
        uint256 addSize = (margin * leverageBps * ONE) / (uint256(BPS) * price); // notional/price
        if (addSize == 0) addSize = 1; // dust guard: never leave size 0 (would divide-by-0 on next add)
        uint256 supply = IERC20(positionToken).totalSupply();

        if (supply == 0) {
            // Fresh pool: shares 1:1 with margin.
            shares = margin;
            p.collateral = margin;
            p.size = addSize;
            p.entryPrice = price;
        } else {
            uint256 pv = _poolValue(p, price);
            if (pv == 0) revert PoolLiquidated(); // liquidated pool — holders wiped; don't re-seed/dilute
            shares = (margin * supply) / pv;
            if (shares == 0) revert ZeroShares(); // sub-NAV dust deposit — reject, don't keep the margin
            p.entryPrice = (p.size * p.entryPrice + addSize * price) / (p.size + addSize);
            p.size += addSize;
            p.collateral += margin;
        }

        IERC20(marginToken).safeTransferFrom(msg.sender, address(this), margin);
        PerpPositionToken(positionToken).mint(msg.sender, shares);
        emit Opened(positionToken, msg.sender, margin, shares);
    }

    function redeem(address positionToken, uint256 shares, uint256 minOut)
        external
        override
        nonReentrant
        returns (uint256 out)
    {
        bytes32 poolId = poolOf[positionToken];
        if (poolId == bytes32(0)) revert UnknownToken();
        Pool storage p = _pools[poolId];
        uint256 price = markets[p.market].price;
        if (price == 0) revert BadPrice();

        uint256 supply = IERC20(positionToken).totalSupply();
        if (supply == 0) revert ZeroShares();
        uint256 pv = _poolValue(p, price);
        out = (pv * shares) / supply;
        if (out < minOut) revert Slippage();

        // The redeemer's collateral slice; any excess of `out` over it is PnL paid from the house —
        // never from another pool's collateral (revert if the house can't cover). A loss adds to house.
        uint256 colShare = (p.collateral * shares) / supply;
        if (out > colShare) {
            uint256 profit = out - colShare;
            if (profit > houseBalance) revert InsufficientHouse();
            houseBalance -= profit;
        } else {
            houseBalance += (colShare - out);
        }
        // Remove the redeemer's slice; round size UP so the remaining pool never over-retains value.
        p.size -= Math.ceilDiv(p.size * shares, supply);
        p.collateral -= colShare;

        PerpPositionToken(positionToken).burn(msg.sender, shares);
        if (out > 0) IERC20(marginToken).safeTransfer(msg.sender, out);
        emit Redeemed(positionToken, msg.sender, shares, out);
    }

    function shareValue(address positionToken, uint256 shares) external view override returns (uint256 wethValue) {
        bytes32 poolId = poolOf[positionToken];
        if (poolId == bytes32(0)) return 0;
        Pool storage p = _pools[poolId];
        uint256 supply = IERC20(positionToken).totalSupply();
        if (supply == 0) return 0;
        return (_poolValue(p, markets[p.market].price) * shares) / supply;
    }

    // ── views + internals ──────────────────────────────────────────────────────────
    function poolInfo(bytes32 market, bool isLong, uint16 leverageBps)
        external
        view
        returns (address shareToken, uint256 collateral, uint256 size, uint256 entryPrice, uint256 value)
    {
        Pool storage p = _pools[_poolId(market, isLong, leverageBps)];
        return (p.shareToken, p.collateral, p.size, p.entryPrice, _poolValue(p, markets[market].price));
    }

    function _poolId(bytes32 market, bool isLong, uint16 leverageBps) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(market, isLong, leverageBps));
    }

    /// @dev Pool value = collateral + unrealized PnL, floored at 0 (a fully-liquidated pool = 0).
    function _poolValue(Pool storage p, uint256 price) internal view returns (uint256) {
        if (p.size == 0 || price == 0) return p.collateral;
        int256 diff = int256(price) - int256(p.entryPrice);
        int256 pnl = (int256(p.size) * diff) / int256(ONE);
        if (!p.isLong) pnl = -pnl;
        int256 v = int256(p.collateral) + pnl;
        return v > 0 ? uint256(v) : 0;
    }
}
