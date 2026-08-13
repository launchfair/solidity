// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CoreTGE, IWETH9} from "../../src/v2/v4/CoreTGE.sol";
import {TokenDeployerV2} from "../../src/v2/TokenDeployerV2.sol";
import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {IUniswapV3Factory, INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
import {MockV3Factory, MockPositionManager} from "../mocks/MockUniswapV3.sol";

contract MockWeth9 is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract CoreTGETest is Test {
    CoreTGE tge;
    MockWeth9 weth;
    MockV3Factory factory;
    MockPositionManager npm;
    TokenDeployerV2 tokenDeployer; // the REAL platform factory — the core must come from it

    address constant TEAM = address(0x7e40);
    address constant COMMUNITY = address(0xc0);
    address constant DISTRIBUTOR = address(0xd157);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        weth = new MockWeth9();
        factory = new MockV3Factory();
        npm = new MockPositionManager();
        tokenDeployer = new TokenDeployerV2();
        tge = new CoreTGE(
            address(this),
            IWETH9(address(weth)),
            IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)),
            tokenDeployer,
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
        assertFalse(t.limitActive(), "launch limits permanently off");
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
            INonfungiblePositionManager(address(npm)), tokenDeployer, "", 10_000, 5_000, 1_000, 3_000, 500);
        vm.expectRevert(CoreTGE.BadAllocation.selector);
        new CoreTGE(address(this), IWETH9(address(weth)), IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)), tokenDeployer, "", 10_000, 6_000, 1_000, 3_000, 0);
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
        tge.fundClaims(100_000_000 ether); // season 1 tranche — purely the admin's call
        // 10% season dev cut to devFeeRecipient (defaults to the owner), 90% to the distributor.
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

    function test_devFeeConfig_capsAndRecipient() public {
        // Pool cut may be ANYTHING up to 100% ("the whole 1% fee"); season skim capped at 20%.
        tge.setDevFeeConfig(TEAM, 500, 10_000);
        assertEq(tge.devFeeRecipient(), TEAM);
        assertEq(tge.seasonDevFeeBps(), 500);
        assertEq(tge.poolDevFeeBps(), 10_000);

        vm.expectRevert(CoreTGE.FeeTooHigh.selector);
        tge.setDevFeeConfig(TEAM, 2_001, 0); // season skim above the 20% ceiling
        vm.expectRevert(CoreTGE.FeeTooHigh.selector);
        tge.setDevFeeConfig(TEAM, 0, 10_001); // pool cut above 100%
        vm.expectRevert(CoreTGE.ZeroAddress.selector);
        tge.setDevFeeConfig(address(0), 0, 0);
        vm.prank(address(0xbad));
        vm.expectRevert();
        tge.setDevFeeConfig(address(0xbad), 0, 0);
    }

    function test_collectPoolFees_devCarveAndCompound() public {
        tge.seed{value: 10 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        tge.setDevFeeConfig(TEAM, 1_000, 1_000);

        // Pretend the locked position accrued 1%-pool fees: 1 WETH + 1000 tokens.
        (address t0,) = tokenAddr < address(weth) ? (tokenAddr, address(weth)) : (address(weth), tokenAddr);
        uint256 fee0 = t0 == tokenAddr ? 1_000 ether : 1 ether;
        uint256 fee1 = t0 == tokenAddr ? 1 ether : 1_000 ether;
        npm.setCollectable(tge.lpTokenId(), fee0, fee1);

        uint256 tgeTokBefore = IERC20(tokenAddr).balanceOf(address(tge));
        uint256 npmTokBefore = IERC20(tokenAddr).balanceOf(address(npm));
        uint256 npmWethBefore = weth.balanceOf(address(npm));
        tge.collectPoolFees();

        // Dev gets 10% of each side; the ENTIRE remainder compounds back into the position.
        assertEq(IERC20(tokenAddr).balanceOf(TEAM), 100 ether, "10% of token-side fees to dev");
        assertEq(weth.balanceOf(TEAM), 0.1 ether, "10% of WETH-side fees to dev");
        assertEq(IERC20(tokenAddr).balanceOf(address(npm)), npmTokBefore - 1_000 ether + 900 ether, "token remainder reinvested");
        assertEq(weth.balanceOf(address(npm)), npmWethBefore - 1 ether + 0.9 ether, "WETH remainder reinvested");
        assertEq(IERC20(tokenAddr).balanceOf(address(tge)), tgeTokBefore, "TGE retains nothing");
        assertEq(weth.balanceOf(address(tge)), 0, "TGE retains no WETH");
    }

    function test_collectPoolFees_fullDevCut() public {
        tge.seed{value: 10 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY, _meta());
        tge.setDevFeeConfig(TEAM, 1_000, 10_000); // take the whole 1% fee

        (address t0,) = tokenAddr < address(weth) ? (tokenAddr, address(weth)) : (address(weth), tokenAddr);
        npm.setCollectable(tge.lpTokenId(), t0 == tokenAddr ? 100 ether : 1 ether, t0 == tokenAddr ? 1 ether : 100 ether);
        tge.collectPoolFees();
        assertEq(IERC20(tokenAddr).balanceOf(TEAM), 100 ether, "whole token side to dev");
        assertEq(weth.balanceOf(TEAM), 1 ether, "whole WETH side to dev");
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
