
# Dakota Network

This repository provides everything you need to get started with a local/private Hyperledger Besu network, optionally using Tessera for private transactions. It includes:

- **Tessera 24.4.2** (prebuilt distribution)
- **Besu 24.10.0** (prebuilt binaries can be downloaded from [Besu Releases](https://github.com/hyperledger/besu/releases/tag/24.10.0))
- **Node.zip** (contains `genesis.json`, keys, and a minimal node folder structure)
- **makewallet.js** (a small script to generate Ethereum-compatible wallets)

## Table of Contents

1. [Overview of Files](#overview-of-files)
2. [Using makewallet.js](#using-makewalletjs)
3. [Prerequisites](#prerequisites)
   - [Required Packages and Dependencies](#required-packages-and-dependencies)
4. [Installation and Setup](#installation-and-setup)
   - [1. Unzip the Provided Files](#1-unzip-the-provided-files)
   - [2. Installing Tessera (Prebuilt)](#2-installing-tessera-prebuilt)
5. [Using the Node Folder](#using-the-node-folder)
6. [Running the Network](#running-the-network)
7. [Additional Notes](#additional-notes)
8. [References](#references)

---

## Overview of Files

1. **`tessera-24.4.2.zip`**

   - A **prebuilt** Tessera distribution (version 24.4.2).
   - Required if you want to enable privacy transactions on your Besu network.

2. **`besu-24.10.0.zip`**

   - Prebuilt binaries are available from the [Besu Releases page](https://github.com/hyperledger/besu/releases/tag/24.10.0).

3. **`Node.zip`**

   - Contains a minimal node setup, including:
     - `genesis.json` (defines blockchain parameters)
     - `data/` folder with a pair of keys (`key` and `key.pub`)
     - `Tessera/` folder for private transaction configuration (keys, `tessera-config.json`, etc.)

4. **`makewallet.js`**

   - A small script (Node.js) to generate Ethereum-compatible wallets.
   - Useful for creating new keys for your node or additional test accounts.

---

## Using `makewallet.js`

`makewallet.js` is a Node.js script that generates a new Ethereum-compatible wallet, including a private key and a public address. This can be used to create the keys for your node or additional accounts for testing purposes.

### Steps to Use `makewallet.js`

1. Install Node.js if you haven’t already (see [Prerequisites](#prerequisites) for instructions).
2. Navigate to the folder containing `makewallet.js`.
3. Run the script:
   ```bash
   node makewallet.js
   ```
4. The script will generate a private key and corresponding public address. These can be used for your node or as additional accounts for testing.

---

## Prerequisites

### Required Packages and Dependencies

Before proceeding, ensure that the following packages are installed on your system. Instructions below are applicable to **Ubuntu** and **Fedora** servers.

#### 1. **Java 21** (Required for Hyperledger Besu)

- Install OpenJDK 21:

  **Ubuntu**:

  ```bash
  sudo apt update
  sudo apt install -y openjdk-21-jdk
  ```

  **Fedora**:

  ```bash
  sudo dnf install -y java-21-openjdk-devel
  ```

- Verify the installation:

  ```bash
  java -version
  ```

  You should see `openjdk version "21"` or similar.

#### 2. **Java 11 or Higher** (Required for Tessera)

- Tessera can use Java 11 or higher. If you already installed OpenJDK 21 for Besu, you're covered.

#### 3. **Node.js and npm** (Optional for `makewallet.js`)

- Install Node.js using `nvm` (Node Version Manager):

  1. Download and install `nvm`:

     **Ubuntu and Fedora**:
     ```bash
     curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash
     ```

  2. Follow the instructions displayed in the terminal to enable `nvm`. This typically involves running a command like:
     ```bash
     source ~/.bashrc
     ```
     or
     ```bash
     source ~/.zshrc
     ```

  3. Install Node.js (version 18 or higher recommended):
     ```bash
     nvm install 18
     ```

  4. Set the default Node.js version:
     ```bash
     nvm alias default 18
     ```

- Verify the installation:
  ```bash
  node -v
  npm -v
  ```

#### 4. **Unzip Tool**

- Required to extract the provided `.zip` files:

  **Ubuntu**:
  ```bash
  sudo apt install -y unzip
  ```
  **Fedora**:
  ```bash
  sudo dnf install -y unzip
  ```

---

## Installation and Setup

### 1. Unzip the Provided Files

Unzip the following files:

- `tessera-24.4.2.zip` → Extract to a folder, e.g., `/opt/tessera-24.4.2`.
- `Node.zip` → Extract to your desired working directory, e.g., `/home/user/dakota-node`.

Example command to unzip files:
```bash
unzip <file-name>.zip -d <destination-folder>
```

### 2. Installing Tessera (Prebuilt)

1. Extract the provided `tessera-24.4.2.zip`:
   ```bash
   unzip tessera-24.4.2.zip -d /opt/tessera-24.4.2
   ```
2. Add the Tessera binary directory to your PATH (optional):
   ```bash
   export PATH=$PATH:/opt/tessera-24.4.2/bin
   ```
3. Verify Tessera is accessible:
   ```bash
   tessera --version
   ```

---

## Using the Node Folder

Inside **`Node.zip`**:

- **`genesis.json`**
  Defines the blockchain parameters (chain ID, block gas limit, etc.).
- **`data/`**
  Contains a set of node keys:
  - `key` (the private key)
  - `key.pub` (the public key)
- **`Tessera/`** (folder)
  - `node1`, `node1.pub`: Key pair for the Tessera node.
  - `tessera-config1.json`: Basic Tessera configuration file.

You can use these files to spin up your own local Besu node.

---

## Running the Network

### Start Besu

Run the following command to start Besu with the provided configuration:

```bash
besu --data-path=data      --genesis-file=../genesis.json      --bootnodes=enode://ef2bd01fbaea3b6f255a6811e32e050efa51a93d0dde34593cd0c77d5344ea151f8cce2c1a3aca9baf9a2eb0daaf2abac856ed7d9ca7ad602246e887aa6d3021@100.111.5.6:30303      --p2p-port=30303      --rpc-http-enabled      --rpc-http-api=ETH,NET,QBFT      --host-allowlist="*"      --rpc-http-cors-origins="all"      --rpc-http-port=8545      --p2p-host=100.111.5.7      --sync-min-peers=3
```

### Start Tessera (Optional for Privacy)

```bash
tessera -configfile /home/user/dakota-node/Tessera/tessera-config1.json
```

---

## Additional Notes

- Ensure Java is properly installed and accessible.
- Modify `genesis.json` to customize your blockchain parameters (e.g., chain ID, block rewards).
- For production, replace the provided keys and configurations with your own secure files.

---

## References

- [Hyperledger Besu Documentation](https://besu.hyperledger.org/)
- [Tessera Documentation](https://docs.consensys.net/tessera/)
- [Node.js Downloads](https://nodejs.org/)

---

Feel free to open an issue or pull request if you have questions or improvements. Enjoy experimenting with your **Dakota Network**!
