
# Dakota Network

This guide explains how to set up a Hyperledger Besu node and connect it to the **Dakota Network**, with optional Tessera configuration for privacy transactions.

## Overview of Files

1. **`tessera-24.4.2.zip`**

   - Prebuilt Tessera distribution for enabling privacy transactions.

2. **`besu-24.10.0.zip`**

   - Prebuilt binaries for Hyperledger Besu are available from the [Besu Releases page](https://github.com/hyperledger/besu/releases/tag/24.10.0).

3. **`Node.zip`**

   - Contains configuration files for the Dakota Network:
     - `genesis.json`: Defines blockchain parameters.
     - `data/`: Node-specific key pair (`key` and `key.pub`).
     - `Tessera/`: Optional files for Tessera configuration.

4. **`makewallet.js`**

   - A Node.js script to generate Ethereum-compatible wallets for the network.

---

## Prerequisites

### Required Packages

Ensure the following are installed on your system:

1. **Java 21** (Required for Besu):

   **Ubuntu**:
   ```bash
   sudo apt update && sudo apt install -y openjdk-21-jdk
   ```
   **Fedora**:
   ```bash
   sudo dnf install -y java-21-openjdk-devel
   ```

2. **Node.js**:
   Install using `nvm` (Node Version Manager):

   ```bash
   curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash
   source ~/.bashrc
   nvm install 18
   nvm alias default 18
   ```

3. **Unzip Tool**:

   **Ubuntu**:
   ```bash
   sudo apt install -y unzip
   ```
   **Fedora**:
   ```bash
   sudo dnf install -y unzip
   ```

---

## Installation Steps

1. **Download and Extract Files**:
   - Download Besu binaries from [Besu Releases](https://github.com/hyperledger/besu/releases/tag/24.10.0) and extract them to `/opt/besu`:
     ```bash
     tar -xvzf besu-24.10.0.tar.gz -C /opt/besu
     ```
   - Unzip the provided files:
     ```bash
     unzip tessera-24.4.2.zip -d /opt/tessera
     unzip Node.zip -d /home/user/dakota-node
     ```

2. **Verify Installations**:
   - Besu:
     ```bash
     /opt/besu/bin/besu --version
     ```
   - Tessera (optional):
     ```bash
     /opt/tessera/bin/tessera --version
     ```

---

## Using `makewallet.js`

Use this script to generate wallets for the Dakota Network:

1. Navigate to the directory containing `makewallet.js`.
2. Run the script:
   ```bash
   node makewallet.js
   ```
3. Save the private key and public address for use with your node.

---

## Connecting to Dakota Network

1. **Run Besu**:

   Use the following command to start your Besu node and connect to the Dakota Network:

   ```bash
   /opt/besu/bin/besu      --data-path=/home/user/dakota-node/data      --genesis-file=/home/user/dakota-node/genesis.json      --bootnodes=enode://ef2bd01fbaea3b6f255a6811e32e050efa51a93d0dde34593cd0c77d5344ea151f8cce2c1a3aca9baf9a2eb0daaf2abac856ed7d9ca7ad602246e887aa6d3021@100.111.5.6:30303      --p2p-port=30303      --rpc-http-enabled      --rpc-http-api=ETH,NET,QBFT      --host-allowlist="*"      --rpc-http-cors-origins="all"      --rpc-http-port=8545      --p2p-host=100.111.5.7      --sync-min-peers=3
   ```

2. **(Optional) Run Tessera**:

   If privacy is required, start Tessera with the provided configuration:

   ```bash
   /opt/tessera/bin/tessera -configfile /home/user/dakota-node/Tessera/tessera-config1.json
   ```

---

## Additional Notes

- Ensure your firewall allows necessary ports (e.g., `30303` for P2P, `8545` for HTTP-RPC).
- Replace the provided keys in `Node.zip` for production setups.
- Customize `genesis.json` if additional parameters are required.

---

## References

- [Hyperledger Besu Documentation](https://besu.hyperledger.org/)
- [Tessera Documentation](https://docs.consensys.net/tessera/)
