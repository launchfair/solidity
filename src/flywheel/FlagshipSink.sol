// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair - flagship fee sink / forwarder.
//
// The immutable fee hooks bake in their `flagshipSink` address and can never repoint it (that is
// what makes them scan clean). But the flagship destination legitimately CHANGES over the flywheel's
// life: while fees accumulate there is no core token yet, then the CoreTGE war chest is seeded from
// them, then a buyback vault buys the core token back. This tiny contract is the fixed indirection
// that makes that possible: the hooks point at THIS (forever), it just holds the ETH they send, and
// the owner/keeper sweeps the hoard to the current `target` (unset -> CoreTGE -> vault) whenever it
// is time. It is not a token's pool hook, so its settable target trips no token scanner.

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract FlagshipSink is Ownable2Step {
    /// Where `sweep` sends the accumulated ETH. 0 = hoard only (the pre-CoreTGE state).
    address public target;
    /// Wallets allowed to trigger a sweep (the keeper), in addition to the owner. They can only ever
    /// move value to the owner-set `target`, never to an arbitrary address.
    mapping(address => bool) public isKeeper;

    event FeeReceived(address indexed from, uint256 amount);
    event TargetSet(address indexed target);
    event KeeperSet(address indexed keeper, bool allowed);
    event Swept(address indexed target, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error NotAuthorized();
    error TargetUnset();
    error EthTransferFailed();

    constructor(address owner_) Ownable(owner_) {}

    /// @dev Fee hooks push plain ETH here. Accumulate, never revert on receipt (a revert here would
    /// brick the hook's whole distribution).
    receive() external payable {
        emit FeeReceived(msg.sender, msg.value);
    }

    /// @notice Point the sweep at the current flagship destination: CoreTGE while accumulating toward
    /// the seeded launch, then the buyback vault after the flagship launches. Owner-only.
    function setTarget(address target_) external onlyOwner {
        target = target_;
        emit TargetSet(target_);
    }

    /// @notice Authorize (or revoke) a keeper to trigger `sweep`. Owner-only.
    function setKeeper(address keeper, bool ok) external onlyOwner {
        isKeeper[keeper] = ok;
        emit KeeperSet(keeper, ok);
    }

    /// @notice Sweep the whole accumulated hoard to `target`. Owner or an authorized keeper; the
    /// destination is NOT a parameter, so a leaked keeper key can only ever move it along the flow.
    function sweep() external returns (uint256 amount) {
        if (msg.sender != owner() && !isKeeper[msg.sender]) revert NotAuthorized();
        address t = target;
        if (t == address(0)) revert TargetUnset();
        amount = address(this).balance;
        if (amount == 0) return 0;
        (bool ok,) = t.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Swept(t, amount);
    }

    /// @notice Owner escape hatch so the hoard can never be stuck (e.g. a target that rejects ETH).
    function withdraw(address to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Withdrawn(to, amount);
    }
}
