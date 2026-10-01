// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDmdSwapFactory} from "../interfaces/IDmdSwapFactory.sol";
import {IDmdNameResolver} from "../interfaces/IDmdNameResolver.sol";
import {IWDMD} from "../interfaces/IWDMD.sol";
import {DmdSwapLibrary} from "../libraries/DmdSwapLibrary.sol";
import {DmdSwapRouterBase} from "../periphery/DmdSwapRouterBase.sol";

/// @title DmdNameRouter
/// @notice Swap-and-send / send directly to a DMD Name (e.g. "alice" for alice.dmd).
/// @dev Name-binding protection: the caller passes `expectedRecipient` — the address the UI showed and
///      the user confirmed. The name is re-resolved on-chain inside the same transaction and the call
///      reverts unless it still resolves to exactly that address. A name transferred, deactivated,
///      expired or blocked between quote and execution can therefore never redirect funds.
///      All functions honour the factory's emergency pause.
contract DmdNameRouter is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    DmdSwapRouterBase
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:dmdswap.storage.NameRouter
    struct NameRouterStorage {
        address factory;
        address wdmd;
        address resolver;
    }

    // keccak256(abi.encode(uint256(keccak256("dmdswap.storage.NameRouter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NAME_ROUTER_STORAGE_LOCATION =
        0x9d82d1be8be96b3e8b5e98809a8055fd847ffcfb0269f18f9aa03f7e12041500;

    /// @notice tokenOut == address(0) means native DMD.
    event NamePayment(
        address indexed sender, address indexed recipient, address indexed tokenOut, uint256 amountOut, string name
    );
    event NameResolverUpdated(address indexed previousResolver, address indexed newResolver);

    error NameNotResolvable(string name);
    error RecipientMismatch(string name, address resolved, address expected);
    error Paused();
    error ZeroAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address factory_, address wdmd_, address resolver_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (factory_.code.length == 0) revert NotAContract(factory_);
        if (wdmd_.code.length == 0) revert NotAContract(wdmd_);
        if (resolver_.code.length == 0) revert NotAContract(resolver_);
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        NameRouterStorage storage $ = _ns();
        $.factory = factory_;
        $.wdmd = wdmd_;
        $.resolver = resolver_;
        emit NameResolverUpdated(address(0), resolver_);
    }

    receive() external payable {
        if (msg.sender != _ns().wdmd) revert OnlyWDMD();
    }

    modifier whenNotPaused() {
        if (IDmdSwapFactory(_ns().factory).swapsPaused()) revert Paused();
        _;
    }

    // ─────────────────────────────────────────────── governance

    function setNameResolver(address resolver_) external onlyOwner {
        if (resolver_.code.length == 0) revert NotAContract(resolver_);
        NameRouterStorage storage $ = _ns();
        emit NameResolverUpdated($.resolver, resolver_);
        $.resolver = resolver_;
    }

    // ─────────────────────────────────────────────── views

    function factory() external view returns (address) {
        return _ns().factory;
    }

    function WDMD() external view returns (address) {
        return _ns().wdmd;
    }

    function nameResolver() external view returns (address) {
        return _ns().resolver;
    }

    function resolveName(string calldata name) external view returns (address) {
        return IDmdNameResolver(_ns().resolver).resolve(name);
    }

    // ─────────────────────────────────────────────── swap + send to name (exact input, FOT-safe)

    function swapExactTokensForTokensToName(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        string calldata name,
        address expectedRecipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountOut) {
        address to = _recipient(name, expectedRecipient);
        amountOut = _exactInputFOT(amountIn, amountOutMin, path, to);
        emit NamePayment(msg.sender, to, path[path.length - 1], amountOut, name);
    }

    function swapExactDMDForTokensToName(
        uint256 amountOutMin,
        address[] calldata path,
        string calldata name,
        address expectedRecipient,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountOut) {
        address to = _recipient(name, expectedRecipient);
        amountOut = _exactDMDInputFOT(amountOutMin, path, to);
        emit NamePayment(msg.sender, to, path[path.length - 1], amountOut, name);
    }

    function swapExactTokensForDMDToName(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        string calldata name,
        address expectedRecipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountOut) {
        address to = _recipient(name, expectedRecipient);
        amountOut = _exactInputToDMDFOT(amountIn, amountOutMin, path, to);
        emit NamePayment(msg.sender, to, address(0), amountOut, name);
    }

    // ─────────────────────────────────────────────── swap + send to name (exact output)

    function swapTokensForExactTokensToName(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        string calldata name,
        address expectedRecipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountIn) {
        address to = _recipient(name, expectedRecipient);
        uint256[] memory amounts = DmdSwapLibrary.getAmountsIn(_ns().factory, amountOut, path, _feeBps());
        amountIn = amounts[0];
        if (amountIn > amountInMax) revert ExcessiveInputAmount(amountIn, amountInMax);
        _pullToFirstPair(path, amountIn);
        _swap(amounts, path, to);
        emit NamePayment(msg.sender, to, path[path.length - 1], amountOut, name);
    }

    function swapDMDForExactTokensToName(
        uint256 amountOut,
        address[] calldata path,
        string calldata name,
        address expectedRecipient,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountIn) {
        address to = _recipient(name, expectedRecipient);
        uint256[] memory amounts = DmdSwapLibrary.getAmountsIn(_ns().factory, amountOut, path, _feeBps());
        amountIn = amounts[0];
        if (amountIn > msg.value) revert ExcessiveInputAmount(amountIn, msg.value);
        _wrapToFirstPair(path, amountIn);
        _swap(amounts, path, to);
        if (msg.value > amountIn) _safeTransferDMD(msg.sender, msg.value - amountIn); // refund to payer
        emit NamePayment(msg.sender, to, path[path.length - 1], amountOut, name);
    }

    function swapTokensForExactDMDToName(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        string calldata name,
        address expectedRecipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountIn) {
        address to = _recipient(name, expectedRecipient);
        address wdmd = _ns().wdmd;
        if (path[path.length - 1] != wdmd) revert InvalidPath();
        uint256[] memory amounts = DmdSwapLibrary.getAmountsIn(_ns().factory, amountOut, path, _feeBps());
        amountIn = amounts[0];
        if (amountIn > amountInMax) revert ExcessiveInputAmount(amountIn, amountInMax);
        _pullToFirstPair(path, amountIn);
        _swap(amounts, path, address(this));
        IWDMD(wdmd).withdraw(amountOut);
        _safeTransferDMD(to, amountOut);
        emit NamePayment(msg.sender, to, address(0), amountOut, name);
    }

    // ─────────────────────────────────────────────── plain send to name

    function sendDMDToName(string calldata name, address expectedRecipient)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (msg.value == 0) revert ZeroAmount();
        address to = _recipient(name, expectedRecipient);
        _safeTransferDMD(to, msg.value);
        emit NamePayment(msg.sender, to, address(0), msg.value, name);
    }

    function sendTokenToName(address token, uint256 amount, string calldata name, address expectedRecipient)
        external
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        address to = _recipient(name, expectedRecipient);
        IERC20(token).safeTransferFrom(msg.sender, to, amount);
        emit NamePayment(msg.sender, to, token, amount, name);
    }

    // ─────────────────────────────────────────────── internals

    /// @dev Resolve on-chain and bind to the user-confirmed address.
    function _recipient(string calldata name, address expectedRecipient) private view returns (address to) {
        if (expectedRecipient == address(0)) revert ZeroAddress();
        to = IDmdNameResolver(_ns().resolver).resolve(name);
        if (to == address(0)) revert NameNotResolvable(name);
        if (to != expectedRecipient) revert RecipientMismatch(name, to, expectedRecipient);
        _checkRecipient(to);
    }

    function _factoryAddr() internal view override returns (address) {
        return _ns().factory;
    }

    function _wdmdAddr() internal view override returns (address) {
        return _ns().wdmd;
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }

    function _ns() private pure returns (NameRouterStorage storage $) {
        assembly {
            $.slot := NAME_ROUTER_STORAGE_LOCATION
        }
    }
}
