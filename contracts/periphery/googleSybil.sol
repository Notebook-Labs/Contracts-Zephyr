//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../core/dep/ReentrancyGuard.sol";
import "../core/interfaces/IOrderbook.sol";
import "../core/interfaces/IGoogleVerifier.sol";
import "./Multicall.sol";
import "../core/dep/Ownable.sol";

/**
 * HIGH LEVEL OVERVIEW
 * This contract is equivalent to the Sybil contract for Venmo, however it additionally includes a matching system so that claims and 'requests' 
 * can be done syncrohonously by the seller. This mechanism is to ensure incentive-compatibility in terms of the seller claiming that they are live.
 * If this was to be done off-chain, a seller could claim that they are live, the buyer would place the claim and then the seller could not commit 
 * to a transaction ID if they were in fact not live, and only commit to it when they are live - adding a staking mechanism to this would only make
 * it messy. Whereas here, a seller will have to pay gas to accept an order (pay to place claim + commit to transaction ID). Hence the profit 
 * maximising strategy would be to only pay gas if they are live + the request is legit. The caveat to this is they could automate a system which
 * accepts all claims and commits to a bogus transaction, and then later the sell order would go live and commit to a real transaction. This can be
 * fixed by the frontend only showing the buyer a single transaction request per claim, so the second claim would not be shown.
 */
contract GoogleSybil is Ownable, Multicall, ReentrancyGuard {

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
     * @notice verifer - the address of the google verifier contract that the Sybil contract points to. Used for commiting to transaction IDs.
     */
    IGoogleVerifier public immutable verifier;

    /**
     * @notice Event when a potential onramper places a claim (i.e. shows their intent to buy/place a claim on the orderbook). Any seller can then 
     * accept the claim by calling 'acceptClaim' which also commits to a transaction ID for the claim.
     */
    event ClaimPlaced(address onramperWallet, uint32 amount, uint32 maxProverFee, uint24 priceSigBits, uint8 priceShift);

    /**
     * @notice event called when a seller accepts a claim. 
     */
    event ClaimFulfilled(bytes32 claimKey);

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

    /**
     * @notice information that an onramper commits to for their buy order. They encode the usual claim information + a minimum price/value for the sell order
     * that they will be willing to accept.
     * @dev for optimisation to ensure everything can fit in one storage register, you can replace a uint96 of price to priceSigBits (24 bits) and priceShift 
     * which is 8 bits, so that you compute price as priceSigBits << priceShift. This preserves some degree of accuracy but lets this contract support tokens
     * with a range of token decimals.
     */
    struct ClaimInfo {
        address onramperWallet;
        uint32 amount;
        uint32 maxProverFee;
        uint24 priceSigBits;
        uint8 priceShift;
    }

    mapping(bytes32 => ClaimInfo) public claims; 

    constructor (address _orderbook, address _verifier, address _initialOwner, uint32 _reserveTime) {
        orderbook = IOrderbook(_orderbook);
        verifier = IGoogleVerifier(_verifier);
        transferOwnership(_initialOwner);
        reserveTime = _reserveTime;
    }

    /**
     * @notice function for an onramper to show their intent to onramp. They commit to a minimum price/value that they will be willing to accept as well
     * as the information for their claim.
     */
    function placeClaim(ClaimInfo calldata claimInfo) external {
        require(claimInfo.amount > claimInfo.maxProverFee, "1");
        bytes32 claimKey = getClaimKey(claimInfo);

        //ensure you are pushing to an index that isn't set
        require(claims[claimKey].onramperWallet == address(0), "2");
        claims[claimKey] = claimInfo;

        emit ClaimPlaced(claimInfo.onramperWallet, claimInfo.amount, claimInfo.maxProverFee, claimInfo.priceSigBits, claimInfo.priceShift);
    }

    /**
     * @notice function for a seller to accept a claim.
     * @dev this function has some innate transaction ordering risks (only one seller will be able to accept the claim - frontend will need to try to
     * limit these risks by showing the identifier of the individual to request the transaction from to only a few sellers
     */
    function acceptClaim(IOrderbook.SellOrder calldata sellOrder, bytes32 claimKey, uint256[] calldata expiredIdx, uint96 txID, uint64 sell_order_ctr) public {
        require(msg.sender == sellOrder.seller, "1");
        
        //fetch claim from claimKey
        ClaimInfo memory claimInfo = claims[claimKey];
        require(sellOrder.price > uint96(claimInfo.priceSigBits << claimInfo.priceShift), "2");

        //place claim, get index, then place transaction commitment, then delete the claim
        uint256 claim_index = orderbook.claimSellOrder(sellOrder, claimInfo.onramperWallet, claimInfo.amount, claimInfo.maxProverFee, expiredIdx);

        verifier.commitTxID(sellOrder, txID, sell_order_ctr, uint192(claim_index));

        delete claims[claimKey];

        emit ClaimFulfilled(claimKey);
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


    function getClaimKey(ClaimInfo calldata claimInfo) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(claimInfo.onramperWallet, claimInfo.amount, claimInfo.maxProverFee, claimInfo.priceSigBits, claimInfo.priceShift));
    }

}