// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 — https://hood.launchfair.app

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice THE PERMANENT ON-CHAIN CREATOR of every LaunchFair token.
///
/// Every token is deployed with CREATE2 by `TokenDeployerV2`, which exists so the large token
/// creation bytecode lives outside the launchpad's 24KB limit. That has one bad consequence for
/// anyone indexing us: the factory EMBEDS the token bytecode (`new LaunchTokenV2{salt}`), so its
/// address is really a fingerprint of the token code. Every change to LaunchTokenV2 moves the
/// factory, which moves the "created by" that explorers and data providers (Codex, scanners,
/// terminals) key on. We have already been through three generations, and the core token ended up
/// with a creator no live launchpad uses — the flagship token disowned by its own platform.
///
/// This contract fixes that permanently. It holds no token logic of its own: it DELEGATECALLs the
/// current `TokenDeployerV2`, and because CREATE2 inside a delegatecall executes in the CALLER's
/// context, the token's on-chain creator is THIS address, forever, no matter how many times the
/// token implementation changes behind it. One address to hand to Codex, stable for the life of
/// the platform.
///
/// Two properties make this safe to do here, and they should be re-checked before any future
/// implementation swap:
///   1. `TokenDeployerV2` is STATELESS — no storage at all — so there is no storage-collision
///      hazard between it and this proxy's own slots (the usual reason proxies are dangerous).
///   2. `msg.sender` survives a delegatecall, so `deploy` still records the LAUNCHPAD (the real
///      caller) as the token's privileged controller and supply holder, exactly as before. This
///      contract never becomes the token's launchpad.
///
/// Upgradeability is the price of a permanent address, so it is bounded:
///   - only the DEPLOYER (owner) or the TREASURY may point it at a new implementation;
///   - the implementation must be a contract, checked on every set AND on every call, because a
///     delegatecall to a codeless address SUCCEEDS SILENTLY and would otherwise make `deploy`
///     return nothing while the launchpad believed it had a token;
///   - `freezeImplementation()` gives up the power for good. Once the token code is final, call
///     it: the address stays permanent and the contract becomes as immutable as a plain factory.
contract LaunchFairTokenFactory is Ownable2Step {
    /// @notice The `TokenDeployerV2` whose `deploy` this address delegatecalls.
    address public implementation;
    /// @notice May also repoint the implementation (never the owner-only controls).
    address public treasury;
    /// @notice Once true, `implementation` can never change again. One-way.
    bool public implementationFrozen;
    /// @notice Addresses allowed to deploy through this factory (the launchpad + CoreTGE).
    /// Declared AFTER the mined-address state so implementation (slot 2) and treasury (slot 3)
    /// keep their slots, and this mapping lands in a fresh slot the stateless impl never touches.
    mapping(address => bool) public isLauncher;

    event ImplementationSet(address indexed previous, address indexed current);
    event TreasurySet(address indexed previous, address indexed current);
    event ImplementationFrozen(address indexed implementation);
    event LauncherSet(address indexed launcher, bool allowed);

    error ZeroAddress();
    error NotAContract();
    error NotAuthorized();
    error AlreadyFrozen();

    /// @dev The implementation is deliberately NOT a constructor argument. This address is
    /// mined and must be reproducible from values we know are final — the owner and the treasury.
    /// Including the implementation would make the address depend on wherever that contract
    /// happened to land, so the mined address could never be reproduced (or re-derived on another
    /// chain) once the token code changed. `setImplementation` is called immediately after deploy;
    /// until then the fallback reverts, so the factory simply cannot deploy anything.
    constructor(address owner_, address treasury_) Ownable(owner_) {
        if (owner_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(address(0), treasury_);
    }

    /// @dev The deployer or the treasury — the same privileged pair that controls fee destinations
    /// elsewhere in the platform. Nothing else, ever.
    modifier onlyOwnerOrTreasury() {
        if (msg.sender != owner() && msg.sender != treasury) revert NotAuthorized();
        _;
    }

    /// @notice Point this permanent address at a new `TokenDeployerV2` (i.e. new token bytecode).
    /// Tokens already deployed are untouched — they are independent, immutable contracts. This
    /// only changes what FUTURE launches deploy.
    function setImplementation(address impl) external onlyOwnerOrTreasury {
        if (implementationFrozen) revert AlreadyFrozen();
        if (impl.code.length == 0) revert NotAContract();
        emit ImplementationSet(implementation, impl);
        implementation = impl;
    }

    /// @notice Owner-only on purpose: if the treasury could move itself, a compromised treasury
    /// could lock the deployer out of its own factory.
    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, t);
        treasury = t;
    }

    /// @notice Allow (or revoke) an address to deploy through this factory. The launchpad and
    /// CoreTGE are allow-listed at deploy time; nothing else can mint a token that carries this
    /// canonical creator address. Without this the fallback was open, so ANYONE could deploy a
    /// LaunchTokenV2 through the proxy and have the scam token indexed as "created by LaunchFair"
    /// — the one thing the permanent address exists to make trustworthy.
    function setLauncher(address launcher, bool allowed) external onlyOwnerOrTreasury {
        if (launcher == address(0)) revert ZeroAddress();
        isLauncher[launcher] = allowed;
        emit LauncherSet(launcher, allowed);
    }

    /// @notice Permanently give up the ability to change the implementation. Do this once the
    /// token contract is final: the creator address stays exactly the same, and the upgrade
    /// surface this contract introduces disappears for good.
    function freezeImplementation() external onlyOwner {
        if (implementationFrozen) revert AlreadyFrozen();
        // Never freeze with no implementation set — the fallback would then revert forever and
        // the permanent address (and every immutable `deployer` wired to it) would be dead.
        if (implementation == address(0)) revert NotAContract();
        implementationFrozen = true;
        emit ImplementationFrozen(implementation);
    }

    /// @notice Renouncing would leave the treasury as the sole, un-freezable upgrader (setTreasury
    /// and freezeImplementation are owner-only). Disabled so ownership can only be transferred.
    function renounceOwnership() public override onlyOwner {
        revert NotAuthorized();
    }

    /// @dev Everything else (today: `deploy`) runs as this address via delegatecall, which is what
    /// makes this contract the tokens' permanent creator. Deliberately NOT payable: nothing here
    /// needs ETH, and a non-payable fallback means a mistaken transfer reverts instead of being
    /// stranded in a contract with no withdrawal.
    ///
    /// Note for future implementations: a function whose selector collides with one declared above
    /// would be shadowed by this contract and unreachable through it. We control the
    /// implementation, so this is a review checklist item, not an open risk.
    fallback() external {
        // Only the allow-listed launchers (launchpad + CoreTGE) may deploy through the factory —
        // otherwise anyone could mint a token that indexes as "created by LaunchFair".
        if (!isLauncher[msg.sender]) revert NotAuthorized();
        address impl = implementation;
        // A delegatecall to an address with no code SUCCEEDS and returns empty — `deploy` would
        // hand the launchpad address(0) as a "token". Fail loudly instead.
        if (impl.code.length == 0) revert NotAContract();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
