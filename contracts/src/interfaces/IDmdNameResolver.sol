// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice DMDSwap-side view over the official DMD Naming System (DMDcoin/diamond-contracts-registry).
interface IDmdNameResolver {
    /// @return account The address `name` (label without ".dmd") currently and safely resolves to,
    ///         or address(0) if the name is invalid, inactive, expired, blocked, inconsistent,
    ///         or resolution is disabled. Never reverts.
    function resolve(string calldata name) external view returns (address account);

    /// @return name The forward-verified active DMD Name label of `account`, or "". Never reverts.
    function activeNameOf(address account) external view returns (string memory name);

    /// @return True iff `name` satisfies the DMD Name rules (identical to DMDRegistrarController.valid).
    function isValidName(string calldata name) external pure returns (bool);
}
