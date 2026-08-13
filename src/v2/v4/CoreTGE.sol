// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair — core/flywheel token TGE (seeded launch).
//
// The core token is NOT fair-launched on day one. Instead this contract is the platform's
// fee accumulator ("war chest"): the V4 FeeLocker's flagship sink and the StockPairRouter's
// flagship sink both point here, so a slice of every trade on the platform accrues as ETH.
// The owner can also seed ETH manually at any time (the "seed it ourselves" option).
//
// When the owner triggers `launch`, the core token is minted ONCE and split:
//   - claims    → held here, released to the season Merkle distributor in ADMIN-SIZED tranches
//                 (`fundClaims`) — volume-based seasonal rewards, computed off-chain per points
//   - team      → held here, claimable by the owner from the dashboard (`claimTeam`)
//   - community → held here, claimable by the owner for community initiatives (`claimCommunity`)
//   - liquidity → paired with the ENTIRE accumulated ETH into a full-range Uniswap V3 position
//                 whose NFT lives in this contract forever — there is no function that can
//                 remove it, so the seeded liquidity is locked by construction.
//
// Starting price = accumulated ETH ÷ LP tokens: every pre-TGE trade raises the launch floor.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3Factory, INonfungiblePositionManager, IUniswapV3Pool} from "../../interfaces/IUniswapV3.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/// @notice The core token itself: a plain fixed-supply ERC20. All supply mints to the TGE
/// contract, which owns the allocation buckets. No owner, no mint, no hooks — nothing to rug.
contract CoreToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply, address to) ERC20(name_, symbol_) {
        _mint(to, supply);
    }
}

