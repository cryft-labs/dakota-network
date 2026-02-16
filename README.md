
# Dakota Network

Smart contracts, tools, and node configuration for the **Dakota Network** — a public QBFT blockchain built on Hyperledger Besu with Tessera privacy.

All project-owned contracts are licensed under **Apache 2.0**. This software is part of a patented system — see the [LICENSE](LICENSE) file and <https://cryftlabs.org/licenses> for details.

Utilizing Software Related to Cryft Labs patent(s) or otherwise infriging upon our patent(s) will result in legal action. Permission to use is required.
---

## Repository Structure

```
dakota-network/
├── Contracts/
│   ├── Code Management/
│   │   ├── CodeManager2.sol          # Permissionless unique ID registry (fee-based)
│   │   ├── ComboStorage.sol          # Redemption verification service
│   │   └── interfaces/
│   │       ├── ICodeManager.sol
│   │       ├── IComboStorage.sol
│   │       └── IRedeemable.sol
│   ├── Genesis/
│   │   ├── besuGenesis.json          # Besu genesis file with contract allocations
│   │   ├── GasManager.sol            # Gas beneficiary — voter-governed funding & burns
│   │   ├── validatorContracts/
│   │   │   ├── ValidatorSmartContractAllowList.sol  # QBFT validator governance
│   │   │   └── ValidatorSmartContractInterface.sol  # Shared interface
│   │   ├── proxy/                    # OpenZeppelin transparent proxy (MIT)
│   │   ├── interfaces/               # OpenZeppelin proxy interfaces (MIT)
│   │   └── utils/                    # OpenZeppelin utilities (MIT)
│   └── Tokens/
│       ├── GreetingCards.sol          # ERC-721 greeting card NFT (CryftGreetingCards)
│       └── interfaces/
│           ├── ICodeManager.sol
│           ├── IComboStorage.sol
│           └── IRedeemable.sol
├── Tools/
│   ├── keywizard/
│   │   └── dakota_keywizard.py       # EOA, Besu node key, and Tessera key generator
│   └── solc_compiler/
│       ├── compile.py                # Local Solidity compiler (py-solc-x)
│       └── compiled_output/          # ABI and artifact output
├── Node.zip                          # Pre-configured node files (genesis, keys, Tessera config)
└── README.md
```

---

## Contracts

### Genesis Contracts (deployed at network genesis)

| Contract | Address | Purpose |
|----------|---------|---------|
| **ValidatorSmartContractAllowList** | `0x0000...1111` | QBFT validator and voter governance with majority-vote quorum. Supports federated voter expansion via external voter contracts. |
| **GasManager** | Genesis beneficiary | Receives block rewards. Voter-governed gas funding to whitelisted addresses with per-period rate limiting. Two-phase ERC-20 token burn (vote to approve, then permissionless execution). Auto-burns native excess above configurable cap. |
| **TransparentUpgradeableProxy** | — | OpenZeppelin transparent proxy pattern for upgradeable genesis contracts. |

### Application Contracts (deployed post-genesis)

| Contract | Purpose |
|----------|---------|
| **CodeManager2** | Permissionless unique ID registry. Charges a configurable registration fee forwarded to a fee vault. Deterministic ID generation via `keccak256(address(this), giftContract, chainId) + counter`. |
| **ComboStorage** | Redemption verification service. Validates codes against CodeManager, records verified redemptions. Access-controlled via CodeManager's whitelist. |
| **CryftGreetingCards** | ERC-721 NFT. Mint-on-purchase with atomic CodeManager registration. Per-batch `PurchaseSegment` storage for gas-efficient buyer/URI lookups (binary search). Explicit freeze for lost/stolen codes. |

---

## Tools

### `Tools/keywizard/dakota_keywizard.py`

Interactive wizard for generating and distributing three types of cryptographic keys across your node network. No external Python packages required (stdlib only).

**Key types:**
- **EOA accounts** — private key + address, optional keystore V3 JSON
- **Besu node keys** — `key` + `key.pub` for P2P identity / validator signing
- **Tessera keys** — via `tessera -keygen` (locked or unlocked)

