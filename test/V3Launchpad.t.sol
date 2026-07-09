// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {V3Launchpad} from "../src/V3Launchpad.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IUniswapV3Factory, INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockV3Factory, MockV3Pool, MockPositionManager} from "./mocks/MockUniswapV3.sol";

/// Token/WETH address ordering flips every piece of tick & price math, so the
/// whole suite runs twice: once with WETH at a high address (token = token0)
/// and once with WETH at a low address (token = token1).
abstract contract V3LaunchpadTestBase is Test {
    uint128 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant INITIAL_PRICE = 1_491_146_318; // WETH wei per whole token
    uint24 constant FEE_TIER = 10_000; // 1% per swap
    int24 constant TICK_LOWER0 = -203_200;
    int24 constant TICK_UPPER0 = 887_200;
    uint256 constant GRAD_WETH = 5 ether; // WETH raised into the pool that bonds a token
    uint16 constant MAX_BUY_BPS = 200; // 2% wallet cap...
    uint32 constant MAX_BUY_BLOCKS = 360; // ...for the first 360 blocks
    string constant SITE = "https://fun.example.xyz";
    uint256 constant CREATION_FEE = 0.000005 ether;

    MockWETH weth;
    MockV3Factory factory;
    MockPositionManager pm;
    FeeLocker locker;
    V3Launchpad pad;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    address token;
    bool expectToken0; // whether launched tokens should sort below WETH

    function _wethAddress() internal pure virtual returns (address);

    function setUp() public {
        // Pin WETH at a chosen address so the token/WETH ordering is deterministic.
        address wethAt = _wethAddress();
        vm.etch(wethAt, address(new MockWETH()).code);
        weth = MockWETH(payable(wethAt));

        factory = new MockV3Factory();
        pm = new MockPositionManager();
        locker = new FeeLocker(owner, INonfungiblePositionManager(address(pm)), IERC20(address(weth)), treasury);
        pad = new V3Launchpad(
            owner,
            IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(pm)),
            locker,
            address(weth),
            V3Launchpad.PoolConfig({
                feeTier: FEE_TIER,
                tickLower0: TICK_LOWER0,
                tickUpper0: TICK_UPPER0,
                tokenTotalSupply: TOTAL_SUPPLY,
                initialPriceWethPerToken: INITIAL_PRICE,
                graduationWethAmount: GRAD_WETH,
                maxBuyBps: MAX_BUY_BPS,
                maxBuyBlocks: MAX_BUY_BLOCKS
            }),
            SITE
        );
        vm.prank(owner);
        locker.setLaunchpad(address(pad));

        // Devs pay the flat creation fee, so fund the creators used in tests.
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);

        vm.prank(creator);
        token = pad.createToken{value: CREATION_FEE}("Test Token", "TST");
        expectToken0 = token < address(weth);
    }

    function test_orderingMatchesFixture() public view {
        // Sanity: the etched WETH address actually produces the intended branch.
        assertEq(expectToken0, _wethAddress() == address(type(uint160).max));
    }

    function test_launch_createsRealPoolAndLocksFullSupply() public view {
        V3Launchpad.LaunchInfo memory info = pad.getLaunch(token);
        assertEq(info.creator, creator);
        assertEq(info.tokenIsToken0, expectToken0);
        assertFalse(info.graduated);
        assertEq(info.pool, factory.getPool(token, address(weth), FEE_TIER));

        // Pool initialized at the configured launch price (reconstruct from sqrtPriceX96).
        MockV3Pool pool = MockV3Pool(info.pool);
        assertTrue(pool.initialized());
        uint256 sqrtP = pool.sqrtPriceX96();
        uint256 wethPerToken =
            expectToken0 ? Math.mulDiv(sqrtP * sqrtP, 1e18, 1 << 192) : Math.mulDiv(1 << 192, 1e18, sqrtP * sqrtP);
        assertApproxEqRel(wethPerToken, INITIAL_PRICE, 1e12, "pool must open at the configured price");

        // Single-sided range order with the FULL supply, minted straight to the locker.
        (,,, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1, address recipient) =
            pm.minted(info.positionTokenId);
        assertEq(recipient, address(locker), "LP NFT must be locked");
        if (expectToken0) {
            assertEq(amount0, TOTAL_SUPPLY);
            assertEq(amount1, 0);
            assertEq(tickLower, TICK_LOWER0);
            assertEq(tickUpper, TICK_UPPER0);
        } else {
            assertEq(amount1, TOTAL_SUPPLY);
            assertEq(amount0, 0);
            assertEq(tickLower, -TICK_UPPER0);
            assertEq(tickUpper, -TICK_LOWER0);
        }

        (uint256 tokenId, bool isToken0, bool exists) = locker.positions(token);
        assertEq(tokenId, info.positionTokenId);
        assertEq(isToken0, expectToken0);
        assertTrue(exists);

        // Launchpad keeps nothing; entire supply is pool liquidity.
        assertEq(IERC20(token).balanceOf(address(pad)), 0);
        assertEq(IERC20(token).balanceOf(address(pm)), TOTAL_SUPPLY);
    }

    function test_tokenTradableFromBlockOne() public {
        // No transfer locks of any kind: the pool IS the market from creation.
        vm.prank(address(pm));
        IERC20(token).transfer(alice, 1_000 ether);
        vm.prank(alice);
        IERC20(token).transfer(creator, 400 ether);
        assertEq(IERC20(token).balanceOf(creator), 400 ether);
        assertEq(LaunchToken(token).owner(), address(0), "token must read as renounced");
    }

    function test_claim_devGetsOnlyWeth_tokenFeesBurned() public {
        V3Launchpad.LaunchInfo memory info = pad.getLaunch(token);

        // Simulate accrued pool fees: 2 WETH (from buys) + 5M tokens (from sells).
        uint256 wethFees = 2 ether;
        uint256 tokenFees = 5_000_000 ether;
        vm.deal(address(pm), wethFees);
        vm.prank(address(pm));
        weth.deposit{value: wethFees}();
        if (expectToken0) pm.setCollectable(info.positionTokenId, tokenFees, wethFees);
        else pm.setCollectable(info.positionTokenId, wethFees, tokenFees);

        uint256 supplyBefore = IERC20(token).totalSupply();
        vm.prank(alice); // permissionless
        (uint256 toTreasury, uint256 toDev, uint256 burned) = locker.claim(token);

        // WETH: exact 50/50 between treasury and dev.
        assertEq(toTreasury, wethFees / 2);
        assertEq(toDev, wethFees - wethFees / 2);
        assertEq(weth.balanceOf(treasury), toTreasury);
        assertEq(weth.balanceOf(creator), toDev);

        // Token-side fees are burned — the dev NEVER receives tokens to dump.
        assertEq(burned, tokenFees);
        assertEq(IERC20(token).totalSupply(), supplyBefore - tokenFees);
        assertEq(IERC20(token).balanceOf(creator), 0, "dev must not receive tokens");
        assertEq(IERC20(token).balanceOf(treasury), 0, "treasury must not receive tokens");
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "locker keeps nothing");

        vm.expectRevert(FeeLocker.NothingToClaim.selector);
        locker.claim(token);
    }

    /// Bond WETH into a pool (simulate buys) so checkGraduation/curveProgress see it.
    function _bondWeth(address pool, uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(pool, amount);
    }

    function test_graduation_atWethTarget() public {
        V3Launchpad.LaunchInfo memory info = pad.getLaunch(token);
        assertEq(info.graduationWethAmount, GRAD_WETH);

        // Below the WETH target: not bonded yet.
        _bondWeth(info.pool, GRAD_WETH - 1);
        vm.expectRevert(V3Launchpad.NotEnoughWethBonded.selector);
        pad.checkGraduation(token);

        // One more wei reaches the target: anyone can poke it; liquidity never moves.
        _bondWeth(info.pool, 1);
        vm.prank(alice);
        assertTrue(pad.checkGraduation(token));
        assertTrue(pad.getLaunch(token).graduated);

        vm.expectRevert(V3Launchpad.AlreadyGraduated.selector);
        pad.checkGraduation(token);

        (uint256 tokenId,, bool exists) = locker.positions(token);
        assertTrue(exists);
        assertEq(tokenId, info.positionTokenId);
    }

    /// The bond target is snapshotted per token at creation — owner changes only
    /// affect future tokens, never existing ones.
    function test_setGraduationWethAmount_futureOnly() public {
        assertEq(pad.getLaunch(token).graduationWethAmount, GRAD_WETH);
        assertEq(pad.defaultGraduationWethAmount(), GRAD_WETH);

        // Owner raises the default.
        vm.prank(owner);
        pad.setGraduationWethAmount(2 ether);
        assertEq(pad.defaultGraduationWethAmount(), 2 ether);

        // Existing token is UNCHANGED (not retroactive).
        assertEq(pad.getLaunch(token).graduationWethAmount, GRAD_WETH);

        // A token created afterwards picks up the new default.
        vm.prank(creator);
        address token2 = pad.createToken{value: CREATION_FEE}("Later", "LTR");
        assertEq(pad.getLaunch(token2).graduationWethAmount, 2 ether);

        // Guards: reject 0, owner-only.
        vm.prank(owner);
        vm.expectRevert(V3Launchpad.InvalidPoolConfig.selector);
        pad.setGraduationWethAmount(0);
        vm.prank(alice);
        vm.expectRevert();
        pad.setGraduationWethAmount(1 ether);
    }

    function _predictToken(string memory name, string memory symbol, address creator_, bytes32 salt)
        internal
        view
        returns (address)
    {
        LaunchToken.Metadata memory empty;
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(LaunchToken).creationCode,
                abi.encode(name, symbol, uint256(TOTAL_SUPPLY), SITE, empty, MAX_BUY_BPS, MAX_BUY_BLOCKS)
            )
        );
        return vm.computeCreate2Address(keccak256(abi.encode(creator_, salt)), initCodeHash, address(pad));
    }

    function _sqrtPriceFor(uint256 priceWethPerToken, bool isToken0) internal pure returns (uint160) {
        uint256 ratioX192 =
            isToken0 ? Math.mulDiv(priceWethPerToken, 1 << 192, 1e18) : Math.mulDiv(1e18, 1 << 192, priceWethPerToken);
        return uint160(Math.sqrt(ratioX192));
    }

    function _targetSqrtPrice(address predictedToken) internal view returns (uint160) {
        return _sqrtPriceFor(INITIAL_PRICE, predictedToken < address(weth));
    }

    /// curveProgress is the frontend progress bar, measured as WETH bonded into
    /// the pool toward graduationWethAmount (0 -> 10000 bps).
    function test_curveProgress_tracksWethBonded() public {
        address pool = pad.getLaunch(token).pool;

        // Fresh launch: nothing bonded -> 0%.
        assertEq(pad.curveProgress(token), 0);

        // Bond 30% of the target -> 3000 bps.
        _bondWeth(pool, (GRAD_WETH * 30) / 100);
        assertApproxEqAbs(pad.curveProgress(token), 3000, 1);

        // Bond past the target -> clamps at 100%, before and after graduation.
        _bondWeth(pool, GRAD_WETH);
        assertEq(pad.curveProgress(token), 10_000);
        pad.checkGraduation(token);
        assertEq(pad.curveProgress(token), 10_000);

        // A token with nothing bonded reads 0%.
        vm.prank(creator);
        address token2 = pad.createToken{value: CREATION_FEE}("Second", "SEC");
        assertEq(pad.curveProgress(token2), 0);
    }

    /// Pool-poisoning: an attacker who predicts the CREATE2 token address and
    /// pre-creates its pool must not be able to brick or skew the launch.
    function test_poolGriefing_handledSafely() public {
        LaunchToken.Metadata memory empty;

        // Case A: pool pre-created but NOT initialized -> launchpad initializes
        // it at the configured price and proceeds.
        address predictedA = _predictToken("Griefed", "GRF", creator, 0);
        factory.createPool(predictedA, address(weth), FEE_TIER);
        vm.prank(creator);
        address tokenA = pad.createToken{value: CREATION_FEE}("Griefed", "GRF", empty, 0);
        assertEq(tokenA, predictedA);
        assertTrue(MockV3Pool(pad.getLaunch(tokenA).pool).initialized());

        // Case B: pool pre-initialized at a HOSTILE price (above our launch
        // price -> single-sided mint would break) -> clean revert, and the
        // creator retries with a fresh salt for a fresh address.
        address predictedB = _predictToken("Hostile", "HST", creator, 0);
        address poolB = factory.createPool(predictedB, address(weth), FEE_TIER);
        uint160 target = _targetSqrtPrice(predictedB);
        bool bIsToken0 = predictedB < address(weth);
        MockV3Pool(poolB).initialize(bIsToken0 ? target * 2 : target / 2);
        vm.prank(creator);
        vm.expectRevert(V3Launchpad.PoolPriceUnsafe.selector);
        pad.createToken{value: CREATION_FEE}("Hostile", "HST", empty, 0);

        vm.prank(creator);
        address tokenB = pad.createToken{value: CREATION_FEE}("Hostile", "HST", empty, bytes32(uint256(1)));
        assertTrue(tokenB != predictedB, "retry salt must yield a fresh address");
        assertTrue(pad.getLaunch(tokenB).pool != address(0));

        // Case C: pool pre-initialized at a SAFE price (at/below launch price)
        // -> the single-sided order still mints fully in tokens; proceed.
        address predictedC = _predictToken("Safe", "SFE", creator, 0);
        address poolC = factory.createPool(predictedC, address(weth), FEE_TIER);
        uint160 targetC = _targetSqrtPrice(predictedC);
        bool cIsToken0 = predictedC < address(weth);
        MockV3Pool(poolC).initialize(cIsToken0 ? targetC / 2 : targetC * 2);
        vm.prank(creator);
        address tokenC = pad.createToken{value: CREATION_FEE}("Safe", "SFE", empty, 0);
        assertEq(tokenC, predictedC);
        (,,,,, uint256 amount0, uint256 amount1, address recipient) = pm.minted(pad.getLaunch(tokenC).positionTokenId);
        assertEq(cIsToken0 ? amount0 : amount1, TOTAL_SUPPLY, "full supply still minted single-sided");
        assertEq(recipient, address(locker));
    }

    function test_metadataCarriesOver() public {
        LaunchToken.Metadata memory meta = LaunchToken.Metadata({
            logoURI: "ipfs://QmLogo",
            website: "https://mytoken.xyz",
            telegram: "https://t.me/mytoken",
            discord: "https://discord.gg/mytoken",
            twitter: "https://x.com/mytoken"
        });
        vm.prank(creator);
        address t = pad.createToken{value: CREATION_FEE}("Meta", "MTA", meta, 0);
        assertEq(LaunchToken(t).logoURI(), meta.logoURI);
        assertEq(LaunchToken(t).website(), meta.website);
        assertEq(LaunchToken(t).platformWebsite(), SITE);

        LaunchToken.Metadata memory bad;
        bad.website = 'x","image":"evil';
        vm.prank(creator);
        vm.expectRevert(V3Launchpad.InvalidMetadata.selector);
        pad.createToken{value: CREATION_FEE}("Bad", "BAD", bad, 0);
    }

    /// Anti-sniper guard: 2% max wallet for the first 360 blocks, then free.
    function test_maxBuy_capsWalletsForFirst360Blocks() public {
        LaunchToken t = LaunchToken(token);
        uint256 cap = (uint256(TOTAL_SUPPLY) * MAX_BUY_BPS) / 10_000; // 20M tokens
        assertEq(t.maxWalletAmount(), cap);
        assertTrue(t.limitActive());

        // Protocol plumbing is exempt (pool, position manager, locker, launchpad).
        assertTrue(t.limitExempt(pad.getLaunch(token).pool));
        assertTrue(t.limitExempt(address(pm)));
        assertTrue(t.limitExempt(address(locker)));
        assertTrue(t.limitExempt(address(pad)));

        // Buying up to exactly 2% is fine; one wei more reverts...
        vm.prank(address(pm));
        IERC20(token).transfer(alice, cap);
        vm.prank(address(pm));
        vm.expectRevert(LaunchToken.MaxBuyExceeded.selector);
        IERC20(token).transfer(alice, 1);

        // ...and stacking via wallet-to-wallet transfers can't exceed it either.
        vm.prank(address(pm));
        IERC20(token).transfer(bob, cap / 2);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.MaxBuyExceeded.selector);
        IERC20(token).transfer(bob, cap / 2 + 1);

        // Selling (transfer to the exempt pool infra) always works.
        vm.prank(alice);
        IERC20(token).transfer(address(pm), cap / 2);

        // The guard auto-expires after 360 blocks; nobody can re-enable it.
        vm.roll(block.number + MAX_BUY_BLOCKS);
        assertFalse(t.limitActive());
        vm.prank(address(pm));
        IERC20(token).transfer(alice, cap * 3);
        assertGt(IERC20(token).balanceOf(alice), cap);
    }

    function test_maxBuy_onlyLaunchpadCanExempt() public {
        vm.prank(alice);
        vm.expectRevert(LaunchToken.OnlyLaunchpad.selector);
        LaunchToken(token).setLimitExempt(alice, true);

        vm.prank(owner); // not even the launchpad owner
        vm.expectRevert(LaunchToken.OnlyLaunchpad.selector);
        LaunchToken(token).setLimitExempt(owner, true);
    }

    function test_creationFee_chargedToTreasury() public {
        assertEq(pad.creationFeeWei(), CREATION_FEE);
        assertEq(locker.treasury(), treasury);
        uint256 treasuryStart = treasury.balance;

        // Exact fee → treasury receives it.
        vm.prank(creator);
        pad.createToken{value: CREATION_FEE}("FeeTok", "FEE");
        assertEq(treasury.balance - treasuryStart, CREATION_FEE, "treasury gets the creation fee");

        // Overpayment → fee kept, remainder refunded to the dev.
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        pad.createToken{value: CREATION_FEE + 1 ether}("FeeTok2", "FEE2");
        assertEq(creator.balance, creatorBefore - CREATION_FEE, "excess refunded to dev");
        assertEq(treasury.balance - treasuryStart, 2 * CREATION_FEE, "treasury got both fees");

        // Underpayment → revert, nothing created.
        vm.prank(creator);
        vm.expectRevert(V3Launchpad.InsufficientCreationFee.selector);
        pad.createToken{value: CREATION_FEE - 1}("Cheap", "CHP");
    }

    function test_creationFee_ownerConfigurableAndCapped() public {
        vm.prank(owner);
        pad.setCreationFee(0.0001 ether);
        assertEq(pad.creationFeeWei(), 0.0001 ether);

        // Cannot exceed the hard cap.
        uint256 cap = pad.MAX_CREATION_FEE_WEI();
        vm.prank(owner);
        vm.expectRevert(V3Launchpad.CreationFeeTooHigh.selector);
        pad.setCreationFee(cap + 1);

        // Only the owner can change it.
        vm.prank(alice);
        vm.expectRevert();
        pad.setCreationFee(0);
    }

    function test_lockerAccessControl() public {
        vm.prank(alice);
        vm.expectRevert(FeeLocker.OnlyLaunchpad.selector);
        locker.register(address(0xBEEF), 1, true);

        vm.prank(owner);
        vm.expectRevert(FeeLocker.LaunchpadAlreadySet.selector);
        locker.setLaunchpad(alice);

        vm.expectRevert(FeeLocker.UnknownToken.selector);
        locker.claim(address(0xBEEF));

        // The locker has no function to withdraw or decrease liquidity — the
        // position NFT and the pool liquidity are locked forever by construction.
    }

    function test_transferCreatorByTreasury_ctoReassignsAndRedirectsFees() public {
        // Not the treasury (even the current creator) → OnlyTreasury.
        vm.prank(creator);
        vm.expectRevert(V3Launchpad.OnlyTreasury.selector);
        pad.transferCreatorByTreasury(token, bob);

        // Treasury performs a community takeover → creator becomes bob.
        vm.prank(treasury);
        pad.transferCreatorByTreasury(token, bob);
        assertEq(pad.creatorOf(token), bob, "treasury reassigned the creator");

        // The new (CTO) creator now receives the dev WETH fee share; old gets 0.
        V3Launchpad.LaunchInfo memory info = pad.getLaunch(token);
        vm.deal(address(pm), 1 ether);
        vm.prank(address(pm));
        weth.deposit{value: 1 ether}();
        if (expectToken0) pm.setCollectable(info.positionTokenId, 0, 1 ether);
        else pm.setCollectable(info.positionTokenId, 1 ether, 0);
        locker.claim(token);
        assertEq(weth.balanceOf(bob), 0.5 ether, "CTO creator receives the dev WETH share");
        assertEq(weth.balanceOf(creator), 0, "abandoning dev gets nothing after takeover");

        // Treasury can't null the creator.
        vm.prank(treasury);
        vm.expectRevert(V3Launchpad.ZeroAddress.selector);
        pad.transferCreatorByTreasury(token, address(0));
    }
}

contract V3LaunchpadTokenIsToken0Test is V3LaunchpadTestBase {
    function _wethAddress() internal pure override returns (address) {
        return address(type(uint160).max); // WETH above any CREATE address
    }
}

contract V3LaunchpadTokenIsToken1Test is V3LaunchpadTestBase {
    function _wethAddress() internal pure override returns (address) {
        return address(uint160(0x1234)); // WETH below any CREATE address
    }
}
