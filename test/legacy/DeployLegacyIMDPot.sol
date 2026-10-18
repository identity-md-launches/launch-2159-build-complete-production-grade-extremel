// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IMDPot} from "./LegacyIMDPot.sol";

/// @title DeployIMDPot
/// @notice Reviewable deployment helper. The IMD launch factory deploys the contract from its bytecode with the
///         constructor argument `$owner`; this script mirrors that for local rehearsal and documents the
///         post-deployment configuration the owner performs.
/// @dev `run()` reads its configuration from the environment; tests call `deploy` directly with explicit
///      arguments and never touch the environment.
contract DeployIMDPot is Script {
    /// @notice Deploys IMDPot owned by `owner_`.
    function deploy(address owner_) public returns (IMDPot pot) {
        pot = new IMDPot(owner_);
    }

    /// @notice Broadcast entry point. Requires `IMDPOT_OWNER` to be set.
    function run() external returns (IMDPot pot) {
        address owner_ = vm.envAddress("IMDPOT_OWNER");
        vm.startBroadcast();
        pot = deploy(owner_);
        vm.stopBroadcast();
    }
}
