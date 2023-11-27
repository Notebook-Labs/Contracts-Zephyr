// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../core/interfaces/IVerifier.sol";
import "../core/interfaces/IOrderbook.sol";
import "./Multicall.sol";
import "./SelfPermit.sol";
import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";

/** 
 * @title OrderbookInterface
 * @dev This is a simple contract to call placeSellOrder in the Orderbook contract. In order to use this contract, a seller
 * will call multicall to batch calls to this contract. They will need to first call a transfer function, either perimt2TransferFrom,
 * or transfer, and then will call a function to place the sell order - either placeFirstSell or placeSell.
 */
contract OrderbookInterface is SelfPermit {


    IOrderbook public immutable orderbook;
    ISignatureTransfer public immutable permit2;

    /**
     * @param _permit2 is the address of the Uniswap permit2 contract.
     */
    constructor (address _orderbook, address _permit2) {
        orderbook = IOrderbook(_orderbook);
        permit2 = ISignatureTransfer(_permit2);
    }

    /**
     * @dev called by a seller who has not yet commited to their Venmo ID in the verifier contract. This function will commit to
     * their ID in the verifier contract and then calls placeSell.
     */
    function placeFirstSellTransfer(IOrderbook.SellOrder calldata sellOrder, bytes32 venmoIdHash, uint32 maxClaimAmount, address token, uint256 amount, bool business) external {
        IVerifier verifier = IVerifier(sellOrder.verifyContract);
        verifier.onboardSeller(sellOrder.seller, venmoIdHash, business);

        IERC20(token).transferFrom(msg.sender, address(orderbook), amount);

        _placeSell(sellOrder, maxClaimAmount);
    }

    /**
     * @dev called by a seller who has not yet commited to their Venmo ID in the verifier contract. This function will commit to
     * their ID in the verifier contract and then calls placeSell.
     */
    function placeFirstSellPermit(IOrderbook.SellOrder calldata sellOrder, bytes32 venmoIdHash, uint32 maxClaimAmount, bool business, ISignatureTransfer.PermitTransferFrom calldata permit, uint256 spendAmount, bytes calldata signature) external {
        IVerifier verifier = IVerifier(sellOrder.verifyContract);
        verifier.onboardSeller(sellOrder.seller, venmoIdHash, business);

        permit2.permitTransferFrom(permit, ISignatureTransfer.SignatureTransferDetails(address(orderbook), spendAmount), msg.sender, signature); 

        _placeSell(sellOrder, maxClaimAmount);
    }


    /**
     * @dev Contract to be called by a seller who has already committed to their Venmo ID in the verifier contract (or in placeFirstSell).
     * It computes the sellKey, adds the counter to the verifier contract and then calls placeSellOrder in the Orderbook contract.
     * Used when a user wants to transfer tokens to the contract using transferFrom.
     */
    function placeSellTransfer(IOrderbook.SellOrder calldata sellOrder, uint32 maxClaimAmount, address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(orderbook), amount);

        _placeSell(sellOrder, maxClaimAmount);
    }

    /**
     * @dev Contract to be called by a seller who has already committed to their Venmo ID in the verifier contract (or in placeFirstSell).
     * It computes the sellKey, adds the counter to the verifier contract and then calls placeSellOrder in the Orderbook contract.
     * Used when a user wants to transfer tokens to the contract using permit2.
     */
    function placeSellPermit(IOrderbook.SellOrder calldata sellOrder, uint32 maxClaimAmount, ISignatureTransfer.PermitTransferFrom calldata permit, uint256 spendAmount, bytes calldata signature) external {
        permit2.permitTransferFrom(permit, ISignatureTransfer.SignatureTransferDetails(address(orderbook), spendAmount), msg.sender, signature); 

        _placeSell(sellOrder, maxClaimAmount);
    }

    /**
     * @notice internal function with logic to execute a sell order.
     */
    function _placeSell(IOrderbook.SellOrder calldata sellOrder, uint32 maxClaimAmount) internal {
        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);

        IVerifier verifier = IVerifier(sellOrder.verifyContract);
        
        verifier.addCounter(sellOrderKey);

        orderbook.placeSellOrder(sellOrder, maxClaimAmount);
    }


     /**
     * @notice getSellKey - a function which returns the sellOrderKey for a sell order.
     * @param seller - the address of the seller.
     * @param price - the price of the sell order.
     * @param token - the token of the sell order.
     * @param verifyContract - the address of the Verifier contract.
     * @param sybilContract - the address of the Sybil contract.
     * @dev This function is used to generate the sellOrderKey for a sell order.
     */
    function getSellKey(address seller, uint96 price, address token, address verifyContract, address sybilContract) public pure returns (bytes32 sellOrderKey) {
        sellOrderKey = keccak256(abi.encodePacked(seller, price, token, verifyContract, sybilContract));
    }
    
}
