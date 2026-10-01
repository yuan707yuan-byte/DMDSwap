// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Flash-swap callback, invoked on `to` when `data.length > 0`.
interface IDmdSwapCallee {
    function dmdSwapCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
