// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IDmdSwapFactory} from "../interfaces/IDmdSwapFactory.sol";
import {IDmdSwapPair} from "../interfaces/IDmdSwapPair.sol";

/// @title DmdSwapLibrary
/// @notice Constant-product (x*y=k) quoting math. The fee formula here MUST stay consistent with the
///         K-check in DmdSwapPair.swap (both use BPS = 10_000). See test/DmdSwapPair.t.sol fuzz tests.
/// @dev Pair addresses are always read from the factory (never derived from an init-code hash), which
///      removes the classic "wrong INIT_CODE_HASH" deployment bug class entirely.
library DmdSwapLibrary {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_PATH_LENGTH = 5;

    error IdenticalAddresses();
    error ZeroAddress();
    error PairNotFound(address tokenA, address tokenB);
    error InsufficientAmount();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InsufficientLiquidity();
    error InvalidPath();

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        pair = IDmdSwapFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound(tokenA, tokenB);
    }

    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB, address pair)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        pair = pairFor(factory, tokenA, tokenB);
        (uint112 reserve0, uint112 reserve1,) = IDmdSwapPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice Max output for an exact input. Rounds DOWN (in favour of the pool).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * (BPS - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BPS + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Min input for an exact output. Rounds UP (in favour of the pool).
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * BPS;
        uint256 denominator = (reserveOut - amountOut) * (BPS - feeBps);
        amountIn = (numerator / denominator) + 1;
    }

    function getAmountsOut(address factory, uint256 amountIn, address[] memory path, uint256 feeBps)
        internal
        view
        returns (uint256[] memory amounts)
    {
        checkPath(path);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; ++i) {
            (uint256 reserveIn, uint256 reserveOut,) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, feeBps);
        }
    }

    function getAmountsIn(address factory, uint256 amountOut, address[] memory path, uint256 feeBps)
        internal
        view
        returns (uint256[] memory amounts)
    {
        checkPath(path);
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; --i) {
            (uint256 reserveIn, uint256 reserveOut,) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, feeBps);
        }
    }

    function checkPath(address[] memory path) internal pure {
        if (path.length < 2 || path.length > MAX_PATH_LENGTH) revert InvalidPath();
    }
}
