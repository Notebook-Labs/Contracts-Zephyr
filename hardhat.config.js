require("@nomicfoundation/hardhat-toolbox");
require('dotenv').config();


/** @type import('hardhat/config').HardhatUserConfig */
tdly = require("@tenderly/hardhat-tenderly");

tdly.setup();

module.exports = {
  solidity: "0.8.18",
};


// Replace this private key with your Sepolia account private key
// To export your private key from Coinbase Wallet, go to
// Settings > Developer Settings > Show private key
// To export your private key from Metamask, open Metamask and
// go to Account Details > Export Private Key
// Beware: NEVER put real Ether into testing accounts
const SEPOLIA_PRIVATE_KEY = process.env.SEPOLIA_PRIVATE_KEY;
const SYBIL_SEPOLIA_PRIV_KEY = process.env.SYBIL_SEPOLIA_PRIV_KEY;

module.exports = {
  solidity: "0.8.18",
  networks: {
    sepolia: {
      url: `https://eth-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
      accounts: [SEPOLIA_PRIVATE_KEY, SYBIL_SEPOLIA_PRIV_KEY],
      // gasPrice: 7046910900
    }
  },
  tenderly: {
    project: 'zephyr-testing',
    username: 'NathanielMY'
  }

};