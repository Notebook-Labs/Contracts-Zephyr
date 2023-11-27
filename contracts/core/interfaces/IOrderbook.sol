// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

/**
 * @dev Interface for the orderbook contract. 
 */
interface IOrderbook {

    struct SellOrder {
        address seller;
        uint96 price; 
        address token;
        address verifyContract; 
        address sybilContract;  
    }

    //timestamp is 0 if the claim is deleted and is otherwise the timestamp of the block the claim was placed at
    struct ClaimDigest { 
        address onramperWallet;
        uint32 maxProverFee; 
        uint32 amount; 
        uint32 timestamp;
    }

    struct Amounts {
        uint128 amount;
        uint64 totalReserved; 
        uint32 scheduleCloseTimestamp; 
        uint32 maxClaimAmount; 
    }


    function placeSellOrder(SellOrder calldata sellOrder, uint32 maxClaimAmount) external;

    function claimSellOrder(SellOrder calldata sellOrder, address onramperWallet, uint32 amount, uint32 maxProverFee, uint256[] calldata expiredIdx) external returns (uint256 claimIndex);

    function unlockFunds(SellOrder calldata sellOrder, uint256 sellOrderIndex, uint256 claimIndex, bytes32 proofNullifier) external returns (uint128 transferAmount);

    function transferUnreserved(SellOrder calldata sellOrder, uint128 transferAmount) external;

    function scheduleCloseSell(SellOrder calldata sellOrder) external;

    function cancelScheduleCloseSell(SellOrder calldata sellOrder) external;

    function closeSellOrder(SellOrder calldata sellOrder) external;

    function updateSellPrice(SellOrder calldata sellOrder, uint96 newPrice) external;

    function addTokens(address[] calldata tokens) external;

    function addInterfaces(address[] calldata interfaces) external;

    function removeTokens(address[] calldata tokens) external;

    function removeInterfaces(address[] calldata interfaces) external;

    /**
     * @dev Emitted when a claim was placed against a sell order.
     * @param sellOrderKey The key of the sell order.
     * @param claimIndex The index of the claim in the onRampClaims array.
     * @param onramperWallet The address of the wallet to receive unlocked funds.
     */
    event ClaimPlaced(bytes32 indexed sellOrderKey, uint256 claimIndex, address onramperWallet, uint32 amount, uint32 maxProverFee);

    /**
     * @dev Emitted when a claim is deleted.
     * @param sellOrderKey The key of the sell order.
     * @param index The index of the claim in the onrampClaims array.
     */
    event ClaimDeleted(bytes32 indexed sellOrderKey, uint256 index);

    /**
     * @dev Emitted during unlockFunds after funds have been transfered out of the sellOrder to the onramper.
     */
    event PaymentComplete(bytes32 indexed sellOrderKey, uint256 claimIndex);

    /**
     * @dev Emitted when a new sell order is placed.
     */
    event NewSellOrder(address indexed seller, uint128 amount, uint96 price, address token, address verifyContract, address sybilContract, uint32 maxClaimAmount);

    /**
     * @dev Emitted when the amount of a sell order is increased through placeSellOrder.
     */
    event IncreaseAmount(bytes32 indexed sellOrderKey, uint128 amount);

    /**
     * @dev Emitted when the amount of a sell order is decreased through transferUnreserved by less than the total unreserved amount.
     */
    event DecreaseAmount(bytes32 indexed sellOrderKey, uint128 amount);

    /**
     * @dev Emitted when the amount of a sell order is decreased through transferUnreserved by the entire unreserved amount of the sell order.
     */
    event DecreaseAmountFull(bytes32 indexed sellOrderKey, uint128 amount);

    /**
     * @dev Emitted when a sell order is closed.
     */
    event SellOrderClosed(bytes32 indexed sellOrderKey);

    /**
     * @dev Emitted when a sell order is closed because it's price has changed and a new sell order has opened. 
     * @param sellOrderKey is the sellOrderKey of the sellOrder which just closed. The new sellOrder is emitted through either newSellOrder or increaseAmount 
     * in the same transaction.
     */
    event ChangePrice(bytes32 indexed sellOrderKey);


    /**
     * @dev Emitted when a close is scheduled.
     */
    event CloseScheduled(bytes32 indexed sellOrderKey);

    /**
     * @dev Emitted when a scheduling of a close is cancelled.
     */
    event CloseCancelled(bytes32 indexed sellOrderKey);

}