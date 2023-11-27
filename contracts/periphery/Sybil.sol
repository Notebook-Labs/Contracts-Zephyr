//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../core/dep/ReentrancyGuard.sol";
import "../core/interfaces/IOrderbook.sol";
import "../core/interfaces/IVerifier.sol";
import "./Multicall.sol";
import "../core/dep/Ownable.sol";

/**
 * @title Sybil
 * @notice Sybil contract which allows sellers to schedule operations on their sell orders and helps buyers place claims.
 * @dev When a seller places a sell order they can specify to have a sybil contract or not. The purpose of the Sybil contract is twofold. 
 * First, it allows sellers to schedule operations on their sell orders. It's not possible for a seller to instantaeneously change their price
 * close their order as some buyers may have pending claims. Therefore, it is important that when a seller wishes to change their order, they 
 * leave a buffer of time to ensure that all active claims are completed or expire. This means that if the Seller wishes to change their price, 
 * they must execute two transactions: one to schedule the price change and one to execute the price change. If the seller wishes, they can execute 
 * a single transaction to schedule the price change through the Sybil contract, and when the delay is over, anyone can execute the price change. The
 * second purpose of the Sybil contract is sybil prevention for sellers. If a seller wishes to set a Sybil contract on their sell order, all claims will
 * have to be placed through the contract. Note that the actual funds never flow through the Sybil contract and once a claim is placed, unlocking funds
 * is fully permissionless. Placing claims through the Sybil contract does not add any security, it will only rate limit buyers to ensure that they do not
 * repeatedly claim funds without making executing the orders.
 */
