const fs = require('fs');
const Wallet = require('ethereumjs-wallet').default;

// Generate a new wallet
const wallet = Wallet.generate();

// Extract the private key and address
const privateKey = wallet.getPrivateKey();
const address = wallet.getAddressString();

// Convert the private key to a hexadecimal string
const privateKeyHex = privateKey.toString('hex');

// Write the private key and address to files
fs.writeFileSync('key', privateKeyHex);
fs.writeFileSync('key.pub', address);

console.log('Private key and address have been written to "key" and "key.pub"');
