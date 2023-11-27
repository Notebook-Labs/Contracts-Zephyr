// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "./dep/Ownable.sol";
import "./dep/ERC20.sol";

interface IProverFee {
    //returns a fee in the token for the given price and amount
    function calculateFee(address token, uint96 price, uint32 amount) external view returns (uint128); 
}

contract ProverFee is IProverFee, Ownable {
    mapping(address => uint128) public _fees; // fee in native token decimals

    // set the owner to the timelock contract
    constructor(address _owner) {
        transferOwnership(_owner);
    }

    function setFee(address token, uint32 fee) external onlyOwner {
        _fees[token] = fee;
    }

    function calculateFee(address token, uint96 price, uint32 amount) external view returns (uint128) {
        return _fees[token];
    }
}