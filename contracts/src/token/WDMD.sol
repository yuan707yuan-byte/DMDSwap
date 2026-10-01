// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IWDMD} from "../interfaces/IWDMD.sol";

/// @title WDMD — Wrapped DMD (1:1, ERC-20 + EIP-2612)
/// @notice No pause, no blacklist, no mint authority: supply only ever equals deposits - withdrawals.
/// @dev UUPS-upgradeable (owner = 24h timelock) per project requirement. Recommended: once stable,
///      renounce ownership via the timelock to make WDMD permanently immutable.
contract WDMD is ERC20PermitUpgradeable, UUPSUpgradeable, Ownable2StepUpgradeable, IWDMD {
    error ZeroAmount();
    error DMDTransferFailed();
    error NotAContract(address account);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __ERC20_init("Wrapped DMD", "WDMD");
        __ERC20Permit_init("Wrapped DMD");
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    receive() external payable {
        _deposit();
    }

    function deposit() external payable {
        _deposit();
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount); // effects before interaction (CEI)
        emit Withdrawal(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert DMDTransferFailed();
    }

    function _deposit() private {
        if (msg.value == 0) revert ZeroAmount();
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }
}
