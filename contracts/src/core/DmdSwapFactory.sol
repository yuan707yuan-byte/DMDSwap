// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {DmdSwapOwnable} from "../governance/DmdSwapOwnable.sol";
import {IDmdSwapFactory} from "../interfaces/IDmdSwapFactory.sol";
import {IDmdSwapPair} from "../interfaces/IDmdSwapPair.sol";

/// @title DmdSwapFactory
/// @notice Creates/indexes pairs and holds the hard-bounded fee settings and the emergency pause.
///
/// Fee model (from the first swap): the trader pays `swapFeeBps` of the input (default 0.30 %). Of that fee:
///   - `adminShareBps` (default 25 % = 0.075 % of the trade) is paid directly to the admin wallet,
///   - `daoShareBps`   (default 25 % = 0.075 % of the trade) is paid directly to the DAO fee wallet,
///   - the rest (default 50 % = 0.15 % of the trade) stays in the pool and grows every LP position.
///   While no DAO fee wallet is set, the DAO share is paid to the admin wallet instead.
///   Hard limits: swap fee <= 1 %; admin + DAO share <= 50 % of the fee (LPs always keep at least half).
///
/// Roles:
///   - owner (the DMD DAO, via proposals): upgrades, fee rates, unpause, replacing the admin, ownership transfer.
///   - admin (a wallet): emergency pause (instant), set/replace the DAO fee wallet, hand the admin role to a new
///     wallet. The admin can never upgrade code, change fee rates or unpause.
///   Pause halts swaps / adds / pair creation ONLY — removing liquidity can never be paused.
contract DmdSwapFactory is DmdSwapOwnable, IDmdSwapFactory {
    uint16 public constant MAX_SWAP_FEE_BPS = 100;
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;

    /// @custom:storage-location erc7201:dmdswap.storage.Factory
    struct FactoryStorage {
        address pairBeacon;
        address admin;
        address daoFeeTo; // address(0) = not set yet => DAO share is paid to `admin`
        uint16 swapFeeBps;
        uint16 adminShareBps;
        uint16 daoShareBps;
        bool swapsPaused;
        mapping(address => mapping(address => address)) getPair;
        address[] allPairs;
    }

    // keccak256(abi.encode(uint256(keccak256("dmdswap.storage.Factory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FACTORY_STORAGE_LOCATION =
        0x3a9518a2f0d6955e0f2574a2e06808bbe57f7b09b934d012dc3902a872d6f700;

    error ZeroAddress();
    error IdenticalAddresses();
    error PairExists(address pair);
    error FeeTooHigh(uint256 fee, uint256 max);
    error Unauthorized();
    error Paused();
    error AlreadyInState();

    modifier onlyAdminOrOwner() {
        if (msg.sender != _getFactoryStorage().admin && msg.sender != owner()) revert Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param owner_         The DMD DAO (sole authority for upgrades and settings).
    /// @param admin_         Admin wallet: emergency pause, DAO fee wallet, receives the admin share.
    /// @param pairBeacon_    DmdSwapPairBeacon holding the DmdSwapPair implementation.
    /// @param swapFeeBps_    Swap fee in bps of the input (30 = 0.30 %).
    /// @param adminShareBps_ Admin share of the swap fee in bps (2_500 = a quarter of the fee).
    /// @param daoShareBps_   DAO share of the swap fee in bps (2_500 = a quarter of the fee).
    /// @param daoFeeTo_      DAO fee wallet, or address(0) to set it later with `setDaoFeeTo`.
    function initialize(
        address owner_,
        address admin_,
        address pairBeacon_,
        uint16 swapFeeBps_,
        uint16 adminShareBps_,
        uint16 daoShareBps_,
        address daoFeeTo_
    ) external initializer {
        if (owner_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (pairBeacon_.code.length == 0) revert NotAContract(pairBeacon_);
        __DmdSwapOwnable_init(owner_);

        FactoryStorage storage $ = _getFactoryStorage();
        $.pairBeacon = pairBeacon_;
        $.admin = admin_;
        emit AdminUpdated(address(0), admin_);
        _setSwapFee($, swapFeeBps_);
        _setFeeShares($, adminShareBps_, daoShareBps_);
        if (daoFeeTo_ != address(0)) _setDaoFeeTo($, daoFeeTo_);
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

    // ─────────────────────────────────────────────── admin (or DAO)

    /// @notice Emergency stop for swaps, liquidity adds and pair creation. Takes effect immediately.
    function pause() external onlyAdminOrOwner {
        FactoryStorage storage $ = _getFactoryStorage();
        if ($.swapsPaused) revert AlreadyInState();
        $.swapsPaused = true;
        emit SwapsPaused(msg.sender);
    }

    /// @notice Sets (or replaces) the wallet that receives the DAO share of every swap fee.
    ///         address(0) means "not set": the DAO share then goes to the admin wallet.
    function setDaoFeeTo(address newDaoFeeTo) external onlyAdminOrOwner {
        _setDaoFeeTo(_getFactoryStorage(), newDaoFeeTo);
    }

    /// @notice Hands the admin role (pause key, DAO-fee-wallet setter, admin fee receiver) to a new wallet.
    ///         One-step: effective immediately. The DAO can also call this, e.g. to replace a lost admin key.
    function transferAdmin(address newAdmin) external onlyAdminOrOwner {
        if (newAdmin == address(0)) revert ZeroAddress();
        FactoryStorage storage $ = _getFactoryStorage();
        emit AdminUpdated($.admin, newAdmin);
        $.admin = newAdmin;
    }

    // ─────────────────────────────────────────────── DAO only

    /// @notice Resumes trading. DAO only, so a stolen admin key can't unpause during an incident.
    function unpause() external onlyOwner {
        FactoryStorage storage $ = _getFactoryStorage();
        if (!$.swapsPaused) revert AlreadyInState();
        $.swapsPaused = false;
        emit SwapsUnpaused(msg.sender);
    }

    function setSwapFee(uint16 newFeeBps) external onlyOwner {
        _setSwapFee(_getFactoryStorage(), newFeeBps);
    }

    function setFeeShares(uint16 newAdminShareBps, uint16 newDaoShareBps) external onlyOwner {
        _setFeeShares(_getFactoryStorage(), newAdminShareBps, newDaoShareBps);
    }

    // ─────────────────────────────────────────────── views

    function pairBeacon() external view returns (address) {
        return _getFactoryStorage().pairBeacon;
    }

    function admin() external view returns (address) {
        return _getFactoryStorage().admin;
    }

    /// @return The DAO fee wallet, or address(0) if it hasn't been set (its share then goes to the admin).
    function daoFeeTo() external view returns (address) {
        return _getFactoryStorage().daoFeeTo;
    }

    function swapFeeBps() external view returns (uint16) {
        return _getFactoryStorage().swapFeeBps;
    }

    function adminShareBps() external view returns (uint16) {
        return _getFactoryStorage().adminShareBps;
    }

    function daoShareBps() external view returns (uint16) {
        return _getFactoryStorage().daoShareBps;
    }

    function swapsPaused() external view returns (bool) {
        return _getFactoryStorage().swapsPaused;
    }

    function swapConfig() external view returns (SwapConfig memory cfg) {
        FactoryStorage storage $ = _getFactoryStorage();
        address dao = $.daoFeeTo;
        cfg = SwapConfig({
            paused: $.swapsPaused,
            feeBps: $.swapFeeBps,
            adminFeeTo: $.admin,
            adminShareBps: $.adminShareBps,
            daoFeeTo: dao == address(0) ? $.admin : dao,
            daoShareBps: $.daoShareBps
        });
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

    function _setSwapFee(FactoryStorage storage $, uint16 newFeeBps) private {
        if (newFeeBps > MAX_SWAP_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_SWAP_FEE_BPS);
        emit SwapFeeUpdated($.swapFeeBps, newFeeBps);
        $.swapFeeBps = newFeeBps;
    }

    function _setFeeShares(FactoryStorage storage $, uint16 newAdminShareBps, uint16 newDaoShareBps) private {
        uint256 total = uint256(newAdminShareBps) + newDaoShareBps;
        if (total > MAX_PROTOCOL_SHARE_BPS) revert FeeTooHigh(total, MAX_PROTOCOL_SHARE_BPS);
        $.adminShareBps = newAdminShareBps;
        $.daoShareBps = newDaoShareBps;
        emit FeeSharesUpdated(newAdminShareBps, newDaoShareBps);
    }

    function _setDaoFeeTo(FactoryStorage storage $, address newDaoFeeTo) private {
        emit DaoFeeToUpdated($.daoFeeTo, newDaoFeeTo);
        $.daoFeeTo = newDaoFeeTo;
    }

    function _getFactoryStorage() private pure returns (FactoryStorage storage $) {
        assembly {
            $.slot := FACTORY_STORAGE_LOCATION
        }
    }
}