**SCP distribution:** After generation, the wizard can distribute each key set to remote nodes via SCP with per-key review, retry on failure, and optional deletion of local originals.

**Interactive mode (default):**
```bash
python3 Tools/keywizard/dakota_keywizard.py
```

**CLI flags for scripted/batch use:**
```bash
# Generate 4 Besu node keys + 4 Tessera keys, no EOA, with SCP step
python3 Tools/keywizard/dakota_keywizard.py \
  --besu-count 4 \
  --tessera-count 4 \
  --no-eoa \
  --scp

# Generate 3 EOAs with keystore JSON, output to custom directory
python3 Tools/keywizard/dakota_keywizard.py \
  --eoa-count 3 \
  --eoa-keystore \
  --out /home/user/my-keys

# Non-interactive batch (no SCP, uses defaults)
python3 Tools/keywizard/dakota_keywizard.py \
  --non-interactive \
  --besu-count 4 \
  --tessera-count 4
```

**All flags:**

| Flag | Default | Description |
|------|---------|-------------|
| `--out` | `~/dakota-keys` | Base output directory |
| `--non-interactive` | off | Run without prompts (uses flags/defaults) |
| `--no-eoa` | off | Disable EOA generation |
| `--eoa-count` | 1 | Number of EOA accounts to generate |
| `--eoa-keystore` | off | Also generate keystore V3 JSON |
| `--eoa-keystore-pass` | prompt | Keystore password |
| `--besu-count` | 0 | Number of Besu node keys to generate |
| `--tessera-count` | 0 | Number of Tessera keys to generate |
| `--tessera-bin` | `tessera` | Tessera binary name/path |
| `--tessera-basename` | `nodeKey` | Base filename for Tessera keys |
| `--tessera-locked` | off | Generate password-locked Tessera keys |
| `--name-prefix-eoa` | `eoa-` | Folder prefix for EOA keys |
| `--name-prefix-besu` | `besu-node-` | Folder prefix for Besu node keys |
| `--name-prefix-tessera` | `tessera-` | Folder prefix for Tessera keys |
| `--scp` | off | Enable SCP distribution step |

### `Tools/solc_compiler/compile.py`

