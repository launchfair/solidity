// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlagshipBuyback, IWETH9B} from "../../src/flywheel/FlagshipBuyback.sol";
import {IUniswapV3Factory, IV3SwapRouter} from "../../src/interfaces/IUniswapV3.sol";
import {MockV3Factory, MockV3Pool} from "../mocks/MockUniswapV3.sol";

contract BuybackMockWeth is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract BuybackMockCore is ERC20 {
    constructor() ERC20("Core", "CORE") {}
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// Swap router mock: pays `payoutBps` of amountIn in core (1:1 base rate), honors min-out.
contract BuybackMockRouter {
    BuybackMockCore public core;
    uint16 public payoutBps = 10_000;

    constructor(BuybackMockCore core_) {
        core = core_;
    }

    function setPayoutBps(uint16 b) external {
        payoutBps = b;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = (p.amountIn * payoutBps) / 10_000;
        require(out >= p.amountOutMinimum, "slip");
        core.mint(p.recipient, out);
    }
}

/// Distributor mock: pulls the funding via allowance (proving the approve+fund path).
contract BuybackMockDistributor {
    IERC20 public core;
    uint256 public lastSeason;
    uint256 public lastAmount;
    bytes32 public lastRoot;

    constructor(IERC20 core_) {
        core = core_;
    }

    function fundAndPublish(uint256 season, uint256 amount, bytes32 root, uint256) external {
        core.transferFrom(msg.sender, address(this), amount);
        lastSeason = season;
        lastAmount = amount;
        lastRoot = root;
    }
}

contract FlagshipBuybackTest is Test {
    FlagshipBuyback vault;
    BuybackMockWeth weth;
    BuybackMockCore core;
    BuybackMockRouter router;
    BuybackMockDistributor dist;
    MockV3Factory factory;

    function setUp() public {
        weth = new BuybackMockWeth();
        core = new BuybackMockCore();
        router = new BuybackMockRouter(core);
        dist = new BuybackMockDistributor(IERC20(address(core)));
        factory = new MockV3Factory();

        vault = new FlagshipBuyback(
            address(this),
            IWETH9B(address(weth)),
            IUniswapV3Factory(address(factory)),
            IV3SwapRouter(address(router)),
            IERC20(address(core)),
            10_000 // 1% pool fee tier
        );
        vault.setDistributor(address(dist));

        // The core/WETH pool at a 1:1 spot (sqrtPriceX96 = 2^96).
        address pool = factory.createPool(address(weth), address(core), 10_000);
        MockV3Pool(pool).setSqrtPriceX96(uint160(1 << 96));
    }

    function test_receivesFeeEth_andBuysBack() public {
        vm.deal(address(0xfee), 1 ether);
        vm.prank(address(0xfee));
        (bool ok,) = address(vault).call{value: 0.3 ether}("");
        assertTrue(ok);

        uint256 out = vault.buyback();
        // 1:1 mock fill; floor was 0.96x (1% pool fee + 3% slippage) — comfortably met.
        assertEq(out, 0.3 ether, "bought 1:1");
        assertEq(core.balanceOf(address(vault)), 0.3 ether, "core held by the VAULT, not a wallet");
        assertEq(address(vault).balance, 0, "fee ETH fully deployed");
    }

    address constant KEEPER = address(0xCEE9);

    // ── keeper gas auto-top-up ───────────────────────────────────────────────
    function test_gasTopUp_refillsOnlyBelowFloor() public {
        address keeper = KEEPER;
        vm.deal(address(vault), 1 ether);
        vault.setGasPolicy(keeper, 0.03 ether, 0.02 ether, 0.1 ether);

        // Below the floor -> topped up toward it, but never more than maxPerTopUp in one go.
        vm.deal(keeper, 0.005 ether);
        assertEq(vault.topUpGas(), 0.02 ether, "first top-up is capped at maxPerTopUp");
        assertEq(keeper.balance, 0.025 ether, "keeper rose by the capped amount");
        // A second call finishes the job (0.005 short of the floor).
        assertEq(vault.topUpGas(), 0.005 ether, "sends only the remaining shortfall");
        assertEq(keeper.balance, 0.03 ether, "keeper is back at the floor");

        // At the floor -> nothing sent, however often it is called.
        assertEq(vault.topUpGas(), 0, "no top-up while funded");
        assertEq(vault.topUpGas(), 0, "still nothing");
        assertEq(keeper.balance, 0.03 ether, "balance untouched");

        // Above the floor -> nothing sent.
        vm.deal(keeper, 0.5 ether);
        assertEq(vault.topUpGas(), 0, "never tops up an already-rich keeper");
    }

    /// PERMISSIONLESS by design: a keeper with no gas can't send the tx that refills itself.
    /// Anyone may poke it, and the money can still only reach the owner-set recipient.
    function test_gasTopUp_isPermissionless_butOnlyPaysTheSetRecipient() public {
        address keeper = KEEPER;
        vm.deal(address(vault), 1 ether);
        vault.setGasPolicy(keeper, 0.03 ether, 0.02 ether, 0.1 ether);
        vm.deal(keeper, 0);

        vm.prank(address(0xBAD)); // a stranger triggers it
        uint256 sent = vault.topUpGas();
        assertEq(sent, 0.02 ether, "capped by maxPerTopUp");
        assertEq(keeper.balance, 0.02 ether, "funds went to the KEEPER, not the caller");
        assertEq(address(0xBAD).balance, 0, "caller got nothing");
    }

    function test_gasTopUp_dailyCapBoundsACompromisedKeeper() public {
        address keeper = KEEPER;
        vm.deal(address(vault), 5 ether);
        // Cap the day at 0.05 with a 0.02 per-call ceiling.
        vault.setGasPolicy(keeper, 0.03 ether, 0.02 ether, 0.05 ether);

        uint256 drained;
        for (uint256 i; i < 10; i++) {
            vm.deal(keeper, 0); // keeper burns everything, repeatedly
            drained += vault.topUpGas();
        }
        assertEq(drained, 0.05 ether, "a whole day of abuse is bounded by the daily cap");

        // The window rolls after 24h and the budget returns.
        vm.warp(block.timestamp + 1 days + 1);
        vm.deal(keeper, 0);
        assertEq(vault.topUpGas(), 0.02 ether, "fresh window, fresh budget");
    }

    function test_buyback_topsUpKeeperFirst() public {
        address keeper = KEEPER;
        vm.deal(address(vault), 1 ether);
        vault.setGasPolicy(keeper, 0.03 ether, 0.02 ether, 0.1 ether);
        vm.deal(keeper, 0.01 ether);

        vault.buyback();
        assertEq(keeper.balance, 0.03 ether, "the cron call refilled the wallet that paid for it");
    }

    function test_gasTopUp_offByDefaultAndWhenDisabled() public {
        vm.deal(address(vault), 1 ether);
        assertEq(vault.gasRecipient(), address(0), "off until configured");
        assertEq(vault.topUpGas(), 0, "no recipient, no spend");

        address keeper = KEEPER;
        vault.setGasPolicy(keeper, 0.03 ether, 0.02 ether, 0.1 ether);
        vault.setGasPolicy(address(0), 0, 0, 0); // switched back off
        vm.deal(keeper, 0);
        assertEq(vault.topUpGas(), 0, "disabled means disabled");
    }

    function test_setGasPolicy_ownerOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        vault.setGasPolicy(address(0xBAD), 1 ether, 1 ether, 1 ether);
    }

    function test_buyback_capsPerSwap() public {
        vm.deal(address(vault), 2 ether);
        vault.setParams(300, 0.5 ether);
        vault.buyback();
        assertEq(address(vault).balance, 1.5 ether, "only the per-swap cap was spent");
    }

    function test_buyback_selfQuotedFloorRejectsBadFill() public {
        vm.deal(address(vault), 1 ether);
        router.setPayoutBps(9_000); // 90% fill < the 96% floor
        vm.expectRevert(bytes("slip"));
        vault.buyback();
    }

    function test_buyback_ownerOnly_andNeedsBalance() public {
        vm.prank(address(0xbad));
        vm.expectRevert();
        vault.buyback();
        vm.expectRevert(FlagshipBuyback.NothingToBuy.selector);
        vault.buyback(); // owner, but empty
    }

    function test_publishSeason_fundsDistributorFromVault() public {
        vm.deal(address(vault), 1 ether);
        vault.buyback();
        vault.publishSeason(123, 0.4 ether, keccak256("root"), 0.4 ether);
        assertEq(dist.lastSeason(), 123);
        assertEq(core.balanceOf(address(dist)), 0.4 ether, "distributor pulled straight from the vault");
        vm.prank(address(0xbad));
        vm.expectRevert();
        vault.publishSeason(124, 1, bytes32(0), 1);
    }

    function test_withdrawHatches_ownerOnly() public {
        vm.deal(address(vault), 0.2 ether);
        vault.withdrawEth(address(0xAAA1), 0.2 ether);
        assertEq(address(0xAAA1).balance, 0.2 ether);

        core.mint(address(vault), 5 ether);
        vault.withdrawToken(address(core), address(0xBBB1), 2 ether); // e.g. the season team cut
        assertEq(core.balanceOf(address(0xBBB1)), 2 ether);

        vm.prank(address(0xbad));
        vm.expectRevert();
        vault.withdrawEth(address(0xbad), 1);
    }

    function test_setParams_caps() public {
        vm.expectRevert(FlagshipBuyback.BadParams.selector);
        vault.setParams(2_001, 1 ether);
        vm.expectRevert(FlagshipBuyback.BadParams.selector);
        vault.setParams(300, 0);
    }
}
