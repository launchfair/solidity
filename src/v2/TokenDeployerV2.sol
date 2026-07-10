// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// LaunchFair V2 — https://hood.launchfair.app

import {LaunchTokenV2} from "./LaunchTokenV2.sol";

/// @notice Deploys LaunchTokenV2 instances so the (large) token creation
/// bytecode lives here instead of inlined in the launchpad — keeping the
/// launchpad under the EIP-170 24KB limit. The launchpad passes itself as
/// `launchpad_`, so the deployed token trusts the launchpad (not this factory)
/// for its privileged calls, and mints the full supply to the launchpad.
contract TokenDeployerV2 {
    struct Params {
        string name;
        string symbol;
        uint256 supply;
        string platformWebsite;
        LaunchTokenV2.Metadata metadata;
        uint16 maxBuyBps;
        uint32 maxBuyBlocks;
        LaunchTokenV2.Mode mode;
        address rewardToken;
        address rewardPool;
    }

    /// @dev CREATE2 with the launchpad-chosen `salt`; `launchpad_` is the caller
    /// (the launchpad), which becomes the token's privileged controller + initial
    /// (excluded) supply holder.
    function deploy(Params calldata p, bytes32 salt) external returns (address token) {
        token = address(
            new LaunchTokenV2{salt: salt}(
                p.name,
                p.symbol,
                p.supply,
                p.platformWebsite,
                p.metadata,
                p.maxBuyBps,
                p.maxBuyBlocks,
                p.mode,
                p.rewardToken,
                p.rewardPool,
                msg.sender
            )
        );
    }
}
