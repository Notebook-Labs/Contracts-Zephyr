const { ethers } = require("hardhat");
//to run - write npx hardhat run --network sepolia sdeploy_testnet.js

//FLAG
const modulus0 = ["728185193184898587931474090404658947","1409332177107293293834872607787019326","2607692895823775582904305072937680935","1642327064808770524484167433896339257","1719210826311917241600793756245915857","2021332119943316909162186907987225592","139708964555461211926695344573320465","1358621314205448579095207406035012819","40956946013763858"]
const modulus1 = ["683441457792668103047675496834917209","1011953822609495209329257792734700899","1263501452160533074361275552572837806","2083482795601873989011209904125056704","642486996853901942772546774764252018","1463330014555221455251438998802111943","2411895850618892594706497264082911185","520305634984671803945830034917965905","47421696716332554"]
const test_addresses = ["0xc51052a6f08b5982Ca93E526B245993004f8B1B7", "0x95317650b0c90463e365f275da521b395fad4f01", "0xcdcC304CEE132f0892Ef453683bA294767cce654"];
const sybil_address = "0x95317650b0c90463e365F275Da521B395fAD4F01";

const permit2 = "0x000000000022d473030f116ddee9f6b43ac78ba3";

const reserve_time = 3600; 

function hexStringToByteArray(hexString) {
  // Check if the string starts with '0x' and remove it
  if (hexString[0] + hexString[1] == '0x') {
      hexString = hexString.slice(2);
  }

  // Pad the string with a leading zero if it's of odd length
  if (hexString.length % 2 !== 0) {
      hexString = '0' + hexString;
  }

  const byteArray = [];
  for (let i = 0; i < hexString.length; i += 2) {
      const byte = "0x" + parseInt(hexString.substring(i, i + 2), 16).toString(16).padStart(2, '0');
      byteArray.push(byte);
  }
  
  return byteArray;
}

function processModulus(modulus) {
  const bitLength = 121;
  let concatenatedBits = '';

  for (let i = 0; i < modulus.length; i++) {  
      let binaryString = BigInt(modulus[i]).toString(2); // Convert to binary
      binaryString = binaryString.padStart(bitLength, '0'); // Pad to ensure 121 bits
      concatenatedBits = binaryString + concatenatedBits;
  }

  //this is the hex string representing the RSA public key
  concatenatedBits = concatenatedBits.slice(-1024);

  const num = BigInt("0b" + concatenatedBits);
  const hex = "0x" + num.toString(16).toUpperCase();

  return hexStringToByteArray(hex);
}


function decimalAdjust(num_tokens, decimals) {
  return BigInt(num_tokens * 10 ** decimals);
}


async function deploy() {
  const [user] = await ethers.getSigners();
  console.log(user.address)


  const Token = await ethers.getContractFactory("Token");
  const token1 = await Token.deploy("USDC", "USDC", 6);

  await token1.waitForDeployment();


  // Mint tokens and assign a balance to each account
  let initial_account_balance = 1000000;
  for(let j = 0; j < test_addresses.length; j++) {
      await token1.nativeContract.mint(test_addresses[j], decimalAdjust(initial_account_balance, 6));
  }
  
  // Initialize all data needed for the orderbook constructor
  // Deploy testproverFee contract
  const ProverFeeContract = await ethers.getContractFactory("ProverFee");
  const proverFeeContract = await ProverFeeContract.deploy(user.address);

  await proverFeeContract.waitForDeployment();
  await proverFeeContract.nativeContract.setFee(token1.target, decimalAdjust(0.1, 6));
  

  // Deploy DNS contract
  const DNSContract = await ethers.getContractFactory("DNSKeys");
  const dnsContract = await DNSContract.deploy(user.address); //in reality should point to the timelock controller
  
  await dnsContract.waitForDeployment();

  await dnsContract.nativeContract.setVenmoKey(processModulus(modulus0));

  await dnsContract.nativeContract.setSesKey(processModulus(modulus1));

  await dnsContract.nativeContract.setHash();

  // Deploy orderbook contract
  const Orderbook = await ethers.getContractFactory("Orderbook");
  const orderbook = await Orderbook.deploy(reserve_time, user.address);

  await orderbook.waitForDeployment();

  // Add tokens to orderbook
  await orderbook.nativeContract.addTokens([token1.target]);
  
  //deploy zk_verifier
  const ZK_verifier = await ethers.getContractFactory("contracts/core/Verifier.sol:Groth16Verifier");
  const zk_verifier = await ZK_verifier.deploy();

  await zk_verifier.waitForDeployment();


  // Deploy the verifier contract and initialize it with the already deployed orderbook contract
  const Verifier = await ethers.getContractFactory("contracts/core/Verifier.sol:Verifier");
  const verifier = await Verifier.deploy(orderbook.target, dnsContract.target, zk_verifier.target);

  await verifier.waitForDeployment();


  const Sybil = await ethers.getContractFactory("Sybil");
  const sybil = await Sybil.deploy(orderbook.target, sybil_address, reserve_time);

  await sybil.waitForDeployment();


  // Deploy the orderbookInterface contract with a null router contract (for now)
  const OrderbookInterface = await ethers.getContractFactory("OrderbookInterface");
  const orderbookInterface = await OrderbookInterface.deploy(orderbook.target, permit2);

  await orderbookInterface.waitForDeployment();

  const interface_address = [orderbookInterface.target]

  //whitelist interface on orderbook
  await orderbook.nativeContract.addInterfaces(interface_address);

  console.log("Token1 deployed to:", token1.target);
  console.log("Orderbook deployed to:", orderbook.target);
  console.log("Verifier deployed to:", verifier.target);
  console.log("OrderbookInterface deployed to:", orderbookInterface.target);
  console.log("ProverFeeContract deployed to:", proverFeeContract.target);
  console.log("DNSContract deployed to:", dnsContract.target);
  console.log("Sybil deployed to:", sybil.target);
}

async function testDNS() {
  const [user] = await ethers.getSigners();
  const DNSContract = await ethers.getContractFactory("DNSKeys");
  const dnsContract = await DNSContract.deploy(user.address); //in reality should point to the timelock controller
  
  await dnsContract.waitForDeployment();

  await dnsContract.nativeContract.setVenmoKey(processModulus(modulus0));

  await dnsContract.nativeContract.setSesKey(processModulus(modulus1));

  console.log(await dnsContract.nativeContract.testHash());

}

async function testProcessing() {
  console.log(processModulus(modulus0))
  console.log(processModulus(modulus1))
  
}

deploy()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
});