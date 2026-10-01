// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

// Minimal views of the official DMD Naming System v1.0.0
// Source: github.com/DMDcoin/diamond-contracts-registry @ e37c376 (src/DMDRegistrarController.sol,
// src/DMDNames.sol, src/DMDRegistry.sol, src/DMDResolver.sol). Only read functions are used.

interface IDMDRegistrarControllerView {
    function names(address account) external view returns (bytes memory);
    function namesReverse(bytes32 labelHash) external view returns (address);
    function isNameBlocked(string memory name) external view returns (bool);
    function valid(string memory name) external pure returns (bool);
    function diamondNames() external view returns (address);
    function registry() external view returns (address);
    function resolver() external view returns (address);
}

interface IDMDNamesView {
    function ownerOf(uint256 tokenId) external view returns (address);
    function expired(uint256 tokenId) external view returns (bool);
    function exists(uint256 tokenId) external view returns (bool);
}

interface IDMDRegistryView {
    function owner(bytes32 node) external view returns (address);
    function resolver(bytes32 node) external view returns (address);
}

interface IDMDAddrResolverView {
    function addr(bytes32 node) external view returns (address payable);
}
