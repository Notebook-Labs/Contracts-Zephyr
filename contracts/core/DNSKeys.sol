// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "./dep/Ownable.sol";

/**
 * @title DNSKeys
 * @notice DNSKeys contract which stores the hash of the DNS keys used to sign Venmo emails.
 * @dev The contract is owned by a timelock contract. It is responsible for storing he DNS keys 
 * used to sign Venmo emails and the hash of the keys. This contract is used to store 1024 bit keys.
 */
contract DNSKeys is Ownable {

    /**
     * @dev Emitted when the Venmo key is set. We build this contract for 1024 but keys.
     */
    event SetVenmoKey(bytes1[128] key);

    /**
     * @dev Emitted when the Amazonses key is set. We build this contract for 1024 but keys.
     */
    event SetSesKey(bytes1[128] key);

    /**
     * @dev Emitted when the hash is set.
     */
    event SetHash(bytes32 hashVal);

    /** 
     * @notice venmoKey - a bytes array containing the RSA public key of Venmo.
     * @dev The key is used to sign emails originating from venmo.com when a user completes a payment. 
     * The key is 1024 bits long. This key is used to verify that the email originated from Venmo.
     */
    bytes1[128] public venmoKey;

    /** 
     * @notice sesKey - a bytes array containing the RSA public key of Amazonses.
     * @dev The key used to sign emails originating Amazonses sent by Venmo. The key is 1024 bits long. 
     * Venmo uses Amazonses as their email provider. We verify the signature as additional protection 
     * against Venmo leaking their key or an employee gaining access to the Venmo key. 
     */
    bytes1[128] public sesKey;

    /** 
     * @notice hashValue - a bytes32 which stores the hash of the vennmo key concatenated with the ses key. 
     * @dev The hash is intended to be checked by a Verifier contract against a hash outputted by a ZK proof.
     */
    bytes32 public hashValue;

    /**
     * @notice DNSKeys constructor - sets the owner of the contract to a timelock contract.
     */
    constructor(address _initialOwner) {
        transferOwnership(_initialOwner);
    }

    /**
     * @notice setVenmoKey - sets the venmoKey variable.
     * @param key - a bytes array containing the RSA public key of Venmo.
     * @dev The key is used to sign emails originating from venmo.com when a user completes a payment. 
     * This function is permissioned to the timelock contract.
     */
    function setVenmoKey(bytes1[128] memory key) external onlyOwner {
        require(uint8(key[0]) > 63, "venmo key is less than 1022 bits");
        uint8 allEqual = 1;
        for (uint index = 0; index < 128; index++) {
            if (key[index] != sesKey[index]) {
                allEqual = 0;
            }
        }
        require(allEqual == 0, "venmo key is equal to ses key");

        venmoKey = key;
        emit SetVenmoKey(key);
    }

    /**
     * @notice setSesKey - sets the sesKey variable.
     * @param key - a uint array containing the RSA public key of Amazonses.
     * @dev The key used to sign emails originating Amazonses sent by Venmo. Venmo uses Amazonses as their
     * email provider. This function is permissioned to the timelock contract. Key is arranged so that 
     *   key[0] is the most significant byte.
     */
    function setSesKey(bytes1[128] memory key) external onlyOwner {
        require(uint8(key[0]) > 63, "ses key is 1022 bits or less");
        uint8 allEqual = 1;
        for (uint index = 0; index < 128; index++) {
            if (key[index] != venmoKey[index]) {
                allEqual = 0;
            }
        }
        require(allEqual == 0, "ses key is equal to venmo key");

        sesKey = key;
        emit SetSesKey(key);
    }
    
    /**
     * @notice setHash - sets the hashValue variable by calling calculateHash.
     * @dev This function is external so that it can be called by anyone.
     */
    function setHash() external {
        bytes32 hashVal = calculateHash();
        hashValue = hashVal;
        emit SetHash(hashVal);
    }

    /**
     * @notice calculateHash - calculates the hash of the venmoKey concatenated with the sesKey.
     * @return hashVal - the hash of the venmoKey concatenated with the sesKey.
     * @dev This function is public so that it can be called by anyone. It loads the venmoKey and sesKey
     * into memory and then concatenates them. It then calculates the hash of the concatenated bytes array
     * using the standard sha256 Solidity function.
     */
    function calculateHash() public view returns (bytes32 hashVal) {
        
        // Create a new bytes array of size 2048 bits to store the concatenated keys
        bytes memory result = new bytes(256);

        // Copy the venmoKey into the first 4 elements of the concatenate array
        for (uint256 i = 0; i < 128; i++) {
            result[i] = venmoKey[i];
        }

        // Copy the sesKey into the last 4 elements of the concatenate array
        for (uint256 i = 0; i < 128; i++) {
            result[i + 128] = sesKey[i];
        }

        // Return the hash of the concatenated keys by calling the sha256 Solidity function.
        return sha256(result);
    }
}
