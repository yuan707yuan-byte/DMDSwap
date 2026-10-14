// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IDmdSwapFactory {
    /// @notice Everything a pair needs for one swap, read in a single call.
    /// @dev `daoFeeTo` is already resolved: while no DAO fee wallet is set it equals `adminFeeTo`.
    struct SwapConfig {
        bool paused;
        uint16 feeBps;
        address adminFeeTo;
        uint16 adminShareBps;
        address daoFeeTo;
        uint16 daoShareBps;
    }

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairCount);
    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);
    event DaoFeeToUpdated(address indexed previousDaoFeeTo, address indexed newDaoFeeTo);
    event SwapFeeUpdated(uint16 previousFeeBps, uint16 newFeeBps);
    event FeeSharesUpdated(uint16 adminShareBps, uint16 daoShareBps);
    event SwapsPaused(address indexed by);
    event SwapsUnpaused(address indexed by);

    function pairBeacon() external view returns (address);
    function admin() external view returns (address);
    function daoFeeTo() external view returns (address);
    function swapFeeBps() external view returns (uint16);
    function adminShareBps() external view returns (uint16);
    function daoShareBps() external view returns (uint16);
    function swapsPaused() external view returns (bool);
    function swapConfig() external view returns (SwapConfig memory);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256 index) external view returns (address pair);
    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB) external returns (address pair);
}
