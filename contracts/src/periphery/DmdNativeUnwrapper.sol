// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IWDMD} from "../interfaces/IWDMD.sol";

/// @title DmdNativeUnwrapper
/// @notice Turns the CALLER's WDMD into native DMD and pays it straight to the recipient.
/// @dev Why this exists: WETH9-style wrappers pay out with `payable(msg.sender).transfer(amount)`, which forwards
///      only 2,300 gas. The routers are ERC-1967 proxies. A proxy can receive such a payout today only because,
///      inside a router transaction, its implementation slot and storage happen to be "warm" (EIP-2929); cold,
///      the same payout fails (see test_stipendPayout_*). That margin disappears if the network ever reprices
///      storage access (as Istanbul's EIP-1884 did) or if a future router version adds logic to `receive()`.
///      This contract is NOT a proxy and its `receive()` reads no storage (< 100 gas, cold or warm), so native
///      payouts keep working with any wrapper design and any reasonable gas schedule.
///
///      Pull model: `unwrapTo` takes WDMD only from msg.sender (via transferFrom, the routers approve it once),
///      so it can never touch anyone else's funds, and it holds nothing between calls. It has no owner and no
///      settings; the DMD DAO replaces it by upgrading the routers.
contract DmdNativeUnwrapper {
    address public immutable WDMD;

    error OnlyWDMD();
    error NotAContract(address account);
    error ZeroAddress();
    error WDMDTransferFailed();
    error DMDTransferFailed();

    constructor(address wdmd_) {
        if (wdmd_.code.length == 0) revert NotAContract(wdmd_);
        WDMD = wdmd_;
    }

    /// @dev Must stay this cheap (2,300-gas stipend). No storage reads: WDMD is an immutable.
    receive() external payable {
        if (msg.sender != WDMD) revert OnlyWDMD();
    }

    /// @notice Pulls `amount` WDMD from the caller, unwraps it and sends `amount` native DMD to `to`.
    /// @dev The caller must have approved this contract for at least `amount` WDMD.
    function unwrapTo(address to, uint256 amount) external {
        if (to == address(0)) revert ZeroAddress();
        if (!IWDMD(WDMD).transferFrom(msg.sender, address(this), amount)) revert WDMDTransferFailed();
        IWDMD(WDMD).withdraw(amount);
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert DMDTransferFailed();
    }
}
