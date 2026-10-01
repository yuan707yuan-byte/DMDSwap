// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDmdSwapPair} from "../interfaces/IDmdSwapPair.sol";
import {IDmdSwapFactory} from "../interfaces/IDmdSwapFactory.sol";
import {IDmdSwapCallee} from "../interfaces/IDmdSwapCallee.sol";

/// @title DmdSwapPair
/// @notice Constant-product AMM pool + LP token (EIP-2612 permit). Logic ported from Uniswap V2 with:
///   - Solidity 0.8 checked math; TWAP accumulators explicitly `unchecked` (overflow is by design).
///   - Single fee denominator (BPS = 10_000) shared with DmdSwapLibrary — no 1000/10000 mismatch.
///   - Read-only-reentrancy guard: getReserves() reverts while the pair is mid-operation.
///   - Swaps/mints obey the factory pause; burns (LP exits) are NEVER pausable.
///   - MINIMUM_LIQUIDITY locked at 0x…dEaD (OZ ERC20 forbids minting to address(0)).
///   - Protocol fee paid DIRECTLY per swap (not lazily minted as LP): of the fee the trader pays,
///     `shareBps` (default 50 %) is transferred to `feeTo` in the input token; the rest stays for LPs.
/// @dev Deployed behind BeaconProxy. All state lives in ERC-7201 namespaced storage (upgrade-safe).
contract DmdSwapPair is ERC20PermitUpgradeable, ReentrancyGuardUpgradeable, IDmdSwapPair {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 1_000;
    uint256 private constant BPS = 10_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @custom:storage-location erc7201:dmdswap.storage.Pair
    struct PairStorage {
        address factory;
        address token0;
        address token1;
        uint112 reserve0;
        uint112 reserve1;
        uint32 blockTimestampLast;
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
    }

    // keccak256(abi.encode(uint256(keccak256("dmdswap.storage.Pair")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAIR_STORAGE_LOCATION =
        0x4653e66ab3b57af2ecbd66d149139e39ba5c31d263d1c45b0dccc0ec2deb0b00;

    error Paused();
    error Locked();
    error InvalidTokens();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
    error KInvariant();
    error Overflow();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Called once by the factory inside the BeaconProxy constructor (atomic).
    function initialize(address token0_, address token1_) external initializer {
        if (token0_ == address(0) || token0_ >= token1_) revert InvalidTokens();
        __ERC20_init("DMDSwap LP", "DMD-LP");
        __ERC20Permit_init("DMDSwap LP");
        __ReentrancyGuard_init();
        PairStorage storage $ = _s();
        $.factory = msg.sender;
        $.token0 = token0_;
        $.token1 = token1_;
    }

    // ─────────────────────────────────────────────── views

    function factory() external view returns (address) {
        return _s().factory;
    }

    function token0() external view returns (address) {
        return _s().token0;
    }

    function token1() external view returns (address) {
        return _s().token1;
    }

    /// @dev Reverts while locked so integrators can never read mid-swap (stale) reserves.
    function getReserves() external view returns (uint112, uint112, uint32) {
        if (_reentrancyGuardEntered()) revert Locked();
        PairStorage storage $ = _s();
        return ($.reserve0, $.reserve1, $.blockTimestampLast);
    }

    function price0CumulativeLast() external view returns (uint256) {
        return _s().price0CumulativeLast;
    }

    function price1CumulativeLast() external view returns (uint256) {
        return _s().price1CumulativeLast;
    }

    // ─────────────────────────────────────────────── core (call via router; low-level for integrators)

    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        PairStorage storage $ = _s();
        _swapConfigIfNotPaused($);

        (uint112 r0, uint112 r1) = ($.reserve0, $.reserve1);
        uint256 balance0 = IERC20($.token0).balanceOf(address(this));
        uint256 balance1 = IERC20($.token1).balanceOf(address(this));
        uint256 amount0 = balance0 - r0;
        uint256 amount1 = balance1 - r1;

        uint256 supply = totalSupply();
        if (supply == 0) {
            uint256 root = Math.sqrt(amount0 * amount1);
            if (root <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            liquidity = root - MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY
        } else {
            liquidity = Math.min((amount0 * supply) / r0, (amount1 * supply) / r1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Never pausable: LPs can always withdraw.
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        PairStorage storage $ = _s();
        address t0 = $.token0;
        address t1 = $.token1;
        uint256 balance0 = IERC20(t0).balanceOf(address(this));
        uint256 balance1 = IERC20(t1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 supply = totalSupply();
        amount0 = (liquidity * balance0) / supply; // pro-rata, rounds down
        amount1 = (liquidity * balance1) / supply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);
        IERC20(t0).safeTransfer(to, amount0);
        IERC20(t1).safeTransfer(to, amount1);
        balance0 = IERC20(t0).balanceOf(address(this));
        balance1 = IERC20(t1).balanceOf(address(this));

        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        PairStorage storage $ = _s();
        (uint16 feeBps, address feeTo, uint16 shareBps) = _swapConfigIfNotPaused($);
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        if (amount0Out >= $.reserve0 || amount1Out >= $.reserve1) revert InsufficientLiquidity();

        (uint256 balance0, uint256 balance1) = _sendOut($, amount0Out, amount1Out, to, data);
        // 1) full-fee K check on the trader's payment (identical to the quote math in DmdSwapLibrary)
        (uint256 amount0In, uint256 amount1In) = _inputsAndCheckK($, balance0, balance1, amount0Out, amount1Out, feeBps);
        // 2) pay the protocol share of the fee directly to feeTo; LPs keep the rest in the pool
        if (feeTo != address(0) && shareBps != 0) {
            (balance0, balance1) = _payProtocolFee($, amount0In, amount1In, feeBps, feeTo, shareBps, balance0, balance1);
        }

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice Send any surplus tokens (balance above reserves) to `to`.
    function skim(address to) external nonReentrant {
        PairStorage storage $ = _s();
        address t0 = $.token0;
        address t1 = $.token1;
        IERC20(t0).safeTransfer(to, IERC20(t0).balanceOf(address(this)) - $.reserve0);
        IERC20(t1).safeTransfer(to, IERC20(t1).balanceOf(address(this)) - $.reserve1);
    }

    /// @notice Force reserves to match balances.
    function sync() external nonReentrant {
        PairStorage storage $ = _s();
        _update(IERC20($.token0).balanceOf(address(this)), IERC20($.token1).balanceOf(address(this)));
    }

    // ─────────────────────────────────────────────── internals

    /// @dev Optimistic transfer out + optional flash-swap callback; returns post-callback balances.
    function _sendOut(
        PairStorage storage $,
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) private returns (uint256 balance0, uint256 balance1) {
        address t0 = $.token0;
        address t1 = $.token1;
        if (to == t0 || to == t1) revert InvalidTo();
        if (amount0Out > 0) IERC20(t0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(t1).safeTransfer(to, amount1Out);
        if (data.length > 0) IDmdSwapCallee(to).dmdSwapCall(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(t0).balanceOf(address(this));
        balance1 = IERC20(t1).balanceOf(address(this));
    }

    /// @dev Derives inputs from balance deltas and enforces the fee-adjusted K invariant:
    ///      (b0*1e4 - in0*fee) * (b1*1e4 - in1*fee) >= r0*r1*1e8.
    ///      Overflow-safe: balances capped at 2^112 here, so each factor < 2^126.
    function _inputsAndCheckK(
        PairStorage storage $,
        uint256 balance0,
        uint256 balance1,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 feeBps
    ) private view returns (uint256 amount0In, uint256 amount1In) {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        uint256 r0 = $.reserve0;
        uint256 r1 = $.reserve1;
        amount0In = balance0 > r0 - amount0Out ? balance0 - (r0 - amount0Out) : 0;
        amount1In = balance1 > r1 - amount1Out ? balance1 - (r1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();
        uint256 balance0Adjusted = balance0 * BPS - amount0In * feeBps;
        uint256 balance1Adjusted = balance1 * BPS - amount1In * feeBps;
        if (balance0Adjusted * balance1Adjusted < r0 * r1 * (BPS * BPS)) revert KInvariant();
    }

    function _swapConfigIfNotPaused(PairStorage storage $)
        private
        view
        returns (uint16 feeBps, address feeTo, uint16 shareBps)
    {
        bool paused;
        (paused, feeBps, feeTo, shareBps) = IDmdSwapFactory($.factory).swapConfig();
        if (paused) revert Paused();
    }

    /// @dev protocolFee_i = amountIn_i * feeBps * shareBps / 1e8 (rounded down => never more than the share).
    ///      Since shareBps <= 10_000, the protocol cut is always <= the fee the K-check already charged, so
    ///      k cannot decrease; this is re-verified on the real post-transfer balances.
    ///      If a token refuses the transfer (e.g. it blacklists feeTo), the swap still succeeds and that
    ///      fee simply stays with LPs — a misbehaving token can never brick its pool.
    function _payProtocolFee(
        PairStorage storage $,
        uint256 amount0In,
        uint256 amount1In,
        uint256 feeBps,
        address feeTo,
        uint256 shareBps,
        uint256 balance0,
        uint256 balance1
    ) private returns (uint256, uint256) {
        uint256 fee0 = (amount0In * feeBps * shareBps) / (BPS * BPS);
        uint256 fee1 = (amount1In * feeBps * shareBps) / (BPS * BPS);
        bool paid = false;
        if (fee0 != 0 && _tryTransfer($.token0, feeTo, fee0)) {
            emit ProtocolFeePaid($.token0, feeTo, fee0);
            paid = true;
        }
        if (fee1 != 0 && _tryTransfer($.token1, feeTo, fee1)) {
            emit ProtocolFeePaid($.token1, feeTo, fee1);
            paid = true;
        }
        if (!paid) return (balance0, balance1);
        balance0 = IERC20($.token0).balanceOf(address(this));
        balance1 = IERC20($.token1).balanceOf(address(this));
        if (balance0 * balance1 < uint256($.reserve0) * $.reserve1) revert KInvariant();
        return (balance0, balance1);
    }

    /// @dev Non-reverting ERC-20 transfer (tokens with or without a bool return). Copies at most 32
    ///      bytes of return data, so a hostile token cannot "return-bomb" the pair.
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool success) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0x00, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0x00)
        }
        if (!success) return false;
        if (returnSize == 0) return token.code.length != 0;
        return returnSize >= 32 && returnValue == 1;
    }

    /// @dev Writes new reserves (balances) and accrues the TWAP using the OLD reserves.
    function _update(uint256 balance0, uint256 balance1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        PairStorage storage $ = _s();
        uint112 r0 = $.reserve0;
        uint112 r1 = $.reserve1;
        uint32 blockTimestamp = uint32(block.timestamp); // truncation mod 2^32 is intended
        unchecked {
            uint32 timeElapsed = blockTimestamp - $.blockTimestampLast; // wraps by design
            if (timeElapsed > 0 && r0 != 0 && r1 != 0) {
                // UQ112x112 price * seconds; accumulator overflow is intended (consumers diff).
                $.price0CumulativeLast += ((uint256(r1) << 112) / r0) * timeElapsed;
                $.price1CumulativeLast += ((uint256(r0) << 112) / r1) * timeElapsed;
            }
        }
        $.reserve0 = uint112(balance0);
        $.reserve1 = uint112(balance1);
        $.blockTimestampLast = blockTimestamp;
        emit Sync(uint112(balance0), uint112(balance1));
    }

    function _s() private pure returns (PairStorage storage $) {
        assembly {
            $.slot := PAIR_STORAGE_LOCATION
        }
    }
}
