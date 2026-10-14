// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title DmdSwapOwnable
/// @notice Shared governance base for every upgradeable DMDSwap contract.
/// @dev The owner is the DMD Diamond DAO (0xDA0d…dA0). DAO "Contract upgrade" proposals execute
///      `DiamondDao.execute()`, which calls the target with msg.sender = the DAO, so the owner check below is
///      exactly "the DAO approved this proposal". The owner is the ONLY account that can:
///        - upgrade the contract (UUPS `upgradeToAndCall`),
///        - change any setting guarded by `onlyOwner`,
///        - hand ownership to a new address with `transferOwnership(newOwner)` (one-step, effective at once).
///      `renounceOwnership` is disabled: an owner-less contract could never be upgraded or fixed again.
abstract contract DmdSwapOwnable is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    error OwnershipCannotBeRenounced();
    error NotAContract(address account);

    // solhint-disable-next-line func-name-mixedcase
    function __DmdSwapOwnable_init(address owner_) internal onlyInitializing {
        __Ownable_init(owner_); // reverts OwnableInvalidOwner(address(0)) for the zero address
        __UUPSUpgradeable_init();
    }

    /// @notice Disabled on purpose. Use `transferOwnership(newOwner)` to move control to a new address.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }
}
