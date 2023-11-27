// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;
import "./IOrderbook.sol";

interface IGoogleVerifier {
    /**
     * @dev Struct containing proof data which is passed to the zkVerifier contract. _pubSignals contains
     * the hash of a bytes encoding of a HashInputs struct.
     */
    struct ProofData {
        uint[2] _pA;
        uint[2][2] _pB;
        uint[2] _pC;
        uint[1] _pubSignals; 
    }

    /**
     * @dev Struct containing the inputs to the hash function which is used to generate the pubSignal. These
     * are values extracted from the payment receipt within the ZK proof.
     * modHash is the sha256 hash of Venmo and Amazon's public keys which signed the email.
     * Nullifier is a sha256Hash of the amount + paymentID
     * TransactionID contains an encoding of the transaction ID of the request and payment. The transaction ID
     * contains 17 values in [A-Z + 0-9], and 36^17 ~ 2^88
     * Prover is the address of the prover.
     * Amount is the number of cents that was sent in the payment.
     */
    struct HashInputs {
        bytes32 modHash;
        bytes32 Nullifier;
        address Prover; 
        uint96 TransactionID;
        uint32 Amount;
    }
    
    /**
     * @dev Struct used to show if a proof was verified and who was the prover.
     * status = 0 -> not verifier, status = 1 -> verifier and not used, status = 2 -> nullified
     */
    struct Verified {
        uint32 status; 
        address prover; 
    }

    struct Counters {
        uint64 sell_order_ctr;
        uint192 claim_index; //NOTE - claim_index is 192 in storage but 256 everywhere else to fit in with the Orderbook interface
    }


    function addCounter(bytes32 sellOrderKey) external;

    function commitTxID(IOrderbook.SellOrder calldata sellOrder, uint96 txID, uint64 sell_order_ctr, uint192 claim_index) external;

    function decodeManually(bytes memory hashInputs) external pure returns (HashInputs memory finalHashStruct);
    
    function calculateProverFee(address token, uint96 price, uint32 amount, address prover) external view returns (uint128 proverFee);

    function verifyProof(bytes calldata proofData, IOrderbook.SellOrder calldata sellOrder, bytes calldata hashInputs) external;

    function verifyPayment(bytes32 proofNullifier, uint256 sellOrderIndex, uint256 claimIndex) external returns (address prover, bytes32 verifierSellKey);

    function addProverContract(address prover, address feeContract) external;

    function getSellKey(IOrderbook.SellOrder calldata sellOrder) external pure returns (bytes32 sellOrderKey);

    function getVerifiedKey(bytes32 proofNullifier, uint256 sellOrderIndex, uint256 claimIndex) external pure returns (bytes32 verifiedKey);

    function checkProof(bytes32 proofNullifier, uint256 sellOrderIndex, uint256 claimIndex) external view returns (uint32 status, address prover);

    /** 
     * @dev Event called when a sellOrderKey is added to the sellOrderCtrs array
     */
    event SellOrderCtr(bytes32 sellOrderKey, uint64 ctr);

    /**
     * @dev Event called when a proof is verified and whitelisted in verifiedProofs.
     */
    event ProofVerified(bytes32 nullifier, uint64 sellOrderId, uint256 claimId, address prover);

    /**
     * @dev Event is emitted in verifyPayment when a proof is nullified since the Orderbook has used it to unlock funds.
     */
    event ProofNullified(bytes32 nullifier, uint256 sellOrderId, uint256 claimId);

    /**
     * @dev Called in addProverContract when a feeContract for a prover is set.
     */
    event FeeContractSet(address prover, address feeContract);

    event commitTx(uint96 txID, uint64 sell_order_ctr, uint192 claim_index);

}