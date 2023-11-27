// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "./dep/ERC20.sol";
import "./dep/SafeERC20.sol";
import "./dep/ReentrancyGuard.sol";
import "./dep/Ownable.sol";
import "./interfaces/IOrderbookVerifier.sol";
import "./interfaces/IOrderbook.sol";

/**
 * @title Orderbook
 * @notice This contract is used to store sell orders and claims. Each seller, places a sell-order and can optionally permission the
 * right to claim their order to a 'sybilContract'. The seller also specifies a 'verifyContract' which is used to verify proofs of 
 * payments which are used by buyers to unlock their claims.
 * @dev This contract is build to abstract away proof verification and sybil-prevention which are handled on the verifier and sybil 
 * contracts. This also means that multiple payment methods and tokens which use different sybil contracts and verifiers could be
 * supported by a single orderbook. This contract follows a simple bulletin-board design where orders are posted but all routing logic
 * happens off-chain. It is up to the buyer to find a sell order and ensure that the seller correctly configured the rules to place a
 * claim and unlock funds on the sybil contract and verifier. The types used for values are as followed:
 * unit32 - All timestamps use uint32 to represent the unix timestamp. All timestamp comparisons are only done relative to block.timestamp 
 * and reserveTime (which should be ~1 hour) hence over and underflowing are unlikely. maxProverFee and the value of claims are also uint32
 * which is large enough given that these values are in cents and most payment providers cap the size of an individual transaction.
 * uint64 - totalReserved is a uint64 which is large enough to store the total amount of cents that can be reserved on a sell order. A 
 * seller could configure amount and price such that in  certain cases, UINT64_MAX worth of cents is reserved by a given sell order. The 
 * only affect of this is that no further claims can be placed (placing additional claims will fail due to overflow).
 * uint128 - all values of tokens in native decimal are stored as uint128. This contract is intended to be used for placing buy and sell
 * orders in stablecoins (which typically have 6-18 decimals) hence this value is sufficient to prevent overflow.
 * uint256 - All indices and lengths of arrays are stored as uint256.
 */
