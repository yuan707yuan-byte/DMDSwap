// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IDmdSwapFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairCount);
    event FeeToUpdated(address indexed previousFeeTo, address indexed newFeeTo);
    event SwapFeeUpdated(uint16 previousFeeBps, uint16 newFeeBps);
    event ProtocolFeeShareUpdated(uint16 previousShareBps, uint16 newShareBps);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event SwapsPaused(address indexed by);
    event SwapsUnpaused(address indexed by);

    function pairBeacon() external view returns (address);
    function feeTo() external view returns (address);
    function guardian() external view returns (address);
    function swapFeeBps() external view returns (uint16);
    function protocolFeeShareBps() external view returns (uint16);
    function swapsPaused() external view returns (bool);
    function swapConfig() external view returns (bool paused, uint16 feeBps, address feeRecipient, uint16 shareBps);
    function protocolFeeConfig() external view returns (address feeRecipient, uint16 shareBps);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256 index) external view returns (address pair);
    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB) external returns (address pair);
}
