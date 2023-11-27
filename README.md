### Zephyr Smart Contracts

## High level overview

There are four components of our on-chain architecture:
- Orderbook contract
- Verifier contract
- Sybil contract
- DNSKeys contract

### Orderbook contract
The main component is the Orderbook contract which is permissionless and not upgradeable. This contract is responsible for holding seller funds, managing sell orders, and releasing funds to buyers. This is the only contract which will ever take custody of user funds. When a seller places a sell order, they specify information relating to the price, amount, claims, as well as a Verifier contract and optionally a Sybil contract. 

### Verifier contract
The role of a verifier contract is to verify zero-knowledge proof of payment. Furthermore, the verifier must store a mapping of verified proof to (claim, sell order) pairs. Finally, the verifier must nullify proofs to ensure that a single payment cannot be used multiple times. As mentioned in our verifier contingency plan, if a new verifier is deployed, it must take into account the array of nullified proofs to ensure that a payment receipt cannot be re-used. Our current verifier points to a single Orderbook and soley verified Venmo payments. However, we have plans to release a general verifier capable of verifying proofs for many payment methods. The current verifier also points to the DNSKeys contract to make sure that the proof it's verifying is with respect to the most recent keys. 

### DNSKeys contract
The role of this contract is to store the most recent keys of a payment method. An important part of proof of payment is checking that the payment receipt is signed by the payment provider (and other potential parties). Therefore it is imperative that the verifier has access to the most current keys being used to sign receipts - this is the job of the DNSKeys contract. As discussed in the access control section, this contract is permissioned, but we have taken necessary preventions to ensure that a seller cannot lose funds due to malicious keys being pushed. 

### Sybil contract
The Sybil contract is an optional contract that can be specified by a seller to help maintain and protect their sell order. We recommend that seller's use our Sybil contract which will help with closing and changing the price of their position, as well as sybil protection and compliance. Furthermore, when a seller whitelists our Sybil contract, placing claims becomes permissioned to the Sybil contract. This ensures that sell orders are protected against Sybil attacks and that claiming does not revert due to excess buyers claiming the same sell order. We discuss this in more detail in the access control and transaction ordering sections. 

## License

This repository and all its contents are licensed under the GNU General Public License (GPL-3.0-only). This ensures that all users have the freedoms to run, study, share, and modify the software. The full text of the GPL license is available in the LICENSE file in the root directory of this project.




