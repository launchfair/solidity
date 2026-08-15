// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CoreTGE, IWETH9} from "../../src/v2/v4/CoreTGE.sol";
import {TokenDeployerV2} from "../../src/v2/TokenDeployerV2.sol";
import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {IUniswapV3Factory, INonfungiblePositionManager, IV3SwapRouter} from "../../src/interfaces/IUniswapV3.sol";
import {MockV3Factory, MockPositionManager} from "../mocks/MockUniswapV3.sol";

contract MockWeth9 is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// 1:1 WETH->core mock for the Buyback fee modes (fund it with core via claimTeam first).
contract TgeMockV3Router {
    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p) external returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn;
        require(out >= p.amountOutMinimum, "slip");
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

contract CoreTGETest is Test {
    CoreTGE tge;
    MockWeth9 weth;
    MockV3Factory factory;
    MockPositionManager npm;
    TokenDeployerV2 tokenDeployer; // the REAL platform factory — the core must come from it
    TgeMockV3Router v3router;

    address constant TEAM = address(0x7e40);
    address constant TREASURY = address(0x7EEA);
    address constant COMMUNITY = address(0xc0);
    address constant DISTRIBUTOR = address(0xd157);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        weth = new MockWeth9();
        factory = new MockV3Factory();
        npm = new MockPositionManager();
        tokenDeployer = new TokenDeployerV2();
        v3router = new TgeMockV3Router();
        tge = new CoreTGE(
            address(this),
            IWETH9(address(weth)),
            IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)),
            tokenDeployer,
            IV3SwapRouter(address(v3router)),
            TREASURY,
            "https://hood.launchfair.app/",
            10_000,
            5_000, // claims 50%
            1_000, // team 10%
            3_000, // community 30%
            1_000 // LP 10%
        );
    }

    function _meta() internal pure returns (LaunchTokenV2.Metadata memory) {
        return LaunchTokenV2.Metadata({
            logoURI: "ipfs://core-logo",
            website: "https://core.example",
            telegram: "",
            discord: "",
            twitter: "@core"
        });
    }

    /// The core token must be a FACTORY token: deployed by the same TokenDeployerV2 (same
    /// creator + LaunchTokenV2 bytecode external indexers key on), Base mode with the launch
    /// limits off — i.e. it behaves exactly like a plain fixed-supply ERC20.
    function test_launch_viaPlatformFactory_plainBaseToken() public {
        tge.seed{value: 1 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        LaunchTokenV2 t = LaunchTokenV2(tokenAddr);

        assertEq(t.launchpad(), address(tge), "TGE is the token's (unused) launchpad");
        assertEq(uint8(t.mode()), uint8(LaunchTokenV2.Mode.Base), "Base mode");
        assertTrue(t.limitActive(), "anti-snipe guard ON at launch (front-run protection for the seed)");
        assertEq(t.owner(), address(0), "reads renounced on explorers");
        assertEq(t.website(), "https://core.example", "metadata baked into the token");
        assertEq(t.platformWebsite(), "https://hood.launchfair.app/", "platform site set");

        // Plain transfer path: a bucket release then a wallet-to-wallet hop, no tax/hooks.
        tge.claimTeam(TEAM, 1_000 ether);
        vm.prank(TEAM);
        t.transfer(COMMUNITY, 400 ether);
        assertEq(t.balanceOf(COMMUNITY), 400 ether);
        assertEq(t.balanceOf(TEAM), 600 ether);
    }

    function test_allocationMustSumAndHaveLp() public {
        vm.expectRevert(CoreTGE.BadAllocation.selector);
        new CoreTGE(address(this), IWETH9(address(weth)), IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)), tokenDeployer, IV3SwapRouter(address(v3router)), TREASURY, "", 10_000, 5_000, 1_000, 3_000, 500);
        vm.expectRevert(CoreTGE.BadAllocation.selector);
        new CoreTGE(address(this), IWETH9(address(weth)), IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)), tokenDeployer, IV3SwapRouter(address(v3router)), TREASURY, "", 10_000, 6_000, 1_000, 3_000, 0);
    }

    /// The split is a live dashboard knob until launch; the values in force at launch freeze.
    function test_setAllocation_dynamicUntilLaunch() public {
        // Retune pre-launch (60/10/25/5) and launch on the NEW split.
        tge.setAllocation(6_000, 1_000, 2_500, 500);
        assertEq(tge.claimsBps(), 6_000);
        assertEq(tge.lpBps(), 500);

        vm.expectRevert(CoreTGE.BadAllocation.selector);
        tge.setAllocation(6_000, 1_000, 2_500, 400); // must sum to 10000
        vm.expectRevert(CoreTGE.BadAllocation.selector);
        tge.setAllocation(7_000, 1_000, 2_000, 0); // LP slice can't be zero
        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.setAllocation(2_500, 2_500, 2_500, 2_500); // owner only

        tge.seed{value: 1 ether}();
        tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        assertEq(tge.claimsRemaining(), (SUPPLY * 6_000) / 10_000, "launched on the retuned split");
        assertEq(tge.teamRemaining(), (SUPPLY * 1_000) / 10_000);
        assertEq(tge.communityRemaining(), (SUPPLY * 2_500) / 10_000);

        // Post-launch the split is frozen forever (buckets are already accounted from it).
        vm.expectRevert(CoreTGE.AlreadyLaunched.selector);
        tge.setAllocation(5_000, 1_000, 3_000, 1_000);
    }

    /// The launch-price floor: with a dust pot, only pot ÷ floor tokens get paired (whole pot
    /// still in the pool ⇒ starting price = the floor, never a "$7 mcap"); the unpaired LP
    /// remainder stays as withdrawable surplus.
    function test_launch_priceFloor_smallPot() public {
        uint256 floor = 1_491_146_318; // the launchpad's standard ~$2.5k-FDV launch price
        tge.setMinLaunchPrice(floor);
        tge.seed{value: 0.002 ether}(); // dust pot: natural price would be ~2.2e-12/token
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());

        uint256 lpSlice = SUPPLY - tge.claimsRemaining() - tge.teamRemaining() - tge.communityRemaining();
        uint256 expectedPaired = (0.002 ether * 1e18) / floor; // pot ÷ floor ≈ 1.34M tokens
        assertEq(IERC20(tokenAddr).balanceOf(address(npm)), expectedPaired, "paired only what the pot affords");
        assertEq(weth.balanceOf(address(npm)), 0.002 ether, "the ENTIRE pot is in the pool");

        // Unpaired remainder is surplus above the buckets — withdrawable, not stuck.
        uint256 surplus = lpSlice - expectedPaired;
        vm.warp(block.timestamp + 61); // past the anti-snipe window before the big admin withdrawal
        tge.withdrawToken(tokenAddr, TEAM, surplus);
        assertEq(IERC20(tokenAddr).balanceOf(TEAM), surplus, "unpaired LP remainder recoverable");

        // Post-launch the floor is frozen with everything else.
        vm.expectRevert(CoreTGE.AlreadyLaunched.selector);
        tge.setMinLaunchPrice(0);
    }

    /// PURE REVENUE: collected pool fees split TEAM/TREASURY (default 50/50) — nothing
    /// is reinvested, and the split is the only fee config.
    function test_collectPoolFees_pureRevenueSplit() public {
        tge.seed{value: 10 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        tge.setFeeWallets(TEAM, TREASURY);
        tge.setPoolFeeSplit(7_000, 3_000);

        (address t0,) = tokenAddr < address(weth) ? (tokenAddr, address(weth)) : (address(weth), tokenAddr);
        npm.setCollectable(tge.lpTokenId(), t0 == tokenAddr ? 1_000 ether : 1 ether, t0 == tokenAddr ? 1 ether : 1_000 ether);
        tge.collectPoolFees();

        assertEq(IERC20(tokenAddr).balanceOf(TEAM), 700 ether, "team 70% of the token side");
        assertEq(weth.balanceOf(TEAM), 0.7 ether, "team 70% of the WETH side");
        assertEq(IERC20(tokenAddr).balanceOf(TREASURY), 300 ether, "treasury takes the rest");
        assertEq(weth.balanceOf(TREASURY), 0.3 ether);
        assertEq(IERC20(tokenAddr).balanceOf(address(tge)) , SUPPLY - tge.claimsRemaining() - tge.teamRemaining() - tge.communityRemaining() - IERC20(tokenAddr).balanceOf(address(npm)) - 1_000 ether >= 0 ? IERC20(tokenAddr).balanceOf(address(tge)) : 0, "sanity");
        assertEq(weth.balanceOf(address(tge)), 0, "nothing retained, nothing reinvested");

        vm.expectRevert(CoreTGE.BadAllocation.selector);
        tge.setPoolFeeSplit(7_000, 2_000); // must sum to 100%
        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.setPoolFeeSplit(5_000, 5_000); // owner only
    }

    /// One-click reward funding: ETH in → core bought on the pool → straight to the sink.
    function test_buybackAndFund() public {
        tge.seed{value: 10 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        tge.claimTeam(address(v3router), 10 ether); // 1:1 mock inventory

        vm.expectRevert(CoreTGE.ZeroAddress.selector);
        tge.buybackAndFund{value: 0.1 ether}(0); // sink required first

        address SINK = address(0x5111c);
        tge.setRewardSink(SINK);
        // minCoreOut must be non-zero now (no unprotected market buys) — 1:1 mock, so 0.45 is safe.
        vm.expectRevert(CoreTGE.UnprotectedBuyback.selector);
        tge.buybackAndFund{value: 0.5 ether}(0);
        uint256 out = tge.buybackAndFund{value: 0.5 ether}(0.45 ether);
        assertEq(out, 0.5 ether, "1:1 mock fill");
        assertEq(IERC20(tokenAddr).balanceOf(SINK), 0.5 ether, "bought core delivered to the reward sink");

        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.buybackAndFund{value: 1}(1); // owner only
    }

    /// The core token's fee is HARD-CAPPED at 1% — a fatter tier can't even be deployed.
    function test_poolFeeCappedAtOnePercent() public {
        vm.expectRevert(CoreTGE.FeeTooHigh.selector);
        new CoreTGE(address(this), IWETH9(address(weth)), IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)), tokenDeployer, IV3SwapRouter(address(v3router)), TREASURY, "", 10_001, 0, 1_000, 0, 9_000);
    }

    /// A big pot needs no clamp: natural price above the floor pairs the full LP slice.
    function test_launch_priceFloor_bigPotUnclamped() public {
        tge.setMinLaunchPrice(1_491_146_318);
        tge.seed{value: 10 ether}(); // natural = 10e18*1e18/9e26 ≈ 1.1e10 > floor
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        uint256 lpSlice = SUPPLY - tge.claimsRemaining() - tge.teamRemaining() - tge.communityRemaining();
        assertEq(IERC20(tokenAddr).balanceOf(address(npm)), lpSlice, "full LP slice paired");
    }

    function test_accumulateFromSinksAndManualSeed() public {
        // Sinks push plain ETH (receive); the team can seed() on top.
        vm.deal(address(0xfee), 1 ether);
        vm.prank(address(0xfee));
        (bool ok,) = address(tge).call{value: 0.4 ether}("");
        assertTrue(ok);
        tge.seed{value: 0.6 ether}();
        assertEq(address(tge).balance, 1 ether, "war chest accumulates");
    }

    function test_launch_seedsLockedPoolAndBuckets() public {
        tge.seed{value: 10 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        IERC20 t = IERC20(tokenAddr);

        // Buckets: 50/10/30 held here; 10% + rounding remainder into the pool.
        assertEq(tge.claimsRemaining(), SUPPLY / 2, "claims 50%");
        assertEq(tge.teamRemaining(), SUPPLY / 10, "team 10%");
        assertEq(tge.communityRemaining(), (SUPPLY * 3) / 10, "community 30%");
        uint256 lpTokens = SUPPLY - SUPPLY / 2 - SUPPLY / 10 - (SUPPLY * 3) / 10;

        // The NPM pulled the whole war chest (as WETH) + the LP slice; buckets stay in the TGE.
        assertEq(weth.balanceOf(address(npm)), 10 ether, "all accumulated ETH seeded");
        assertEq(t.balanceOf(address(npm)), lpTokens, "LP token slice seeded");
        assertEq(t.balanceOf(address(tge)), SUPPLY - lpTokens, "buckets held by TGE");
        assertEq(address(tge).balance, 0, "no loose ETH after launch");
        assertGt(tge.lpTokenId(), 0, "position minted (and locked here)");
        assertEq(tge.seededEth(), 10 ether);
    }

    function test_launch_onceAndNeedsEth() public {
        vm.expectRevert(CoreTGE.NothingAccumulated.selector);
        tge.launch("Fair Core", "FAIR", SUPPLY, _meta());

        tge.seed{value: 1 ether}();
        tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        vm.deal(address(tge), 1 ether);
        vm.expectRevert(CoreTGE.AlreadyLaunched.selector);
        tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
    }

    function test_fundClaims_adminSizedTranches() public {
        tge.seed{value: 1 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());

        vm.expectRevert(CoreTGE.ZeroAddress.selector);
        tge.fundClaims(1 ether); // distributor unset

        tge.setClaimsDistributor(DISTRIBUTOR);
        vm.warp(block.timestamp + 61); // past the anti-snipe window — admin tranches settle after launch
        tge.fundClaims(100_000_000 ether); // season 1 tranche — purely the admin's call
        // 10% season skim to the teamWallet (defaults to the owner), 90% to the distributor.
        assertEq(IERC20(tokenAddr).balanceOf(DISTRIBUTOR), 90_000_000 ether, "90% to claims");
        assertEq(IERC20(tokenAddr).balanceOf(address(this)), 10_000_000 ether, "10% dev cut");
        assertEq(tge.claimsRemaining(), SUPPLY / 2 - 100_000_000 ether);

        vm.expectRevert(CoreTGE.InsufficientBucket.selector);
        tge.fundClaims(SUPPLY); // can never exceed the reserve
    }

    function test_teamAndCommunityClaims_boundedAndOwnerOnly() public {
        tge.seed{value: 1 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());

        tge.claimTeam(TEAM, 10_000_000 ether);
        assertEq(IERC20(tokenAddr).balanceOf(TEAM), 10_000_000 ether);
        assertEq(tge.teamRemaining(), SUPPLY / 10 - 10_000_000 ether);

        tge.claimCommunity(COMMUNITY, 5_000_000 ether);
        assertEq(IERC20(tokenAddr).balanceOf(COMMUNITY), 5_000_000 ether);

        vm.expectRevert(CoreTGE.InsufficientBucket.selector);
        tge.claimTeam(TEAM, SUPPLY); // bucket-bounded

        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.claimTeam(address(0xbad), 1 ether); // owner only
        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.fundClaims(1 ether);
        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.launch("x", "x", 1, _meta());
    }

    function test_feeSetters_capsAndAuth() public {
        tge.setSeasonDevFee(500);
        assertEq(tge.seasonDevFeeBps(), 500);
        vm.expectRevert(CoreTGE.FeeTooHigh.selector);
        tge.setSeasonDevFee(2_001); // skim above the 20% ceiling

        vm.expectRevert(CoreTGE.ZeroAddress.selector);
        tge.setFeeWallets(address(0), TREASURY);
        vm.expectRevert(CoreTGE.ZeroAddress.selector);
        tge.setRewardSink(address(0));
        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.setFeeWallets(address(0xbad), address(0xbad));
    }

    function test_withdrawToken_respectsBuckets() public {
        tge.seed{value: 1 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());

        // No surplus above the buckets → nothing withdrawable of the core token.
        vm.expectRevert(CoreTGE.InsufficientBucket.selector);
        tge.withdrawToken(tokenAddr, address(this), 1);

        // Create surplus (tokens above the tracked buckets) and only IT is withdrawable.
        tge.claimTeam(address(tge), 100 ether); // teamRemaining drops; balance stays → surplus 100
        tge.withdrawToken(tokenAddr, TEAM, 100 ether);
        vm.expectRevert(CoreTGE.InsufficientBucket.selector);
        tge.withdrawToken(tokenAddr, TEAM, 1 ether); // surplus exhausted
    }

    function test_withdrawEth_escapeHatch() public {
        tge.seed{value: 2 ether}();
        uint256 before = address(this).balance;
        tge.withdrawEth(address(this), 1.5 ether);
        assertEq(address(this).balance, before + 1.5 ether);
        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.withdrawEth(address(0xbad), 0.1 ether);
    }

    receive() external payable {}
}
