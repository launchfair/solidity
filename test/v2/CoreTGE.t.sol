// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CoreTGE, CoreToken, IWETH9} from "../../src/v2/v4/CoreTGE.sol";
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

    address constant TEAM = address(0x7e40);
    address constant COMMUNITY = address(0xc0);
    address constant DISTRIBUTOR = address(0xd157);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        weth = new MockWeth9();
        factory = new MockV3Factory();
        npm = new MockPositionManager();
        tge = new CoreTGE(
            address(this),
            IWETH9(address(weth)),
            IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)),
            10_000,
            5_000, // claims 50%
            1_000, // team 10%
            3_000, // community 30%
            1_000 // LP 10%
        );
    }

    function test_allocationMustSumAndHaveLp() public {
        vm.expectRevert(CoreTGE.BadAllocation.selector);
        new CoreTGE(address(this), IWETH9(address(weth)), IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)), 10_000, 5_000, 1_000, 3_000, 500);
        vm.expectRevert(CoreTGE.BadAllocation.selector);
        new CoreTGE(address(this), IWETH9(address(weth)), IUniswapV3Factory(address(factory)),
            INonfungiblePositionManager(address(npm)), 10_000, 6_000, 1_000, 3_000, 0);
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
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY);
        CoreToken t = CoreToken(tokenAddr);

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
        tge.launch("Fair Core", "FAIR", SUPPLY);

        tge.seed{value: 1 ether}();
        tge.launch("Fair Core", "FAIR", SUPPLY);
        vm.deal(address(tge), 1 ether);
        vm.expectRevert(CoreTGE.AlreadyLaunched.selector);
        tge.launch("Fair Core", "FAIR", SUPPLY);
    }

    function test_fundClaims_adminSizedTranches() public {
        tge.seed{value: 1 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY);

        vm.expectRevert(CoreTGE.ZeroAddress.selector);
        tge.fundClaims(1 ether); // distributor unset

        tge.setClaimsDistributor(DISTRIBUTOR);
        tge.fundClaims(100_000_000 ether); // season 1 tranche — purely the admin's call
        assertEq(IERC20(tokenAddr).balanceOf(DISTRIBUTOR), 100_000_000 ether);
        assertEq(tge.claimsRemaining(), SUPPLY / 2 - 100_000_000 ether);

        vm.expectRevert(CoreTGE.InsufficientBucket.selector);
        tge.fundClaims(SUPPLY); // can never exceed the reserve
    }

    function test_teamAndCommunityClaims_boundedAndOwnerOnly() public {
        tge.seed{value: 1 ether}();
        address tokenAddr = tge.launch("Fair Core", "FAIR", SUPPLY);

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
        tge.launch("x", "x", 1);
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