Local Solidity compiler using [py-solc-x](https://github.com/iamdefinitelyahuman/py-solc-x). Compiles all `.sol` files under `Contracts/`, resolves GitHub imports, and outputs ABI + bytecode artifacts to `compiled_output/`.

```bash
pip install py-solc-x
python3 Tools/solc_compiler/compile.py
```

Options:
- `--clean-cache` — clear downloaded import cache
- `--solc-version 0.8.19` — override compiler version
- `--evm berlin` — override EVM target

---

## Prerequisites

### Java

Two JDK versions are required:

| Component | Version | Java |
|-----------|---------|------|
| **Besu** | 24.10.0 | Java 21 |
| **Tessera** | 24.4.2 | Java 17 |

---

## Installation (Ubuntu)

The following script installs both Besu and Tessera with pinned Java versions and adds them to your PATH via global wrappers:

```bash
(
  set -e

  # --- Packages (Besu uses Java 21; Tessera pinned to Java 17) ---
  sudo apt update
  sudo apt install -y curl unzip tar openjdk-21-jdk openjdk-17-jre-headless

  # --- Install Besu 24.10.0 (official dist zip) ---
  cd /tmp
  curl -fL -o besu-24.10.0.zip \
    https://github.com/hyperledger/besu/releases/download/24.10.0/besu-24.10.0.zip

  sudo rm -rf /opt/besu-24.10.0
  sudo unzip -q -o besu-24.10.0.zip -d /opt
  sudo chmod +x /opt/besu-24.10.0/bin/besu /opt/besu-24.10.0/bin/evmtool

  # --- Install Tessera 24.4.2 (dist tar) ---
  cd /tmp
  curl -fL -o tessera-dist-24.4.2.tar \
    https://repo1.maven.org/maven2/net/consensys/quorum/tessera/tessera-dist/24.4.2/tessera-dist-24.4.2.tar

  sudo rm -rf /opt/tessera-24.4.2
  sudo mkdir -p /opt/tessera-24.4.2
  sudo tar -xf tessera-dist-24.4.2.tar -C /opt/tessera-24.4.2

  # Find the actual tessera launcher (handles nested directory in the tar)
  TESS_BIN="$(sudo find /opt/tessera-24.4.2 -type f -path '*/bin/tessera' -print | head -n 1)"
  if [ -z "$TESS_BIN" ]; then
    echo "ERROR: Could not locate tessera under /opt/tessera-24.4.2"
    exit 1
  fi

  # --- Global wrappers (pin JAVA_HOME per tool) ---
  sudo tee /usr/local/bin/besu >/dev/null <<'EOF'
#!/usr/bin/env bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
exec /opt/besu-24.10.0/bin/besu "$@"
EOF

  sudo tee /usr/local/bin/tessera >/dev/null <<EOF
#!/usr/bin/env bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
exec "$TESS_BIN" "\$@"
EOF

  sudo chmod +x /usr/local/bin/besu /usr/local/bin/tessera

  # --- Verify ---
  hash -r
  command -v besu
  besu --version
  command -v tessera
  tessera version
)
```

### Extract Node Configuration

`Node.zip` contains an example directory structure with genesis, node keys, and Tessera config:

```bash
unzip Node.zip -d /home/user/dakota-node
```

### Node.js (optional)

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash
source ~/.bashrc
nvm install 18
nvm alias default 18
```

---

## Running a Node

### Start Besu

After installation, `besu` is on your PATH with Java 21 pinned automatically:

```bash
besu \
  --data-path=/home/user/dakota-node/data \
  --genesis-file=/home/user/dakota-node/genesis.json \
  --bootnodes=enode://<BOOTNODE_ENODE>@<BOOTNODE_IP>:30303 \
  --p2p-port=30303 \
  --rpc-http-enabled \
  --rpc-http-api=ETH,NET,QBFT \
  --host-allowlist="*" \
  --rpc-http-cors-origins="all" \
  --rpc-http-port=8545 \
  --p2p-host=<YOUR_IP> \
  --sync-min-peers=3
```

### Start Tessera (optional)

`tessera` is also on your PATH with Java 17 pinned automatically:

```bash
tessera -configfile /home/user/dakota-node/Tessera/tessera-config1.json
```

---

## Security Notes

- Replace the default keys in `Node.zip` before any production deployment.
- Ensure your firewall allows port `30303` (P2P) and `8545` (HTTP-RPC).
- Restrict `--rpc-http-api`, `--host-allowlist`, and `--rpc-http-cors-origins` for production.
- Customize `genesis.json` if additional parameters are required.

---

## Documentation & References

### Besu

Besu documentation has moved to a self-hosted versioned model. The relevant version for Dakota Network is **24.8.0**.

- **Versioned documentation index:** <https://lf-hyperledger.atlassian.net/wiki/spaces/BESU/pages/22156555/Versioned+documentation>
- **Self-host the docs:** Clone the Besu docs repo at tag `24.8.0` and build locally:
  ```bash
  git clone --branch 24.8.0 https://github.com/hyperledger/besu-docs.git
  cd besu-docs
  # Follow the repo's README to serve the docs locally
  ```
- **Besu GitHub releases:** <https://github.com/hyperledger/besu/releases/tag/24.10.0>

### Tessera

Tessera documentation is still available online:

- **Tessera docs:** <https://docs.tessera.consensys.io/>
- **Tessera GitHub:** <https://github.com/ConsenSys/tessera>

---

## License

All project-owned smart contracts and tools are licensed under the **Apache License, Version 2.0**.

This software is part of a patented system. See the [LICENSE](LICENSE) file for the full license text and patent notice, and <https://cryft.net/licenses> for additional details.

OpenZeppelin-derived contracts under `Contracts/Genesis/proxy/`, `Contracts/Genesis/utils/`, and `Contracts/Genesis/interfaces/` retain their original **MIT** license.
