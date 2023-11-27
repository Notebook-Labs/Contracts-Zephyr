const bits_to_hash = "100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000010"

function bitStringToSolidityBytes(bitString) {
    let result = '0x';
    let byte = 0;
    let bitCount = 0;

    for (let i = 0; i < bitString.length; i++) {
        // Shift the byte one bit to the left
        byte <<= 1;

        // Add the current bit to the byte
        byte |= bitString[i] === '1' ? 1 : 0;
        bitCount++;

        // If we've added 8 bits, or if this is the last bit, append the byte to the result
        if (bitCount === 8 || i === bitString.length - 1) {
            result += byte.toString(16).padStart(2, '0');
            byte = 0;
            bitCount = 0;
        }
    }

    return result;
}

async function main() {
    const hash = await ethers.getContractFactory("HashTest");
    const HashTest = await hash.deploy();
 

    const hash_value = await HashTest.calculateHash(bitStringToSolidityBytes(bits_to_hash));
    console.log("Hash value: ", hash_value);

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
});