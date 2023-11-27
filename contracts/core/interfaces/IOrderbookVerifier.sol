// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

//interface containing only the functions of verifier that the orderbook needs to call
interface IOrderbookVerifier {

    function calculateProverFee(address token, uint96 price, uint32 amount, address prover) external view returns (uint128);

    function verifyPayment(bytes32 proofNullifier, uint256 sellOrderIndex, uint256 claimIndex) external returns (address, bytes32);

}