// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title DmdSwapPairBeacon
/// @notice Holds the DmdSwapPair implementation used by every pool. One `upgradeTo(newImplementation)` call,
///         made by the owner (the DMD DAO), upgrades all pools at once.
/// @dev OpenZeppelin UpgradeableBeacon with `renounceOwnership` disabled, so pools can never become
///      permanently un-upgradeable. `transferOwnership(newOwner)` is one-step.
contract DmdSwapPairBeacon is UpgradeableBeacon {
    error OwnershipCannotBeRenounced();

    constructor(address implementation_, address owner_) UpgradeableBeacon(implementation_, owner_) {}

    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }
}