contract Sybil is Ownable, Multicall, ReentrancyGuard {

    /** 
     * @notice reserveTime - the amount of time in seconds after a buyer has placed a claim that funds on a sell order are reserved for. 
     * @dev This ensures that if a seller changesPrice or closes the order, that no buys are currently active.
     * This should be set to give the buyer enough time to unlock their funds after they have placed a claim. Before a seller can close or
     * change the price of the position, they must wait until all orders on their position are expired, after pausing their order. Hence this
     * value is also used to check expiry of orders in those functions.
     */
    uint32 public immutable reserveTime;

    /**
     * @notice orderbook - the address of the orderbook contract that the Sybil contract points to.
     */
    IOrderbook public immutable orderbook;

    /**
     * @notice OperationScheduled - event is emitted when a Seller schedules an operation on their sell order.
     * @dev The timestamp of the operation can be derived from the block number
     */
    event OperationScheduled(bytes32 sellOrderKey, uint32 id, uint96 data); 
   
    /**
     * @notice OperationCanceled - event is emitted when a Seller cancels an operation on their sell order.
     */
    event OperationCanceled(bytes32 sellOrderKey); 

    /**
     * @notice CloseExecuted - event is emitted when the Sybil contract closes a sell order after it was scheduled to be closed.
     */
    event CloseExecuted(bytes32 sellOrderKey);

    /**
     * @notice PriceExecuted - event is emitted when the Sybil contract changes the price of a sell order after it was scheduled to be changed.
     */
    event PriceExecuted(bytes32 sellOrderKey);

    /**
     * @notice scheduledOperation - mapping of sellOrderKey to Operation struct.
     * @dev The Operation struct contains the id of the operation, the timestamp of when the operation becomes valid, and the data of the operation.
     * It is used to store a scheduled operation so that anyone can execute it through the Sybil contract after the delay has passed.
     */
    mapping(bytes32 => Operation) public scheduledOperation;

    struct Operation {
        uint32 id; //0 = unscheduled, 1 = close, 2 = changePrice
        uint32 timestamp; //when operation becomes valid
        uint96 data; //either new_price or transfer_amount
    }

    constructor (address _orderbook, address _initialOwner, uint32 _reserveTime) {
        orderbook = IOrderbook(_orderbook);
        transferOwnership(_initialOwner);
        reserveTime = _reserveTime;
    }

    /**
     * @notice claimSellOrder - a wrapper to place a claim on a sell order.
     * @param sellOrder - the sell order that the buyer is claiming against.
     * @dev This function is permissioned to the owner of the Sybil contract for Sybil prevention. Intended to be called via a multicall. 
     * There are no Reentrancy vulnerabilities provided that the whitelisted orderbook contract is the one in ../contract/core.
     */
    function claimSellOrder(IOrderbook.SellOrder calldata sellOrder, address onramperWallet, uint32 amount, uint32 maxProverFee, uint256[] calldata expiredIdx) public onlyOwner {
        orderbook.claimSellOrder(sellOrder, onramperWallet, amount, maxProverFee, expiredIdx);
    }

    /**
     * @notice scheduleOperation - a function which allows a seller to schedule an operation on their sell order.
     * @param sellOrder - the sell order that the seller is scheduling an operation on.
     * @param id - the id of the operation. 1 = close, 2 = changePrice
     * @param data - the data of the operation. This is only relevant for changePrice and denotes the new price. 
     * @dev For security, we require the seller to call scheduleCloseSell on the Orderbook contract themselves before calling this function.  
     */
    function scheduleOperation(IOrderbook.SellOrder calldata sellOrder, uint32 id, uint96 data) external nonReentrant {
        require(msg.sender == sellOrder.seller, "1");
        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);

        // verify the operation id
        require(id == 1 || id == 2, "2");

        //store a hash of the intended transaction
        scheduledOperation[sellOrderKey] = Operation(id, uint32(block.timestamp) + reserveTime, data);
        emit OperationScheduled(sellOrderKey, id, data);
    }

    /**
     * @notice cancelOperation - a function which allows a seller to cancel an operation on their sell order.
     * @param sellOrder - the sell order that the seller is canceling an operation on. 
     */
    function cancelOperation(IOrderbook.SellOrder calldata sellOrder) external nonReentrant {
        require(msg.sender == sellOrder.seller, "1");

        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);
        delete scheduledOperation[sellOrderKey];

        orderbook.cancelScheduleCloseSell(sellOrder);
        
        emit OperationCanceled(sellOrderKey);
    }

    /**
     * @notice executeClose - a function which allows anyone to close a sell order after it was scheduled to be closed.
     * @param sellOrder - the sell order that is being closed.
     * @dev This function is permissionless so that anyone can execute it after the delay has passed.
     */
    function executeClose(IOrderbook.SellOrder calldata sellOrder) public nonReentrant {
        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);
        Operation memory operation = scheduledOperation[sellOrderKey];

        // Ensure that the seller intended to close the order and that the required time has elapsed
        require(operation.id == 1, "3");
        require(uint32(block.timestamp) >= operation.timestamp, "4");

        delete scheduledOperation[sellOrderKey];

        orderbook.closeSellOrder(sellOrder);

        emit CloseExecuted(sellOrderKey);
    }

    /**
     * @notice executePrice - a function which allows anyone to change the price of a sell order after it was scheduled to be changed.
     * @param sellOrder - the sell order that is having its price changed.
     * @dev This function is permissionless so that anyone can execute it after the delay has passed.
     */
    function executePrice(IOrderbook.SellOrder calldata sellOrder) public nonReentrant {
        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);
        
        Operation memory operation = scheduledOperation[sellOrderKey];

        // Ensure that the seller intended to close the order and that the required time has elapsed
        require(operation.id == 2, "3");
        require(uint32(block.timestamp) >= operation.timestamp, "4");

        delete scheduledOperation[sellOrderKey];
        
        orderbook.updateSellPrice(sellOrder, operation.data);
        orderbook.cancelScheduleCloseSell(sellOrder);

        // Whitelist the seller's new sell order on the Verifier contract
        bytes32 newKey = getSellKey(sellOrder.seller, operation.data, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);
        IVerifier(sellOrder.verifyContract).addCounter(newKey);

        emit PriceExecuted(sellOrderKey);
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
    function getSellKey(address seller, uint96 price, address token, address verifyContract, address sybilContract) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(seller, price, token, verifyContract, sybilContract));
    }

}