contract CoreTGE is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    /// Full-range ticks for the 1% fee tier (tickSpacing 200).
    int24 internal constant FULL_RANGE_TICK = 887_200;

    IWETH9 public immutable weth;
    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager public immutable positionManager;
    uint24 public immutable poolFee; // V3 fee tier of the seeded pool (default 10000 = 1%)

    // ── allocation (bps of total supply, fixed at construction, sum == 10000) ──
    uint16 public immutable claimsBps;
    uint16 public immutable teamBps;
    uint16 public immutable communityBps;
    uint16 public immutable lpBps;

    CoreToken public token; // zero until launch
    uint256 public lpTokenId; // the locked full-range position NFT (held here forever)
    uint256 public seededEth; // ETH that went into the pool at launch (for the record)

    // Remaining balances per bucket (decremented as the owner releases them).
    uint256 public claimsRemaining;
    uint256 public teamRemaining;
    uint256 public communityRemaining;

    /// Where claim tranches go: the season Merkle distributor users claim from.
    address public claimsDistributor;

    // ── dev revenue (owner-settable so a misconfig is never terminal) ────────
    /// Season skim ceiling: users' rewards can never be zeroed by a fat-fingered config.
    uint16 public constant MAX_SEASON_DEV_FEE_BPS = 2_000; // 20%
    /// Receives both dev carves. Defaults to the owner; settable (e.g. a team multisig).
    address public devFeeRecipient;
    /// Skimmed off EVERY claims tranche before it reaches the distributor (default 10%).
    uint16 public seasonDevFeeBps = 1_000;
    /// Dev share of the locked position's collected 1% pool fees (default 10%; settable up
    /// to 100% — "the whole 1%"). Whatever ISN'T taken is compounded back into the locked
    /// liquidity, so the pool only ever deepens.
    uint16 public poolDevFeeBps = 1_000;

    event Seeded(address indexed from, uint256 amount);
    event Launched(address token, uint256 supply, uint256 ethSeeded, uint256 lpTokens, uint256 lpTokenId);
    event ClaimsFunded(address indexed distributor, uint256 amount);
    event TeamClaimed(address indexed to, uint256 amount);
    event CommunityClaimed(address indexed to, uint256 amount);
    event ClaimsDistributorSet(address distributor);
    event EthWithdrawn(address indexed to, uint256 amount);
    event DevFeeConfigSet(address recipient, uint16 seasonBps, uint16 poolBps);
    event SeasonDevFeePaid(address indexed to, uint256 amount);
    event PoolFeesCollected(uint256 amount0, uint256 amount1, uint256 dev0, uint256 dev1, uint128 liquidityAdded);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    error AlreadyLaunched();
    error NotLaunched();
    error NothingAccumulated();
    error BadAllocation();
    error InsufficientBucket();
    error ZeroAddress();
    error EthTransferFailed();
    error FeeTooHigh();

    constructor(
        address owner_,
        IWETH9 weth_,
        IUniswapV3Factory factory_,
        INonfungiblePositionManager positionManager_,
        uint24 poolFee_,
        uint16 claimsBps_,
        uint16 teamBps_,
        uint16 communityBps_,
        uint16 lpBps_
    ) Ownable(owner_) {
        if (address(weth_) == address(0) || address(factory_) == address(0) || address(positionManager_) == address(0)) {
            revert ZeroAddress();
        }
        if (uint256(claimsBps_) + teamBps_ + communityBps_ + lpBps_ != BPS || lpBps_ == 0) revert BadAllocation();
        weth = weth_;
        factory = factory_;
        positionManager = positionManager_;
        poolFee = poolFee_;
        claimsBps = claimsBps_;
        teamBps = teamBps_;
        communityBps = communityBps_;
        lpBps = lpBps_;
        devFeeRecipient = owner_;
    }

    // ── accumulate ───────────────────────────────────────────────────────────
    /// @dev Fee sinks (FeeLocker flagship, StockPairRouter flagship) push plain ETH here.
    receive() external payable {
        emit Seeded(msg.sender, msg.value);
    }

    /// @notice Manual seeding — the team can top the war chest up from their own funds.
    function seed() external payable {
        emit Seeded(msg.sender, msg.value);
    }

    /// @notice Escape hatch: pull accumulated ETH back out (e.g. plans change pre-launch).
    function withdrawEth(address to, uint256 amount) external onlyOwner nonReentrant {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthWithdrawn(to, amount);
    }

    // ── launch ───────────────────────────────────────────────────────────────
    /// @notice Mint the core token and seed the locked pool with ALL accumulated ETH.
    /// One-shot. Starting price = accumulated ETH ÷ LP-token slice.
    function launch(string calldata name_, string calldata symbol_, uint256 supply)
        external
        onlyOwner
        nonReentrant
        returns (address tokenAddr)
    {
        if (address(token) != address(0)) revert AlreadyLaunched();
        uint256 eth = address(this).balance;
        if (eth == 0 || supply == 0) revert NothingAccumulated();

        token = new CoreToken(name_, symbol_, supply, address(this));
        tokenAddr = address(token);

        claimsRemaining = (supply * claimsBps) / BPS;
        teamRemaining = (supply * teamBps) / BPS;
        communityRemaining = (supply * communityBps) / BPS;
        uint256 lpTokens = supply - claimsRemaining - teamRemaining - communityRemaining; // remainder → LP (no dust)

        // Wrap the whole war chest and pair it with the LP slice, full range, locked here.
        weth.deposit{value: eth}();
        seededEth = eth;

        (address t0, address t1, uint256 a0, uint256 a1) = tokenAddr < address(weth)
            ? (tokenAddr, address(weth), lpTokens, eth)
            : (address(weth), tokenAddr, eth, lpTokens);

        address pool = factory.getPool(t0, t1, poolFee);
        if (pool == address(0)) pool = factory.createPool(t0, t1, poolFee);
        // sqrtPriceX96 = sqrt(a1/a0) * 2^96, computed as (sqrt(a1) << 96) / sqrt(a0) —
        // plenty of precision for an initial price on fresh liquidity.
        uint160 sqrtPriceX96 = uint160((Math.sqrt(a1) << 96) / Math.sqrt(a0));
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);

        IERC20(tokenAddr).forceApprove(address(positionManager), lpTokens);
        IERC20(address(weth)).forceApprove(address(positionManager), eth);
        (uint256 tokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: poolFee,
                tickLower: -FULL_RANGE_TICK,
                tickUpper: FULL_RANGE_TICK,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this), // the NFT never leaves — liquidity locked by construction
                deadline: block.timestamp
            })
        );
        lpTokenId = tokenId;

        emit Launched(tokenAddr, supply, eth, lpTokens, tokenId);
    }

    // ── post-launch releases (all owner-gated, all bucket-bounded) ───────────
    function setClaimsDistributor(address distributor) external onlyOwner {
        if (distributor == address(0)) revert ZeroAddress();
        claimsDistributor = distributor;
        emit ClaimsDistributorSet(distributor);
    }

    /// @notice Release an ADMIN-SIZED tranche of the claims reserve to the Merkle distributor.
    /// How much becomes claimable each season is purely an admin decision. A fixed
    /// `seasonDevFeeBps` slice of every tranche is skimmed to `devFeeRecipient` first —
    /// the team's cut of each season's rewards.
    function fundClaims(uint256 amount) external onlyOwner nonReentrant {
        if (address(token) == address(0)) revert NotLaunched();
        if (claimsDistributor == address(0)) revert ZeroAddress();
        if (amount > claimsRemaining) revert InsufficientBucket();
        claimsRemaining -= amount;
        uint256 devCut = (amount * seasonDevFeeBps) / BPS;
        if (devCut > 0) {
            IERC20(address(token)).safeTransfer(devFeeRecipient, devCut);
            emit SeasonDevFeePaid(devFeeRecipient, devCut);
        }
        IERC20(address(token)).safeTransfer(claimsDistributor, amount - devCut);
        emit ClaimsFunded(claimsDistributor, amount - devCut);
    }

    /// @notice Claim from the team allocation (the admins' cut, spent via the dashboard).
    function claimTeam(address to, uint256 amount) external onlyOwner nonReentrant {
        if (address(token) == address(0)) revert NotLaunched();
        if (amount > teamRemaining) revert InsufficientBucket();
        teamRemaining -= amount;
        IERC20(address(token)).safeTransfer(to, amount);
        emit TeamClaimed(to, amount);
    }

    /// @notice Claim from the community-initiatives allocation.
    function claimCommunity(address to, uint256 amount) external onlyOwner nonReentrant {
        if (address(token) == address(0)) revert NotLaunched();
        if (amount > communityRemaining) revert InsufficientBucket();
        communityRemaining -= amount;
        IERC20(address(token)).safeTransfer(to, amount);
        emit CommunityClaimed(to, amount);
    }

    // ── dev revenue ──────────────────────────────────────────────────────────
    /// @notice Tune the dev-revenue knobs. `poolBps` may go all the way to 100% ("the whole
    /// 1% fee"); the season skim is capped so user rewards can't be zeroed by misconfig.
    function setDevFeeConfig(address recipient, uint16 seasonBps, uint16 poolBps) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (seasonBps > MAX_SEASON_DEV_FEE_BPS || poolBps > BPS) revert FeeTooHigh();
        devFeeRecipient = recipient;
        seasonDevFeeBps = seasonBps;
        poolDevFeeBps = poolBps;
        emit DevFeeConfigSet(recipient, seasonBps, poolBps);
    }

    /// @notice Collect the locked position's accrued 1% pool fees: `poolDevFeeBps` of each side
    /// goes to `devFeeRecipient` (the team's trading revenue); EVERYTHING else is compounded
    /// straight back into the locked liquidity — the pool only ever deepens, and any dust the
    /// ratio can't absorb stays here for the next round. The position itself never moves.
    function collectPoolFees()
        external
        onlyOwner
        nonReentrant
        returns (uint256 amount0, uint256 amount1, uint128 liquidityAdded)
    {
        if (address(token) == address(0)) revert NotLaunched();
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: lpTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (address t0, address t1) = address(token) < address(weth)
            ? (address(token), address(weth))
            : (address(weth), address(token));
        uint256 dev0 = (amount0 * poolDevFeeBps) / BPS;
        uint256 dev1 = (amount1 * poolDevFeeBps) / BPS;
        if (dev0 > 0) IERC20(t0).safeTransfer(devFeeRecipient, dev0);
        if (dev1 > 0) IERC20(t1).safeTransfer(devFeeRecipient, dev1);

        // Reinvest the remainder into the locked position. NOTE: only the core token side is
        // bucket-tracked; the reinvested core tokens come from collected fees (surplus above
        // the buckets), never from claims/team/community reserves.
        uint256 re0 = amount0 - dev0;
        uint256 re1 = amount1 - dev1;
        if (re0 > 0 || re1 > 0) {
            if (re0 > 0) IERC20(t0).forceApprove(address(positionManager), re0);
            if (re1 > 0) IERC20(t1).forceApprove(address(positionManager), re1);
            (liquidityAdded,,) = positionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: lpTokenId,
                    amount0Desired: re0,
                    amount1Desired: re1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        emit PoolFeesCollected(amount0, amount1, dev0, dev1, liquidityAdded);
    }

    /// @notice Withdraw retained ERC20s (collected-fee remainder etc.). Cannot touch the
    /// allocation buckets: the token's bucket totals stay enforced by their own accounting,
    /// so this is capped at the surplus above (claims + team + community) for the core token.
    function withdrawToken(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (asset == address(token)) {
            uint256 reserved = claimsRemaining + teamRemaining + communityRemaining;
            uint256 surplus = IERC20(asset).balanceOf(address(this)) - reserved;
            if (amount > surplus) revert InsufficientBucket();
        }
        IERC20(asset).safeTransfer(to, amount);
        emit TokenWithdrawn(asset, to, amount);
    }
}