contract Orderbook is IOrderbook, ReentrancyGuard, Ownable { 
    using SafeERC20 for IERC20;

    /** 
     * @notice reserveTime - the amount of time in seconds after a buyer has placed a claim that funds on a sell order are reserved for. 
     * @dev This ensures that if a seller changesPrice or closes the order, that no buys are currently active.
     * This should be set to give the buyer enough time to unlock their funds after they have placed a claim. Before a seller can close or
     * change the price of the position, they must wait until all orders on their position are expired, after pausing their order. Hence this
     * value is also used to check expiry of orders in those functions.
     */
    uint32 public immutable reserveTime; 

    /**
     * @notice tokenBalances - A mapping from token address to the amount of that token held by the contract. 
     * @dev This is used to calculate the amount of tokens transfered in to the contract when a sell order is placed. The contract is only intended to 
     * be used to list sellOrders in stablecoins in which uint128 is sufficient to store the amount of tokens. 
     */
    mapping (address => uint128) public tokenBalances; 

    /** 
     * @notice sellAmounts - A mapping from a sellOrderKey to an Amounts struct which stores:
     * amount - A uint128 representing the total amount of tokens left in the order. This is in token native decimals. Placing a claim
     * does not decrement this but unlockFunds, trasnferUnreserved and closeSellOrder do.
     * totalReserved - A uint64 representing the amount of funds that have been reserved, in cents. The conversion between cents and
     * token decimals is handled by the 'price' value fo the seller's sell order. 
     * scheduleCloseTimestamp - A uint32 which is either 0 (the sell order is not scheduled to close), or the timestamp at which it
     * was scheduled to close.
     * maxClaimAmount - The maximum value in cents of a single claim. Certain payment methods limit transaction sizes and so this value
     * ensures that buyers don't claim an unecessary amount of a sell order. 
     */
    mapping (bytes32 => Amounts) public sellAmounts; 
    
    /**
     * @notice onrampClaims A mapping from a sellOrderKey to an array of ClaimDigests. Each claim will have a corresponding ClaimDigest.
     * Each ClaimDigest stores:
     * onramperWallet - The address to receive the funds if the claim is fulfilled.
     * maxProverFee - A uint32 representing the maximum amount in cents that the onramper is willing to pay to the prover.
     * amount - A uint32 representing the value of the claim in cents. 
     * timestamp - A uint32 representing the timestamp at which the claim was placed.
     */
    mapping (bytes32 => ClaimDigest[]) public onrampClaims;  

    /**
     * @notice Whitelist of approved tokens. Done to ensure that only stablecoins are allowed to be traded on the orderbook.
     */
    mapping (address => bool) public whitelistedTokens;

    /**
     * @notice A whitelist of interfaces that can call place sell order. Done to ensure users correctly call placeSellOrder and do
     * not lose their funds.
     */
    mapping(address => bool) public whitelistedInterfaces;

    /**
     * @param _reserveTime The value in seconds that reserveTime is set to.
     */
    constructor(uint32 _reserveTime, address _initialOwner) {
        reserveTime = _reserveTime; 
        transferOwnership(_initialOwner);
    }

    /**
     * @notice function to add tokens to the whitelist.
     */
    function addTokens(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            whitelistedTokens[tokens[i]] = true;
        }
    }

    /**
     * @notice function to add interfaces to the whitelist.
     */
    function addInterfaces(address[] calldata interfaces) external onlyOwner {
        for (uint256 i = 0; i < interfaces.length; i++) {
            whitelistedInterfaces[interfaces[i]] = true;
        }
    }

    /**
     * @notice function to remove tokens from the whitelist.
     */
    function removeTokens(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            whitelistedTokens[tokens[i]] = false;
        }
    }

    /**
     * @notice function to remove interfaces from the whitelist.
     */
    function removeInterfaces(address[] calldata interfaces) external onlyOwner {
        for (uint256 i = 0; i < interfaces.length; i++) {
            whitelistedInterfaces[interfaces[i]] = false;
        }
    }

    /**
     * @notice Called by the seller to place a sell order.
     * @dev Transfers in funds, calculates a unique sell order key based on the values of the sell order and then writes to sellAmounts.
     * If the sellOrderKey is the same as an existing order, this function will combine those two orders. The sell order is 'bound' to
     * the sellOrderKey and thus the data which is its pre-image. The sell order struct contains:
     * seller - The address of the seller. Used to permission the functions to manage the sell order. 
     * price - A uint96, representing the amount of tokens (in native token) recieved for 1 cent sent to the seller. This is used for
     * conversions between 'amount' and 'maxProverFee' to token decimals in claimSellOrder and unlockFunds. 
     * token - The address of the token that the seller is selling. Intended to be a stablecoin.
     * verifyContract - The address of the verifier. Needs to implement IVerifier. Used to verify a buyer's proof of payment and
     * stores information about the seller used to verify proofs.
     * sybilContract - A contract that is used to permission the right to place claims on a sell order. This is used to prevent a
     * sell order from being entirely claimed by sybil claims/wallets. This contract is also able to call cancelScheduleClose, 
     * updateSellPrice and closeSellOrder after the seller has called scheduleCloseSell for a sufficient amount of time. A seller can pass
     * in the 0 address if they don't want to permission these functions.
     */
    function placeSellOrder(SellOrder calldata sellOrder, uint32 maxClaimAmount) external nonReentrant { 
        ///FLAG: need to allow tx.origin so that the seller can use an interface to transfer funds in and place an order in one transaction.
        require((tx.origin == sellOrder.seller) || (msg.sender == sellOrder.seller), "1");

        require(whitelistedInterfaces[msg.sender], "2");

        require(whitelistedTokens[sellOrder.token], "3");

        uint128 tokenAmount = _transferIn(sellOrder.token);

        _updateReserves(sellOrder.token);

        _placeSell(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract, tokenAmount, maxClaimAmount);
    }
    
    /**
     * @notice This function is called by the sybilContract or the onramper to reserve funds in a sell order.
     * @dev This function checks that the seller hasn't schedule a close, that the claim amount is large enough to pay maxProverFee,
     * is less than maxClaimAMount and that the sell order has enough unreserved money for the onramper to claim. 
     * @param expiredIdx is an array of indices in onrampClaims of expired claims or free indices. The contract calls clearExpired to verify that these
     * indices are expired and updates totalReserved. ExpiredIdx should be an array in decreasing order.  If expiredIdx is an empty 
     * array, the new claim is added to the end of the array, otherwise it is placed on the smallest index in expiredIdx that is free.
     */
    function claimSellOrder(SellOrder calldata sellOrder, address onramperWallet, uint32 amount, uint32 maxProverFee, uint256[] calldata expiredIdx) external returns (uint256 claimIndex) { 
        if (sellOrder.sybilContract != address(0)) { require(msg.sender == sellOrder.sybilContract); } 
        
        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);

        Amounts memory sellAmount = sellAmounts[sellOrderKey];

        require(sellAmount.scheduleCloseTimestamp == 0, "1");

        require(amount <= sellAmount.maxClaimAmount, "2");

        /// Amount and maxProverFee are in cents
        require(amount > maxProverFee, "3"); 

        // Clear the expired claims, free up cents, and get the position of the first free index in the claims array
        (uint256 firstFree, uint256 claimLength, uint64 amountCleared) = clearExpired(sellOrderKey, expiredIdx);
        claimIndex = firstFree;

        sellAmount.totalReserved = sellAmount.totalReserved + uint64(amount) - amountCleared;

        /// Ensure enough is free. If the multiplication overflows, then the additional order couldn't have been placed anyway.
        require(uint128(sellAmount.totalReserved) * uint128(sellOrder.price) <= uint128(sellAmount.amount), "4");

        /// claimIndex will be the index of the last invalid claim so will either be the length of the array or the index of the first free slot
        if (claimIndex == claimLength) {
            onrampClaims[sellOrderKey].push(ClaimDigest(onramperWallet, maxProverFee, amount, uint32(block.timestamp)));
        } else {
            onrampClaims[sellOrderKey][claimIndex] = ClaimDigest(onramperWallet, maxProverFee, amount, uint32(block.timestamp));
        }

        /// Update total reserved
        sellAmounts[sellOrderKey].totalReserved = sellAmount.totalReserved;

        emit ClaimPlaced(sellOrderKey, claimIndex, onramperWallet, amount, maxProverFee);
    }


    /**
     * @notice Called after the prover has verified the proof in the verifier contract.
     * @dev This function checks that the claim is still active and that the proof was verified. 
     * @param proofNullifier a unique identifier for the proof. This is used to prevent replay attacks in the verifier contract, in
     * the case where the same proof is used to unlock muilple claims at the same index.
     * @param sellOrderIndex the index of sellOrderCtrs in the verifier contract that the proof of payment pointed to. Used to ensure
     * the email is correctly nullified.
     * @return transferAmount the amount of tokens that get transferred to the onramperWallet. This is the claim amount minus the proverFee.
     */
    function unlockFunds(SellOrder calldata sellOrder, uint256 sellOrderIndex, uint256 claimIndex, bytes32 proofNullifier) external nonReentrant returns (uint128 transferAmount) { // modified nonReentrant
        ///Need to pass in all inputs of this to ensure data is the same as the sell order
        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);
        
        ClaimDigest memory claim = onrampClaims[sellOrderKey][claimIndex];

        Amounts memory sellAmount = sellAmounts[sellOrderKey];
            
        ///Check claims is still active
        require(claim.timestamp >= uint32(block.timestamp) - reserveTime, "7");

        ///Verify proof with the verifier contract
        IOrderbookVerifier verifier = IOrderbookVerifier(sellOrder.verifyContract);

        // Since prover address can be arbitrary, we assume it can be a hostile address and take precautions by using safeTransfer and making the function nonReentrant
        (address prover, bytes32 verifierSellKey) = verifier.verifyPayment(proofNullifier, sellOrderIndex, claimIndex);

        require(sellOrderKey == verifierSellKey, "7.5");
        
        transferAmount = uint128(claim.amount) * uint128(sellOrder.price);

        //Have to do a conversion as claim.amount is in cents and sellAmount.amount is in token decmals
        sellAmounts[sellOrderKey] = Amounts(sellAmount.amount - uint128(claim.amount) * uint128(sellOrder.price), sellAmount.totalReserved - uint64(claim.amount), sellAmount.scheduleCloseTimestamp, sellAmount.maxClaimAmount);

        delete onrampClaims[sellOrderKey][claimIndex];

        ///If prover is address 0 - prover doesn't take a fee (i.e. if proof was generated client-side)
        if (prover != address(0)) {
            uint128 proverFee = IOrderbookVerifier(sellOrder.verifyContract).calculateProverFee(sellOrder.token, sellOrder.price, claim.amount, prover);
            
            /**
             * @dev Do a conversion because maxProverFee is in cents. A prover could prevent a claim from being fulfilled by setting a proverFee 
             * that is higher than maxProverFee. In this case, the prover will be unable to receive their funds but the user can still get a 
             * different prover to generate a proof and unlock it.
             */
            require(proverFee <= uint128(claim.maxProverFee) * uint128(sellOrder.price), "8"); ///Check that the proverFee is less than the maxProverFee

            if (proverFee != 0) {
                IERC20(sellOrder.token).safeTransfer(prover, proverFee);
            }

            transferAmount -= proverFee;
        }
        
        IERC20(sellOrder.token).safeTransfer(claim.onramperWallet, transferAmount);

        _updateReserves(sellOrder.token);

        emit PaymentComplete(sellOrderKey, claimIndex);
    }

    /**
     * @notice Function that lets a seller transfer out a portion of the unreserved funds of their order.
     * @param transferAmount The amount of tokens to transfer out in token native decimals. If transferAmount
     * >= unreserved funds, the transaction will fail. If a seller wants to transfer out all of their funds, or
     * an amount close to the total, they should set transferAmount = 0 and the contract will transfer out 
     * everything.
     */
    function transferUnreserved(SellOrder calldata sellOrder, uint128 transferAmount) external nonReentrant {
        require(msg.sender == sellOrder.seller, "8");

        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);

        Amounts memory sellAmount = sellAmounts[sellOrderKey];

        /**  
         * @dev This won't underflow because totalReserved only changes in placeClaim where sellAmount.totalReserved * 
         * sellOrder.price < sellAmount.amount is checked. If price is changed, totalReserved is set to 0 and amount
         * can only change in this function, closeSellOrder or unlockFunds. unlockFunds decrements totalReserved and amount
         * in proportion.
        */
        uint128 totalUnreserved = sellAmount.amount - uint128(sellAmount.totalReserved) * uint128(sellOrder.price);

        if (totalUnreserved != 0 && transferAmount <= totalUnreserved) {
            if (sellAmount.totalReserved == 0 && (transferAmount == 0 || transferAmount == totalUnreserved)) {
                //close the order
                _closeSellOrder(sellOrder);

            } else if (transferAmount == 0) {
                //set transferAmount = 0 to transfer everything
                sellAmounts[sellOrderKey] = Amounts(sellAmount.amount - totalUnreserved, sellAmount.totalReserved, sellAmount.scheduleCloseTimestamp, sellAmount.maxClaimAmount); //decrement amount and totalReserved
                IERC20(sellOrder.token).safeTransfer(sellOrder.seller, totalUnreserved);
                emit DecreaseAmountFull(sellOrderKey, sellAmount.amount - totalUnreserved);
            } else {
                sellAmounts[sellOrderKey] = Amounts(sellAmount.amount - transferAmount, sellAmount.totalReserved, sellAmount.scheduleCloseTimestamp, sellAmount.maxClaimAmount); //decrement amount and totalReserved
                IERC20(sellOrder.token).safeTransfer(sellOrder.seller, transferAmount);
                emit DecreaseAmount(sellOrderKey, sellAmount.amount - transferAmount);
            }
            _updateReserves(sellOrder.token);
        }
    }


    /**
     * @notice Used to prevent further claims on a sell order. 
     * @dev permissioned to the onramper.
     */
    function scheduleCloseSell(SellOrder calldata sellOrder) external nonReentrant { 
        require(msg.sender == sellOrder.seller, "9");

        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);

        sellAmounts[sellOrderKey].scheduleCloseTimestamp = uint32(block.timestamp);

        emit CloseScheduled(sellOrderKey);
    }

    /** 
     * @notice Used to cancel schedule close. 
     * @dev Permissioned to the seller and the sybil contract.
     */
    function cancelScheduleCloseSell(SellOrder calldata sellOrder) external nonReentrant { 
        require((msg.sender == sellOrder.seller) || (msg.sender == sellOrder.sybilContract), "9");
        
        bytes32 sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);
        
        sellAmounts[sellOrderKey].scheduleCloseTimestamp = 0;

        emit CloseCancelled(sellOrderKey);
    }

    /**
     * @notice Called to close a sell order after sufficient time has passed since scheduleCloseSell was called or there 
     * are no more active claims. 
     * @dev Permissioned to the seller and the sybil contract to prevent a price change when the seller intended for the order
     * to be closed.
     */
    function closeSellOrder(SellOrder calldata sellOrder) public nonReentrant { 
        _closeSellOrder(sellOrder);
    }

    /**
     * @notice Internal function that implements the logic of closeSellOrder.
     */
    function _closeSellOrder(SellOrder calldata sellOrder) internal {
        bytes32 sellOrderKey = _checkCloseSell(sellOrder);

        delete onrampClaims[sellOrderKey];
        delete sellAmounts[sellOrderKey]; 
        
        IERC20(sellOrder.token).safeTransfer(sellOrder.seller, sellAmounts[sellOrderKey].amount);
        _updateReserves(sellOrder.token);

        emit SellOrderClosed(sellOrderKey);
    }


     /**
     * @notice Called to change the price fo a sell order after sufficient time has passed since scheduleCloseSell was called or there 
     * are no more active claims. Creates an order with the new price and transfers funds across.
     * @dev Permissioned to the seller and the sybil contract to prevent the order being closed when the seller intended a price
     * change.
     */
    function updateSellPrice(SellOrder calldata sellOrder, uint96 newPrice) external nonReentrant { 
        bytes32 oldOrderKey = _checkCloseSell(sellOrder);

        _placeSell(sellOrder.seller, newPrice, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract, sellAmounts[oldOrderKey].amount, sellAmounts[oldOrderKey].maxClaimAmount); //emits an event that a new sell order was placed

        delete onrampClaims[oldOrderKey];
        delete sellAmounts[oldOrderKey]; 

        emit ChangePrice(oldOrderKey);
    }
    
    /**
     * @dev Internal function that runs checks to see if a sell order can be closed or the price can be changed.
     * @param sellOrder The sell order that is being closed or changed
     * @return sellOrderKey The sell order key of the sell order.
     */
    function _checkCloseSell(SellOrder calldata sellOrder) internal view returns (bytes32 sellOrderKey) {
        require((msg.sender == sellOrder.seller) || (msg.sender == sellOrder.sybilContract), "11"); 

        sellOrderKey = getSellKey(sellOrder.seller, sellOrder.price, sellOrder.token, sellOrder.verifyContract, sellOrder.sybilContract);

        uint32 localReserveTime = reserveTime;

        uint32 scheduleClose = sellAmounts[sellOrderKey].scheduleCloseTimestamp;

        ///If sell order hasn't been scheduled to close for enough time -  manually go through the array to check if it's been long enough
        /// Note - this may fail due to gas limits if there are too many claims, in which the seller will have to wait reserveTime seconds.
        if (scheduleClose >= uint32(block.timestamp) - localReserveTime || scheduleClose == 0) {
            //loop through arrays to check if all claims are no longer active
            uint256 length = onrampClaims[sellOrderKey].length;

            //ensure no claims are active
            for(uint index = 0; index < length;) {
                require(onrampClaims[sellOrderKey][index].timestamp < uint32(block.timestamp) - localReserveTime, "12");
                unchecked { ++index; } //As length is a uint256, this won't overflow
            }  
        }
    }

    /**
     * @notice Internal function to place a new sell order.
     * @dev If two sell orders have the same sell key, they will be treated as the same sell order but the maxClaim amount of the second order
     * will overwrite that of the first order.
     */
    function _placeSell(address seller, uint96 price, address token, address verifyContract, address sybilContract, uint128 amount, uint32 maxClaimAmount) internal {
        bytes32 sellOrderKey = getSellKey(seller, price, token, verifyContract, sybilContract);

        Amounts memory sellAmount = sellAmounts[sellOrderKey];

        if (sellAmount.amount == 0) {
            emit NewSellOrder(seller, amount, price, token, verifyContract, sybilContract, maxClaimAmount); 
        } else {
            emit IncreaseAmount(sellOrderKey, sellAmount.amount + amount);
        }

        sellAmounts[sellOrderKey] = Amounts(sellAmount.amount + amount, sellAmount.totalReserved, sellAmount.scheduleCloseTimestamp, maxClaimAmount);
    }

    /**
     * @notice This is an internal function called by claimSellOrder to clear expired claims.
     * @param expiredIdx is an array of indices in onrampClaims of expired claims or free indices. The contract verifies that these
     * indices are expired. ExpiredIdx should be an array in decreasing order.  If expiredIdx is an empty 
     * array, the new claim is added to the end of the array, otherwise it is placed on the smallest index in expiredIdx that is free.
     * @return firstFree The index of the first free slot in onrampClaims. If expiredIdx is empty, this will be the length of the array.
     * @return claimLength The updated length of onrampClaims.
     * @return amountCleared The total amount of cents that were cleared from the sell order.
     */
    function clearExpired(bytes32 sellOrderKey, uint256[] calldata expiredIdx) private returns (uint256 firstFree, uint256 claimLength, uint64 amountCleared) { 

        /// Default to adding new claim to end of array
        firstFree = onrampClaims[sellOrderKey].length; 

        claimLength = firstFree; /// Keeps track of length of onrampClaims

        uint32 localReserveTime = reserveTime;

        amountCleared = 0;

        for (uint index = 0; index < expiredIdx.length;) { /// If expiredIdx is empty, this loop won't run
            if (expiredIdx[index] >= claimLength) { 
                unchecked { ++index; }
                continue; 
            } /// If expiredIdx is too large

            ClaimDigest memory claim = onrampClaims[sellOrderKey][expiredIdx[index]];

            if (claim.timestamp < uint32(block.timestamp) - localReserveTime) { /// Checking if claim is expired or deleted
                
                amountCleared += uint64(claim.amount);

                if (expiredIdx[index] == claimLength - 1) {
                    onrampClaims[sellOrderKey].pop(); 
                    unchecked { --claimLength; } 
                }
                else {
                    delete onrampClaims[sellOrderKey][expiredIdx[index]];
                }
                firstFree = expiredIdx[index]; /// Can add the new claim in this slot
                emit ClaimDeleted(sellOrderKey, expiredIdx[index]);
                
            }
            unchecked { ++index; } /// Won't overflow as expiredIdx.length is a uint256
        }

        return (firstFree, claimLength, amountCleared);
    }


    /**
    * @dev Private function to transfer tokens into the contract.
    * @param token The address of the token to transfer.
    * @return tokenAmount The amount of tokens transferred into the contract.
    */
    function _transferIn(address token) private view returns (uint128 tokenAmount) { 
        uint128 reserve = tokenBalances[token];
        uint128 balance = uint128(IERC20(token).balanceOf(address(this))); 
        tokenAmount = balance - reserve;
        require(tokenAmount != 0, "13"); // Ensure tokens have been deposited
    }

    /**
    * @dev Updates the reserves of a specific token by retrieving its current balance held by the contract.
    * @param token The address of the token for which the reserves are to be updated.
    * @notice This function should be called every time a token is deposited or withdrawn to keep the reserves up-to-date.
    */
    function _updateReserves(address token) private {
        tokenBalances[token] = uint128(IERC20(token).balanceOf(address(this)));
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



 
