// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {IDmdSwapFactory} from "../interfaces/IDmdSwapFactory.sol";
import {IDmdSwapPair} from "../interfaces/IDmdSwapPair.sol";

/// @title DmdSwapFactory
/// @notice Creates/indexes pairs and holds global, hard-bounded fee parameters.
/// @dev UUPS-upgradeable; owner MUST be the 24h TimelockController. Pairs are BeaconProxies whose logic
///      is upgraded via the UpgradeableBeacon (also owned by the timelock).
///      Fee model: trader pays `swapFeeBps` (default 0.30 %). `protocolFeeShareBps` of it (default 50 %)
///      is transferred DIRECTLY to `feeTo` (the admin) inside every swap; the rest stays in the pool for LPs.
///      Hard limits: swap fee <= 1 %, protocol share <= 50 % of the swap fee.
///      Pause halts swaps / adds / pair creation ONLY — removing liquidity can never be paused.
contract DmdSwapFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IDmdSwapFactory {
    uint16 public constant MAX_SWAP_FEE_BPS = 100;
    uint16 public constant MAX_PROTOCOL_FEE_SHARE_BPS = 5_000;

    /// @custom:storage-location erc7201:dmdswap.storage.Factory
    struct FactoryStorage {
        address pairBeacon;
        address feeTo;
        address guardian;
        uint16 swapFeeBps;
        uint16 protocolFeeShareBps;
        bool swapsPaused;
        mapping(address => mapping(address => address)) getPair;
        address[] allPairs;
    }

    // keccak256(abi.encode(uint256(keccak256("dmdswap.storage.Factory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FACTORY_STORAGE_LOCATION =
        0x3a9518a2f0d6955e0f2574a2e06808bbe57f7b09b934d012dc3902a872d6f700;

    error ZeroAddress();
    error IdenticalAddresses();
    error NotAContract(address account);
    error PairExists(address pair);
    error FeeTooHigh(uint256 fee, uint256 max);
    error Unauthorized();
    error Paused();
    error AlreadyInState();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param owner_      TimelockController (sole upgrade/parameter authority).
    /// @param guardian_   Emergency key that can ONLY pause (instant, no timelock).
    /// @param pairBeacon_ UpgradeableBeacon holding the DmdSwapPair implementation.
    /// @param swapFeeBps_ Initial swap fee in bps (30 = 0.30 %).
    /// @param feeTo_      Receives the protocol share of every swap fee directly (the admin wallet).
    /// @param protocolFeeShareBps_ Protocol share of the swap fee in bps (5_000 = half).
    function initialize(
        address owner_,
        address guardian_,
        address pairBeacon_,
        uint16 swapFeeBps_,
        address feeTo_,
        uint16 protocolFeeShareBps_
    ) external initializer {
        if (owner_ == address(0) || guardian_ == address(0) || pairBeacon_ == address(0)) revert ZeroAddress();
        if (pairBeacon_.code.length == 0) revert NotAContract(pairBeacon_);
        if (swapFeeBps_ > MAX_SWAP_FEE_BPS) revert FeeTooHigh(swapFeeBps_, MAX_SWAP_FEE_BPS);
        if (protocolFeeShareBps_ > MAX_PROTOCOL_FEE_SHARE_BPS) {
            revert FeeTooHigh(protocolFeeShareBps_, MAX_PROTOCOL_FEE_SHARE_BPS);
        }
        if (protocolFeeShareBps_ != 0 && feeTo_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        FactoryStorage storage $ = _getFactoryStorage();
        $.pairBeacon = pairBeacon_;
        $.guardian = guardian_;
        $.swapFeeBps = swapFeeBps_;
        $.feeTo = feeTo_;
        $.protocolFeeShareBps = protocolFeeShareBps_;

        emit GuardianUpdated(address(0), guardian_);
        emit SwapFeeUpdated(0, swapFeeBps_);
        emit FeeToUpdated(address(0), feeTo_);
        emit ProtocolFeeShareUpdated(0, protocolFeeShareBps_);
    }

    // ─────────────────────────────────────────────── pair creation

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        FactoryStorage storage $ = _getFactoryStorage();
        if ($.swapsPaused) revert Paused();
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        // No pairs for EOAs / not-yet-deployed (counterfactual) token addresses.
        if (token0.code.length == 0) revert NotAContract(token0);
        if (token1.code.length == 0) revert NotAContract(token1);
        address existing = $.getPair[token0][token1];
        if (existing != address(0)) revert PairExists(existing);

        // initialize() executes inside the proxy constructor => atomic, cannot be front-run.
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        pair = address(
            new BeaconProxy{salt: salt}($.pairBeacon, abi.encodeCall(IDmdSwapPair.initialize, (token0, token1)))
        );

        $.getPair[token0][token1] = pair;
        $.getPair[token1][token0] = pair;
        $.allPairs.push(pair);
        emit PairCreated(token0, token1, pair, $.allPairs.length);
    }

    // ─────────────────────────────────────────────── governance (timelock-only)

    function setFeeTo(address newFeeTo) external onlyOwner {
        FactoryStorage storage $ = _getFactoryStorage();
        emit FeeToUpdated($.feeTo, newFeeTo);
        $.feeTo = newFeeTo; // address(0) disables the protocol fee (100 % of the fee then stays with LPs)
    }

    function setSwapFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_SWAP_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_SWAP_FEE_BPS);
        FactoryStorage storage $ = _getFactoryStorage();
        emit SwapFeeUpdated($.swapFeeBps, newFeeBps);
        $.swapFeeBps = newFeeBps;
    }

    function setProtocolFeeShare(uint16 newShareBps) external onlyOwner {
        if (newShareBps > MAX_PROTOCOL_FEE_SHARE_BPS) revert FeeTooHigh(newShareBps, MAX_PROTOCOL_FEE_SHARE_BPS);
        FactoryStorage storage $ = _getFactoryStorage();
        emit ProtocolFeeShareUpdated($.protocolFeeShareBps, newShareBps);
        $.protocolFeeShareBps = newShareBps;
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        FactoryStorage storage $ = _getFactoryStorage();
        emit GuardianUpdated($.guardian, newGuardian);
        $.guardian = newGuardian;
    }

    /// @notice Emergency stop (guardian or owner, takes effect immediately).
    function pause() external {
        FactoryStorage storage $ = _getFactoryStorage();
        if (msg.sender != $.guardian && msg.sender != owner()) revert Unauthorized();
        if ($.swapsPaused) revert AlreadyInState();
        $.swapsPaused = true;
        emit SwapsPaused(msg.sender);
    }

    /// @notice Resume trading. Owner (timelock) only — a stolen guardian key can't unpause mid-incident.
    function unpause() external onlyOwner {
        FactoryStorage storage $ = _getFactoryStorage();
        if (!$.swapsPaused) revert AlreadyInState();
        $.swapsPaused = false;
        emit SwapsUnpaused(msg.sender);
    }

    // ─────────────────────────────────────────────── views

    function pairBeacon() external view returns (address) {
        return _getFactoryStorage().pairBeacon;
    }

    function feeTo() external view returns (address) {
        return _getFactoryStorage().feeTo;
    }

    function guardian() external view returns (address) {
        return _getFactoryStorage().guardian;
    }

    function swapFeeBps() external view returns (uint16) {
        return _getFactoryStorage().swapFeeBps;
    }

    function protocolFeeShareBps() external view returns (uint16) {
        return _getFactoryStorage().protocolFeeShareBps;
    }

    function swapsPaused() external view returns (bool) {
        return _getFactoryStorage().swapsPaused;
    }

    /// @notice One-call read used by pairs on every swap/mint.
    function swapConfig() external view returns (bool paused, uint16 feeBps, address feeTo_, uint16 shareBps) {
        FactoryStorage storage $ = _getFactoryStorage();
        return ($.swapsPaused, $.swapFeeBps, $.feeTo, $.protocolFeeShareBps);
    }

    /// @notice One-call read used by pairs when accruing the protocol fee.
    function protocolFeeConfig() external view returns (address feeTo_, uint16 shareBps) {
        FactoryStorage storage $ = _getFactoryStorage();
        return ($.feeTo, $.protocolFeeShareBps);
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _getFactoryStorage().getPair[tokenA][tokenB];
    }

    function allPairs(uint256 index) external view returns (address) {
        return _getFactoryStorage().allPairs[index];
    }

    function allPairsLength() external view returns (uint256) {
        return _getFactoryStorage().allPairs.length;
    }

    // ─────────────────────────────────────────────── internals

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }

    function _getFactoryStorage() private pure returns (FactoryStorage storage $) {
        assembly {
            $.slot := FACTORY_STORAGE_LOCATION
        }
    }
}
