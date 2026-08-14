// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {LaunchFairTokenFactory} from "../../src/v2/LaunchFairTokenFactory.sol";
import {TokenDeployerV2} from "../../src/v2/TokenDeployerV2.sol";
import {LaunchTokenV2} from "../../src/v2/LaunchTokenV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// A second implementation standing in for "we changed LaunchTokenV2 and had to redeploy the
/// factory". Same ABI, so the proxy keeps working; different address, which is exactly the churn
/// that used to move our on-chain creator.
contract TokenDeployerV2Alt is TokenDeployerV2 {
    uint256 public constant GENERATION = 2;
}

contract LaunchFairTokenFactoryTest is Test {
    LaunchFairTokenFactory factory;
    TokenDeployerV2 implA;
    TokenDeployerV2Alt implB;

    address constant OWNER = address(0xD3919E4);
    address constant TREASURY = address(0x7BEA5);
    address constant LAUNCHPAD = address(0x1A0);
    address constant RANDO = address(0xBAD);

    function setUp() public {
        implA = new TokenDeployerV2();
        implB = new TokenDeployerV2Alt();
        factory = new LaunchFairTokenFactory(OWNER, TREASURY);
        vm.startPrank(OWNER);
        factory.setImplementation(address(implA));
        factory.setLauncher(LAUNCHPAD, true); // the launchpad is the only caller allowed to deploy
        vm.stopPrank();
    }

    function _params(string memory sym) internal pure returns (TokenDeployerV2.Params memory p) {
        LaunchTokenV2.Metadata memory meta;
        p = TokenDeployerV2.Params({
            name: sym,
            symbol: sym,
            supply: 1_000_000_000 ether,
            platformWebsite: "https://hood.launchfair.app/",
            metadata: meta,
            maxBuyBps: 100,
            maxBuySecs: 60,
            mode: LaunchTokenV2.Mode.Base,
            rewardTokens: new address[](0),
            rewardWeights: new uint16[](0),
            prizeToken: address(0),
            minHoldForRewards: 0
        });
    }

    /// @dev CREATE2 address of a LaunchTokenV2 with these ctor args, as deployed BY `deployer`.
    /// If this matches the real token address, then `deployer` is what executed the CREATE2 —
    /// which is precisely what an explorer records as "created by".
    function _predict(address deployer, bytes32 salt, TokenDeployerV2.Params memory p, address launchpad_)
        internal
        pure
        returns (address)
    {
        bytes memory initcode = abi.encodePacked(
            type(LaunchTokenV2).creationCode,
            abi.encode(
                p.name,
                p.symbol,
                p.supply,
                p.platformWebsite,
                p.metadata,
                p.maxBuyBps,
                p.maxBuySecs,
                p.mode,
                p.rewardTokens,
                p.rewardWeights,
                p.prizeToken,
                p.minHoldForRewards,
                launchpad_
            )
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initcode)))))
        );
    }

    function _deployVia(address target, bytes32 salt, string memory sym) internal returns (address token) {
        vm.prank(LAUNCHPAD);
        token = TokenDeployerV2(target).deploy(_params(sym), salt);
    }

    // ── the whole point ──────────────────────────────────────────────────────

    /// THE property we are selling to Codex: the token's on-chain creator is the FACTORY address,
    /// not the implementation that happens to hold the bytecode today.
    function test_tokenCreatorIsTheFactory_notTheImplementation() public {
        bytes32 salt = keccak256("a");
        address token = _deployVia(address(factory), salt, "AAA");

        assertEq(token, _predict(address(factory), salt, _params("AAA"), LAUNCHPAD), "created by the FACTORY");
        assertTrue(token != _predict(address(implA), salt, _params("AAA"), LAUNCHPAD), "not by the implementation");
    }

    /// And it SURVIVES an implementation swap — the case that broke us three times.
    function test_creatorSurvivesImplementationSwap() public {
        address before = _deployVia(address(factory), keccak256("a"), "AAA");
        assertEq(before, _predict(address(factory), keccak256("a"), _params("AAA"), LAUNCHPAD));

        vm.prank(OWNER);
        factory.setImplementation(address(implB));

        address afterSwap = _deployVia(address(factory), keccak256("b"), "BBB");
        assertEq(
            afterSwap,
            _predict(address(factory), keccak256("b"), _params("BBB"), LAUNCHPAD),
            "still created by the same permanent address after the swap"
        );
    }

    /// The delegatecall must not quietly steal the launchpad role: `msg.sender` has to survive, or
    /// every token would trust this factory instead of the launchpad that created it.
    function test_launchpadRoleIsTheCaller_notTheFactory() public {
        address token = _deployVia(address(factory), keccak256("a"), "AAA");
        assertEq(LaunchTokenV2(payable(token)).launchpad(), LAUNCHPAD, "token trusts the launchpad");
        assertEq(
            LaunchTokenV2(payable(token)).balanceOf(LAUNCHPAD), 1_000_000_000 ether, "supply went to the launchpad"
        );
    }

    /// The free backstop marker we hand Codex alongside the address.
    function test_tokensCarryThePlatformMarker() public {
        address token = _deployVia(address(factory), keccak256("a"), "AAA");
        assertEq(LaunchTokenV2(payable(token)).platformWebsite(), "https://hood.launchfair.app/");
    }

    // ── access control ───────────────────────────────────────────────────────

    function test_onlyOwnerOrTreasuryCanRepoint() public {
        vm.prank(RANDO);
        vm.expectRevert(LaunchFairTokenFactory.NotAuthorized.selector);
        factory.setImplementation(address(implB));

        vm.prank(TREASURY);
        factory.setImplementation(address(implB));
        assertEq(factory.implementation(), address(implB), "treasury may repoint");

        vm.prank(OWNER);
        factory.setImplementation(address(implA));
        assertEq(factory.implementation(), address(implA), "deployer may repoint");
    }

    function test_treasuryCannotMoveItself() public {
        vm.prank(TREASURY);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, TREASURY));
        factory.setTreasury(RANDO);
    }

    function test_implementationMustBeAContract() public {
        vm.prank(OWNER);
        vm.expectRevert(LaunchFairTokenFactory.NotAContract.selector);
        factory.setImplementation(RANDO);
    }

    // ── the one-way exit from upgradeability ─────────────────────────────────

    function test_freezeIsPermanent_andAddressStillWorks() public {
        vm.prank(OWNER);
        factory.freezeImplementation();

        vm.prank(OWNER);
        vm.expectRevert(LaunchFairTokenFactory.AlreadyFrozen.selector);
        factory.setImplementation(address(implB));

        vm.prank(TREASURY);
        vm.expectRevert(LaunchFairTokenFactory.AlreadyFrozen.selector);
        factory.setImplementation(address(implB));

        // Frozen is not broken: it still deploys, still as the same creator.
        address token = _deployVia(address(factory), keccak256("z"), "ZZZ");
        assertEq(token, _predict(address(factory), keccak256("z"), _params("ZZZ"), LAUNCHPAD));
    }

    /// The mined address must be a pure function of (owner, treasury, salt) so the SAME address
    /// is reproducible at the production deploy and on any other chain. If the implementation
    /// were a constructor argument, it never could be.
    function test_addressDependsOnlyOnOwnerAndTreasury() public {
        bytes memory initcode =
            abi.encodePacked(type(LaunchFairTokenFactory).creationCode, abi.encode(OWNER, TREASURY));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(7)), keccak256(initcode)))))
        );
        LaunchFairTokenFactory twin = new LaunchFairTokenFactory{salt: bytes32(uint256(7))}(OWNER, TREASURY);
        assertEq(address(twin), predicted, "address derivable without knowing the implementation");
    }

    function test_deployRevertsUntilImplementationIsSet() public {
        LaunchFairTokenFactory bare = new LaunchFairTokenFactory(OWNER, TREASURY);
        vm.prank(OWNER);
        bare.setLauncher(LAUNCHPAD, true); // past the launcher gate, so we reach the impl check
        vm.prank(LAUNCHPAD);
        vm.expectRevert(LaunchFairTokenFactory.NotAContract.selector);
        TokenDeployerV2(address(bare)).deploy(_params("AAA"), keccak256("a"));
    }

    // The fallback is gated: a caller that is NOT an allow-listed launcher cannot deploy through
    // the factory, so nobody can mint a token carrying our canonical creator address.
    function test_nonLauncherCannotDeploy() public {
        vm.prank(RANDO);
        vm.expectRevert(LaunchFairTokenFactory.NotAuthorized.selector);
        TokenDeployerV2(address(factory)).deploy(_params("EVIL"), keccak256("x"));
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(OWNER);
        vm.expectRevert(LaunchFairTokenFactory.NotAuthorized.selector);
        factory.renounceOwnership();
    }

    function test_freezeBeforeSetImplementationReverts() public {
        LaunchFairTokenFactory bare = new LaunchFairTokenFactory(OWNER, TREASURY);
        vm.prank(OWNER);
        vm.expectRevert(LaunchFairTokenFactory.NotAContract.selector);
        bare.freezeImplementation(); // would otherwise brick the permanent address forever
    }

    // ── the silent-failure guard ─────────────────────────────────────────────

    /// A delegatecall to a codeless address SUCCEEDS and returns empty, so without the guard the
    /// launchpad would receive address(0) as a freshly "created" token.
    function test_codelessImplementationRevertsInsteadOfReturningNothing() public {
        // Force the slot to an EOA, bypassing setImplementation's own check.
        vm.store(address(factory), bytes32(uint256(2)), bytes32(uint256(uint160(RANDO))));
        assertEq(factory.implementation(), RANDO, "slot forced to a codeless address");

        vm.prank(LAUNCHPAD);
        vm.expectRevert(LaunchFairTokenFactory.NotAContract.selector);
        TokenDeployerV2(address(factory)).deploy(_params("AAA"), keccak256("a"));
    }
}
