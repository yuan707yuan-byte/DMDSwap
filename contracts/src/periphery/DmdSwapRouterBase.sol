// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDmdSwapFactory} from "../interfaces/IDmdSwapFactory.sol";
import {IDmdSwapPair} from "../interfaces/IDmdSwapPair.sol";
import {IWDMD} from "../interfaces/IWDMD.sol";
import {DmdNativeUnwrapper} from "./DmdNativeUnwrapper.sol";
import {DmdSwapLibrary} from "../libraries/DmdSwapLibrary.sol";

/// @title DmdSwapRouterBase
/// @notice Shared, single-source swap execution used by DmdSwapRouter and DmdNameRouter.
/// @dev Front-running protection layer (on top of DMD's HBBFT encrypted, randomly-shuffled blocks):
///        - every swap has a deadline;
///        - exact-input swaps MUST set amountOutMin > 0 (unprotected swaps are rejected outright);
///        - exact-output swaps are bounded by amountInMax;
///        - tokens are only ever pulled from msg.sender, never from an arbitrary `from`.
///      Native DMD payouts go through DmdNativeUnwrapper (see there: WETH9-style wrappers pay with a 2,300-gas
///      stipend, which a proxy can only receive while its storage is warm). The routers never hold native DMD.
abstract contract DmdSwapRouterBase {
    using SafeERC20 for IERC20;

    error Expired(uint256 deadline, uint256 timestamp);
    error ZeroAddress();
    error InvalidRecipient(address to);
    error ZeroSlippageProtection();
    error InsufficientOutputAmount(uint256 amountOut, uint256 amountOutMin);
    error ExcessiveInputAmount(uint256 amountIn, uint256 amountInMax);
    error InvalidPath();
    error DMDTransferFailed();
    error UnwrapperMismatch();

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert Expired(deadline, block.timestamp);
        _;
    }

    function _factoryAddr() internal view virtual returns (address);
    function _wdmdAddr() internal view virtual returns (address);
    function _unwrapperAddr() internal view virtual returns (address);

    function _feeBps() internal view returns (uint256) {
        return IDmdSwapFactory(_factoryAddr()).swapFeeBps();
    }

    function _checkRecipient(address to) internal view {
        if (to == address(0) || to == address(this) || to == _unwrapperAddr()) revert InvalidRecipient(to);
    }

    function _requireSlippageProtection(uint256 amountOutMin) internal pure {
        if (amountOutMin == 0) revert ZeroSlippageProtection();
    }

    /// @dev Executes a pre-quoted route. Requires the input already sitting in the first pair.
    function _swap(uint256[] memory amounts, address[] memory path, address to) internal {
        address factory = _factoryAddr();
        uint256 last = path.length - 1;
        for (uint256 i; i < last; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = DmdSwapLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address dest = i < last - 1 ? DmdSwapLibrary.pairFor(factory, output, path[i + 2]) : to;
            IDmdSwapPair(DmdSwapLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, dest, "");
        }
    }

    /// @dev Route execution that derives each hop's input from actual pair balances. Correct for
    ///      fee-on-transfer tokens AND normal tokens. Caller must verify output via balance delta.
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address to) internal {
        address factory = _factoryAddr();
        uint256 feeBps = _feeBps();
        uint256 last = path.length - 1;
        for (uint256 i; i < last; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = DmdSwapLibrary.sortTokens(input, output);
            IDmdSwapPair pair = IDmdSwapPair(DmdSwapLibrary.pairFor(factory, input, output));
            uint256 amountOutput;
            {
                (uint112 r0, uint112 r1,) = pair.getReserves();
                (uint256 reserveIn, uint256 reserveOut) = input == token0 ? (r0, r1) : (r1, r0);
                uint256 amountInput = IERC20(input).balanceOf(address(pair)) - reserveIn;
                amountOutput = DmdSwapLibrary.getAmountOut(amountInput, reserveIn, reserveOut, feeBps);
            }
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            address dest = i < last - 1 ? DmdSwapLibrary.pairFor(factory, output, path[i + 2]) : to;
            pair.swap(amount0Out, amount1Out, dest, "");
        }
    }

    function _pullToFirstPair(address[] memory path, uint256 amountIn) internal {
        IERC20(path[0]).safeTransferFrom(
            msg.sender, DmdSwapLibrary.pairFor(_factoryAddr(), path[0], path[1]), amountIn
        );
    }

    function _wrapToFirstPair(address[] memory path, uint256 amountIn) internal {
        address wdmd = _wdmdAddr();
        if (path[0] != wdmd) revert InvalidPath();
        IWDMD(wdmd).deposit{value: amountIn}();
        IERC20(wdmd).safeTransfer(DmdSwapLibrary.pairFor(_factoryAddr(), path[0], path[1]), amountIn);
    }

    /// @dev FOT-safe exact-input token route; returns tokens actually received by `to`.
    function _exactInputFOT(uint256 amountIn, uint256 amountOutMin, address[] memory path, address to)
        internal
        returns (uint256 received)
    {
        DmdSwapLibrary.checkPath(path);
        _requireSlippageProtection(amountOutMin);
        IERC20 tokenOut = IERC20(path[path.length - 1]);
        uint256 balanceBefore = tokenOut.balanceOf(to);
        _pullToFirstPair(path, amountIn);
        _swapSupportingFeeOnTransferTokens(path, to);
        received = tokenOut.balanceOf(to) - balanceBefore;
        if (received < amountOutMin) revert InsufficientOutputAmount(received, amountOutMin);
    }

    /// @dev FOT-safe exact-input DMD -> token route; returns tokens actually received by `to`.
    function _exactDMDInputFOT(uint256 amountOutMin, address[] memory path, address to)
        internal
        returns (uint256 received)
    {
        DmdSwapLibrary.checkPath(path);
        _requireSlippageProtection(amountOutMin);
        IERC20 tokenOut = IERC20(path[path.length - 1]);
        uint256 balanceBefore = tokenOut.balanceOf(to);
        _wrapToFirstPair(path, msg.value);
        _swapSupportingFeeOnTransferTokens(path, to);
        received = tokenOut.balanceOf(to) - balanceBefore;
        if (received < amountOutMin) revert InsufficientOutputAmount(received, amountOutMin);
    }

    /// @dev FOT-safe exact-input token -> native DMD route (unwraps and pays `to`).
    function _exactInputToDMDFOT(uint256 amountIn, uint256 amountOutMin, address[] memory path, address to)
        internal
        returns (uint256 received)
    {
        DmdSwapLibrary.checkPath(path);
        _requireSlippageProtection(amountOutMin);
        address wdmd = _wdmdAddr();
        if (path[path.length - 1] != wdmd) revert InvalidPath();
        uint256 balanceBefore = IERC20(wdmd).balanceOf(address(this));
        _pullToFirstPair(path, amountIn);
        _swapSupportingFeeOnTransferTokens(path, address(this));
        received = IERC20(wdmd).balanceOf(address(this)) - balanceBefore;
        if (received < amountOutMin) revert InsufficientOutputAmount(received, amountOutMin);
        _unwrapFromRouter(to, received);
    }

    /// @dev Pays `amount` native DMD to `to` from WDMD held by this router.
    ///      The swap output is collected HERE (never sent straight into the unwrapper) and the unwrapper can only
    ///      pull WDMD from its caller, so no other contract or token hook can ever reach a user's output.
    function _unwrapFromRouter(address to, uint256 amount) internal {
        DmdNativeUnwrapper(payable(_unwrapperAddr())).unwrapTo(to, amount);
    }

    /// @dev Initializer helper: the unwrapper must be wired to the same WDMD as the router; approves it once.
    ///      The approval is harmless between transactions: the router holds no WDMD then, and the unwrapper
    ///      only pulls from its caller.
    function _setUpUnwrapper(address wdmd, address unwrapper) internal {
        if (unwrapper.code.length == 0 || DmdNativeUnwrapper(payable(unwrapper)).WDMD() != wdmd) {
            revert UnwrapperMismatch();
        }
        IERC20(wdmd).forceApprove(unwrapper, type(uint256).max);
    }

    function _safeTransferDMD(address to, uint256 value) internal {
        (bool ok,) = payable(to).call{value: value}("");
        if (!ok) revert DMDTransferFailed();
    }
}
