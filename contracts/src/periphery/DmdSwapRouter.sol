// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDmdSwapFactory} from "../interfaces/IDmdSwapFactory.sol";
import {IDmdSwapPair} from "../interfaces/IDmdSwapPair.sol";
import {IWDMD} from "../interfaces/IWDMD.sol";
import {DmdSwapLibrary} from "../libraries/DmdSwapLibrary.sol";
import {DmdSwapRouterBase} from "./DmdSwapRouterBase.sol";

/// @title DmdSwapRouter
/// @notice User entry point for liquidity and swaps (ERC-20 <-> ERC-20, native DMD <-> ERC-20).
/// @dev UUPS-upgradeable, owner = 24h timelock. Holds no funds between transactions.
contract DmdSwapRouter is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    DmdSwapRouterBase
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:dmdswap.storage.Router
    struct RouterStorage {
        address factory;
        address wdmd;
    }

    // keccak256(abi.encode(uint256(keccak256("dmdswap.storage.Router")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROUTER_STORAGE_LOCATION =
        0x8391502ab74cf48132fc1c67aeec9fe1e371612ea9a17433afe2b769d84a0000;

    error InsufficientAAmount(uint256 amount, uint256 min);
    error InsufficientBAmount(uint256 amount, uint256 min);
    error PermitFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address factory_, address wdmd_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (factory_.code.length == 0) revert NotAContract(factory_);
        if (wdmd_.code.length == 0) revert NotAContract(wdmd_);
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        RouterStorage storage $ = _rs();
        $.factory = factory_;
        $.wdmd = wdmd_;
    }

    /// @dev Only WDMD may send native DMD here (during unwraps).
    receive() external payable {
        if (msg.sender != _rs().wdmd) revert OnlyWDMD();
    }

    function factory() external view returns (address) {
        return _rs().factory;
    }

    function WDMD() external view returns (address) {
        return _rs().wdmd;
    }

    // ─────────────────────────────────────────────── liquidity

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        _checkRecipient(to);
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = DmdSwapLibrary.pairFor(_rs().factory, tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IDmdSwapPair(pair).mint(to);
    }

    function addLiquidityDMD(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountDMDMin,
        address to,
        uint256 deadline
    ) external payable nonReentrant ensure(deadline) returns (uint256 amountToken, uint256 amountDMD, uint256 liquidity) {
        _checkRecipient(to);
        address wdmd = _rs().wdmd;
        (amountToken, amountDMD) =
            _addLiquidity(token, wdmd, amountTokenDesired, msg.value, amountTokenMin, amountDMDMin);
        address pair = DmdSwapLibrary.pairFor(_rs().factory, token, wdmd);
        IERC20(token).safeTransferFrom(msg.sender, pair, amountToken);
        IWDMD(wdmd).deposit{value: amountDMD}();
        IERC20(wdmd).safeTransfer(pair, amountDMD);
        liquidity = IDmdSwapPair(pair).mint(to);
        if (msg.value > amountDMD) _safeTransferDMD(msg.sender, msg.value - amountDMD); // refund dust
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        _checkRecipient(to);
        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);
    }

    function removeLiquidityDMD(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountDMDMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountToken, uint256 amountDMD) {
        (amountToken, amountDMD) = _removeLiquidityDMD(token, liquidity, amountTokenMin, amountDMDMin, to);
    }

    /// @notice Remove liquidity using an EIP-2612 LP-token signature (no separate approve tx).
    /// @dev Permit front-running cannot grief this: if permit() fails we fall back to the allowance.
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        _checkRecipient(to);
        _permit(DmdSwapLibrary.pairFor(_rs().factory, tokenA, tokenB), liquidity, deadline, approveMax, v, r, s);
        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);
    }

    function removeLiquidityDMDWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountDMDMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant ensure(deadline) returns (uint256 amountToken, uint256 amountDMD) {
        _permit(DmdSwapLibrary.pairFor(_rs().factory, token, _rs().wdmd), liquidity, deadline, approveMax, v, r, s);
        (amountToken, amountDMD) = _removeLiquidityDMD(token, liquidity, amountTokenMin, amountDMDMin, to);
    }

    /// @notice Variant for fee-on-transfer tokens: forwards the token amount actually received.
    function removeLiquidityDMDSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountDMDMin,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountDMD) {
        _checkRecipient(to);
        address wdmd = _rs().wdmd;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        (, amountDMD) = _removeLiquidity(token, wdmd, liquidity, amountTokenMin, amountDMDMin, address(this));
        uint256 tokenReceived = IERC20(token).balanceOf(address(this)) - tokenBefore;
        IERC20(token).safeTransfer(to, tokenReceived);
        IWDMD(wdmd).withdraw(amountDMD);
        _safeTransferDMD(to, amountDMD);
    }

    // ─────────────────────────────────────────────── swaps

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        _checkRecipient(to);
        _requireSlippageProtection(amountOutMin);
        amounts = DmdSwapLibrary.getAmountsOut(_rs().factory, amountIn, path, _feeBps());
        _checkOut(amounts[amounts.length - 1], amountOutMin);
        _pullToFirstPair(path, amounts[0]);
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        _checkRecipient(to);
        amounts = DmdSwapLibrary.getAmountsIn(_rs().factory, amountOut, path, _feeBps());
        _checkIn(amounts[0], amountInMax);
        _pullToFirstPair(path, amounts[0]);
        _swap(amounts, path, to);
    }

    function swapExactDMDForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        _checkRecipient(to);
        _requireSlippageProtection(amountOutMin);
        amounts = DmdSwapLibrary.getAmountsOut(_rs().factory, msg.value, path, _feeBps());
        _checkOut(amounts[amounts.length - 1], amountOutMin);
        _wrapToFirstPair(path, amounts[0]);
        _swap(amounts, path, to);
    }

    function swapTokensForExactDMD(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        _checkRecipient(to);
        address wdmd = _rs().wdmd;
        if (path[path.length - 1] != wdmd) revert InvalidPath();
        amounts = DmdSwapLibrary.getAmountsIn(_rs().factory, amountOut, path, _feeBps());
        _checkIn(amounts[0], amountInMax);
        _pullToFirstPair(path, amounts[0]);
        _swap(amounts, path, address(this));
        IWDMD(wdmd).withdraw(amounts[amounts.length - 1]);
        _safeTransferDMD(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForDMD(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256[] memory amounts) {
        _checkRecipient(to);
        _requireSlippageProtection(amountOutMin);
        address wdmd = _rs().wdmd;
        if (path[path.length - 1] != wdmd) revert InvalidPath();
        amounts = DmdSwapLibrary.getAmountsOut(_rs().factory, amountIn, path, _feeBps());
        _checkOut(amounts[amounts.length - 1], amountOutMin);
        _pullToFirstPair(path, amounts[0]);
        _swap(amounts, path, address(this));
        IWDMD(wdmd).withdraw(amounts[amounts.length - 1]);
        _safeTransferDMD(to, amounts[amounts.length - 1]);
    }

    function swapDMDForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        _checkRecipient(to);
        amounts = DmdSwapLibrary.getAmountsIn(_rs().factory, amountOut, path, _feeBps());
        _checkIn(amounts[0], msg.value);
        _wrapToFirstPair(path, amounts[0]);
        _swap(amounts, path, to);
        if (msg.value > amounts[0]) _safeTransferDMD(msg.sender, msg.value - amounts[0]); // refund
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountOut) {
        _checkRecipient(to);
        amountOut = _exactInputFOT(amountIn, amountOutMin, path, to);
    }

    function swapExactDMDForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable nonReentrant ensure(deadline) returns (uint256 amountOut) {
        _checkRecipient(to);
        amountOut = _exactDMDInputFOT(amountOutMin, path, to);
    }

    function swapExactTokensForDMDSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountOut) {
        _checkRecipient(to);
        amountOut = _exactInputToDMDFOT(amountIn, amountOutMin, path, to);
    }

    // ─────────────────────────────────────────────── quotes (UI)

    function swapFeeBps() external view returns (uint256) {
        return _feeBps();
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256) {
        return DmdSwapLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external view returns (uint256) {
        return DmdSwapLibrary.getAmountOut(amountIn, reserveIn, reserveOut, _feeBps());
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) external view returns (uint256) {
        return DmdSwapLibrary.getAmountIn(amountOut, reserveIn, reserveOut, _feeBps());
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory) {
        return DmdSwapLibrary.getAmountsOut(_rs().factory, amountIn, path, _feeBps());
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory) {
        return DmdSwapLibrary.getAmountsIn(_rs().factory, amountOut, path, _feeBps());
    }

    // ─────────────────────────────────────────────── internals

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) private returns (uint256 amountA, uint256 amountB) {
        address factory_ = _rs().factory;
        if (IDmdSwapFactory(factory_).getPair(tokenA, tokenB) == address(0)) {
            IDmdSwapFactory(factory_).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB,) = DmdSwapLibrary.getReserves(factory_, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = DmdSwapLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert InsufficientBAmount(amountBOptimal, amountBMin);
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = DmdSwapLibrary.quote(amountBDesired, reserveB, reserveA);
                // amountAOptimal <= amountADesired holds mathematically here.
                if (amountAOptimal < amountAMin) revert InsufficientAAmount(amountAOptimal, amountAMin);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function _removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) private returns (uint256 amountA, uint256 amountB) {
        address pair = DmdSwapLibrary.pairFor(_rs().factory, tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IDmdSwapPair(pair).burn(to);
        (address token0,) = DmdSwapLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount(amountA, amountAMin);
        if (amountB < amountBMin) revert InsufficientBAmount(amountB, amountBMin);
    }

    function _removeLiquidityDMD(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountDMDMin,
        address to
    ) private returns (uint256 amountToken, uint256 amountDMD) {
        _checkRecipient(to);
        address wdmd = _rs().wdmd;
        (amountToken, amountDMD) =
            _removeLiquidity(token, wdmd, liquidity, amountTokenMin, amountDMDMin, address(this));
        IERC20(token).safeTransfer(to, amountToken);
        IWDMD(wdmd).withdraw(amountDMD);
        _safeTransferDMD(to, amountDMD);
    }

    function _permit(
        address pair,
        uint256 liquidity,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        uint256 value = approveMax ? type(uint256).max : liquidity;
        try IERC20Permit(pair).permit(msg.sender, address(this), value, deadline, v, r, s) {}
        catch {
            if (IERC20(pair).allowance(msg.sender, address(this)) < liquidity) revert PermitFailed();
        }
    }

    function _checkOut(uint256 amountOut, uint256 amountOutMin) private pure {
        if (amountOut < amountOutMin) revert InsufficientOutputAmount(amountOut, amountOutMin);
    }

    function _checkIn(uint256 amountIn, uint256 amountInMax) private pure {
        if (amountIn > amountInMax) revert ExcessiveInputAmount(amountIn, amountInMax);
    }

    function _factoryAddr() internal view override returns (address) {
        return _rs().factory;
    }

    function _wdmdAddr() internal view override returns (address) {
        return _rs().wdmd;
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }

    function _rs() private pure returns (RouterStorage storage $) {
        assembly {
            $.slot := ROUTER_STORAGE_LOCATION
        }
    }
}
