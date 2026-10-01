// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IDmdNameResolver} from "../interfaces/IDmdNameResolver.sol";
import {
    IDMDRegistrarControllerView,
    IDMDNamesView,
    IDMDRegistryView,
    IDMDAddrResolverView
} from "../interfaces/external/IDMDNamesSystem.sol";

/// @title DmdNameResolver
/// @notice Fund-safe resolution of DMD Names (official DMDcoin/diamond-contracts-registry v1.0.0).
/// @dev A name resolves ONLY if every independent source agrees — otherwise address(0):
///        1. syntax is valid (identical rules to DMDRegistrarController.valid)
///        2. the configured controller is still the live owner of the `.dmd` node
///        3. registry -> resolver -> addr(node) forward record is set
///        4. the ERC-721 owner of the name equals that address
///        5. the name is NOT expired (DMD does not auto-clear expired records!)
///        6. the controller's active-name index points to the same address
///        7. the name is not blocked by DAO moderation
///      All external reads are gas-capped staticcalls with strict return-data validation, so a
///      faulty/upgraded DMD contract can only make resolution fail closed — never revert or mis-resolve.
contract DmdNameResolver is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IDmdNameResolver {
    /// @notice namehash("dmd") — NameUtils.DMD_NODE in the official registry.
    bytes32 public constant DMD_NODE = 0x9904bf4b5751e3b6a8b75d14c49424160de1a8fa8a90fd5c9fccdeac0503e612;
    uint256 public constant MIN_NAME_LENGTH = 2;
    uint256 public constant MAX_NAME_LENGTH = 63;
    uint256 private constant CALL_GAS = 100_000;

    /// @custom:storage-location erc7201:dmdswap.storage.NameResolver
    struct ResolverStorage {
        address controller;
        address names;
        address registry;
        bool enabled;
    }

    // keccak256(abi.encode(uint256(keccak256("dmdswap.storage.NameResolver")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RESOLVER_STORAGE_LOCATION =
        0x90f5aa5c8216b654c54d09f0c0445f3f59592e6155722f77b3d986c137b47000;

    event NamesSystemUpdated(address indexed controller, address indexed names, address indexed registry);
    event ResolutionEnabled(bool enabled);

    error ZeroAddress();
    error NotAContract(address account);
    error InconsistentNamesSystem();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param owner_      24h TimelockController.
    /// @param controller_ DMDRegistrarController proxy (mainnet: 0x04847f99aD1312aFFB1cc6A03a53FEB5fEdd282B).
    function initialize(address owner_, address controller_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        _setController(controller_);
        _s().enabled = true;
        emit ResolutionEnabled(true);
    }

    // ─────────────────────────────────────────────── governance

    /// @notice Re-point to a new DMD registrar controller (e.g. after a DMD DAO migration).
    function setController(address controller_) external onlyOwner {
        _setController(controller_);
    }

    function setEnabled(bool enabled_) external onlyOwner {
        _s().enabled = enabled_;
        emit ResolutionEnabled(enabled_);
    }

    // ─────────────────────────────────────────────── views

    function namesSystem() external view returns (address controller, address names, address registry, bool enabled) {
        ResolverStorage storage $ = _s();
        return ($.controller, $.names, $.registry, $.enabled);
    }

    function resolve(string calldata name) external view returns (address) {
        return _resolve(name);
    }

    /// @notice Reverse lookup, forward-verified: returns the label only if it resolves back to `account`.
    function activeNameOf(address account) external view returns (string memory) {
        ResolverStorage storage $ = _s();
        if (!$.enabled || account == address(0)) return "";
        (bool ok, bytes memory ret) =
            _readBounded($.controller, abi.encodeCall(IDMDRegistrarControllerView.names, (account)), 256);
        if (!ok || ret.length < 64) return "";
        try this.decodeBytes(ret) returns (bytes memory label) {
            string memory name = string(label);
            if (_resolve(name) == account) return name;
        } catch {}
        return "";
    }

    /// @dev Helper so malformed return data can be decoded inside try/catch. Pure, no state access.
    function decodeBytes(bytes calldata data) external pure returns (bytes memory) {
        return abi.decode(data, (bytes));
    }

    /// @notice Byte-for-byte the rules of DMDRegistrarController.valid(): 2-63 chars of [a-z0-9-],
    ///         starts and ends alphanumeric, no "--". Uppercase is INVALID (UI must lowercase).
    function isValidName(string memory name) public pure returns (bool) {
        bytes memory b = bytes(name);
        uint256 len = b.length;
        if (len < MIN_NAME_LENGTH || len > MAX_NAME_LENGTH) return false;
        if (!_isAlphaNum(b[0]) || !_isAlphaNum(b[len - 1])) return false;
        for (uint256 i = 1; i < len; ++i) {
            bytes1 c = b[i];
            bool hyphen = c == 0x2d;
            if (!hyphen && !_isAlphaNum(c)) return false;
            if (hyphen && b[i - 1] == 0x2d) return false;
        }
        return true;
    }

    // ─────────────────────────────────────────────── internals

    function _resolve(string memory name) private view returns (address account) {
        ResolverStorage storage $ = _s();
        if (!$.enabled || !isValidName(name)) return address(0);

        bytes32 label = keccak256(bytes(name));
        bytes32 node = keccak256(abi.encodePacked(DMD_NODE, label));
        address registry = $.registry;
        address controller = $.controller;

        // (2) configured controller must still be the live `.dmd` registrar
        if (_readAddress(registry, abi.encodeCall(IDMDRegistryView.owner, (DMD_NODE))) != controller) {
            return address(0);
        }
        // (3) forward record
        address res = _readAddress(registry, abi.encodeCall(IDMDRegistryView.resolver, (node)));
        if (res == address(0)) return address(0);
        account = _readAddress(res, abi.encodeCall(IDMDAddrResolverView.addr, (node)));
        if (account == address(0)) return address(0);
        // (4) NFT owner agrees, (5) not expired
        uint256 tokenId = uint256(label);
        if (_readAddress($.names, abi.encodeCall(IDMDNamesView.ownerOf, (tokenId))) != account) return address(0);
        (bool ok, bool flag) = _readBool($.names, abi.encodeCall(IDMDNamesView.expired, (tokenId)));
        if (!ok || flag) return address(0);
        // (6) controller's active-name index agrees, (7) not blocked
        if (_readAddress(controller, abi.encodeCall(IDMDRegistrarControllerView.namesReverse, (label))) != account) {
            return address(0);
        }
        (ok, flag) = _readBool(controller, abi.encodeCall(IDMDRegistrarControllerView.isNameBlocked, (name)));
        if (!ok || flag) return address(0);
    }

    function _setController(address controller_) private {
        if (controller_.code.length == 0) revert NotAContract(controller_);
        address names = _readAddress(controller_, abi.encodeCall(IDMDRegistrarControllerView.diamondNames, ()));
        address registry = _readAddress(controller_, abi.encodeCall(IDMDRegistrarControllerView.registry, ()));
        if (names.code.length == 0 || registry.code.length == 0) revert InconsistentNamesSystem();
        if (_readAddress(registry, abi.encodeCall(IDMDRegistryView.owner, (DMD_NODE))) != controller_) {
            revert InconsistentNamesSystem();
        }
        ResolverStorage storage $ = _s();
        $.controller = controller_;
        $.names = names;
        $.registry = registry;
        emit NamesSystemUpdated(controller_, names, registry);
    }

    /// @dev Gas-capped staticcall returning one 32-byte word. Never copies more than 32 bytes
    ///      (no return-bomb); `ok` is false unless the call succeeded with exactly 32 bytes.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(CALL_GAS, target, add(data, 0x20), mload(data), 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        if (size != 32) ok = false;
    }

    /// @dev Expects one ABI-encoded address. Any anomaly => address(0).
    function _readAddress(address target, bytes memory data) private view returns (address) {
        (bool ok, uint256 v) = _readWord(target, data);
        if (!ok || v >> 160 != 0) return address(0);
        return address(uint160(v));
    }

    /// @dev Expects one ABI-encoded bool. Any anomaly => ok = false.
    function _readBool(address target, bytes memory data) private view returns (bool ok, bool value) {
        uint256 v;
        (ok, v) = _readWord(target, data);
        if (!ok || v > 1) return (false, false);
        return (true, v == 1);
    }

    /// @dev Gas-capped staticcall that refuses (instead of copying) return data larger than `maxLen`.
    function _readBounded(address target, bytes memory data, uint256 maxLen)
        private
        view
        returns (bool ok, bytes memory ret)
    {
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(CALL_GAS, target, add(data, 0x20), mload(data), 0x00, 0x00)
            size := returndatasize()
        }
        if (!ok || size > maxLen) return (false, ret);
        ret = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(ret, 0x20), 0x00, size)
        }
    }

    function _isAlphaNum(bytes1 c) private pure returns (bool) {
        return (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39); // a-z | 0-9
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }

    function _s() private pure returns (ResolverStorage storage $) {
        assembly {
            $.slot := RESOLVER_STORAGE_LOCATION
        }
    }
}
