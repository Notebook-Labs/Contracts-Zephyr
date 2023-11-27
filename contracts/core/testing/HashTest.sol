// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title HashTest
 * @notice Contract to test the solidity SHA256 function.
 */
contract HashTest {
    function calculateHash(bytes calldata input) public pure returns (bytes32) {
        return sha256(input);
    }
}
