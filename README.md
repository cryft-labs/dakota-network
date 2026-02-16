# Dakota Network

Smart contracts, tools, and node configuration for the **Dakota Network** — a public QBFT blockchain built on Hyperledger Besu with Tessera privacy.

All project-owned contracts are licensed under **Apache 2.0**. This software is part of a patented system — see the [LICENSE](LICENSE) file and <https://cryftlabs.org/licenses> for details.

> **PATENT NOTICE — U.S. Patent Application Serial No. 18/930,857**
>
> Portions of this software implement methods and systems described in [U.S. Patent Application Serial No. 18/930,857: *"Card System Utilizing On-Chain Managed Redeemable Gift Code"*](https://patents.google.com/patent/US20250139608A1/en), held by Cryft Labs.
>
> **The patented system covers the on-chain redeemable-code management architecture embodied primarily by the `CodeManager` and `ComboStorage` contracts.** Unauthorized reproduction, deployment, or commercial use of these contracts or any substantially similar implementation of the patented methods — on any blockchain or network — constitutes patent infringement and **will result in legal action, including injunctive relief and monetary damages, at the infringer's expense.**
>
> The `CryftGreetingCards` ERC-721 contract is a client of the redeemable-code service and is **not** itself the subject of the patent claims. Third parties may interface with the Cryft redeemable-code service (CodeManager / ComboStorage) under a valid license or when the applicable fees and permissions have been granted. See <https://cryftlabs.org/licenses> for licensing inquiries.

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

### Copy Node Configuration

The `Node/` directory contains a sample directory structure with node keys and Tessera config:

```bash
cp -r Node/Node /home/user/dakota-node
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

- Replace the default keys in `Node/` before any production deployment.
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
| **CodeManager2** | **Patent-covered.** Permissionless unique ID registry. Charges a configurable registration fee forwarded to a fee vault. Deterministic ID generation via `keccak256(address(this), giftContract, chainId) + counter`. |
| **ComboStorage** | **Patent-covered.** Redemption verification service. Validates codes against CodeManager, records verified redemptions. Access-controlled via CodeManager's whitelist. |
| **CryftGreetingCards** | ERC-721 NFT (service client — not patent-covered). Mint-on-purchase with atomic CodeManager registration. Per-batch `PurchaseSegment` storage for gas-efficient buyer/URI lookups (binary search). Explicit freeze for lost/stolen codes. Interfacing with the redeemable-code service is permitted with proper fees or license. |

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

### `Tools/bytecode_replacer/replace_bytecode.py`

Bulk bytecode replacer for genesis files. Finds all occurrences of one runtime bytecode string and replaces it with another — designed for large genesis files (hundreds of MB) with tens of thousands of identical pre-deployed contract entries.

**Workflow:**
1. Paste the **old** runtime bytecode (hex, with or without `0x`) into `old.txt`
2. Paste the **new** runtime bytecode into `new.txt`
3. Run against the target file:

```bash
python3 Tools/bytecode_replacer/replace_bytecode.py Contracts/Genesis/besuGenesis.json
```

**Options:**

| Flag | Description |
|------|-------------|
| `--old-file <path>` | Path to old bytecode file (default: `old.txt` in same directory) |
| `--new-file <path>` | Path to new bytecode file (default: `new.txt` in same directory) |
| `--dry-run` | Count matches without modifying the file |
| `--no-backup` | Skip creating a `.bak` backup before replacing |

The tool automatically normalizes `0x` prefixes (strips them for matching, preserves them in the output), creates a backup by default, and verifies the replacement count after writing.

### `Tools/tx_simulator/tx_simulator.py`

Configurable transaction simulator for QBFT/PoA chains. Four independent knobs control traffic shape — **sender selection**, **recipient selection**, **amount distribution**, and **timing/rate** — with defaults that reproduce the original round-robin ring behavior. Automatically injects the PoA `extraData` middleware for web3.py compatibility.

**Features:**
- **Pluggable distribution modes** — mix and match sender, recipient, amount, and timing strategies independently.
- **Flexible account sourcing** — BIP-39 mnemonic (with `--indices` or `--num-accounts`), inline private keys, or a key file. Sources are combinable.
- **Async receipt polling** — never blocks waiting for mining; polls receipts in the background.
- **Balance-safe** — maintains a configurable reserve in each account; skips a tx if balance is too low.
- **Optional top-ups** — a designated funder account can automatically replenish underfunded accounts.
- **EIP-1559 aware** — uses type-2 transactions when `baseFeePerGas` is present, falls back to legacy `gasPrice` otherwise.

**Prerequisites:**
```bash
pip install web3 eth-account
```

**Usage:**
```bash
# Original 3-account ring (all defaults)
python3 Tools/tx_simulator/tx_simulator.py \
  --rpc http://100.111.32.1:8545 \
  --prompt-mnemonic

# 10 HD accounts, weighted senders, random recipients, Poisson timing
python3 Tools/tx_simulator/tx_simulator.py \
  --rpc http://100.111.32.1:8545 \
  --prompt-mnemonic --num-accounts 10 \
  --sender-mode weighted --sender-weights 50,20,10,5,5,3,3,2,1,1 \
  --recipient-mode random-uniform \
  --amount-mode log-normal --amount-min-eth 0.00001 --amount-max-eth 0.1 \
  --timing-mode poisson --target-tps 5

# Private keys from file, burst timing, star fan-out
python3 Tools/tx_simulator/tx_simulator.py \
  --rpc http://100.111.32.1:8545 \
  --private-keys-file keys.txt \
  --recipient-mode star-fan-out \
  --timing-mode bursts --burst-size 20 --burst-pause 5
```

**Distribution modes:**

| Knob | Mode | Description |
|------|------|-------------|
| **Sender** | `round-robin` | A0, A1, A2, … rotate each tx *(default)* |
| | `single` | One account sends all txs (`--single-sender-pos`) |
| | `weighted` | Probability weights per account (`--sender-weights`) |
| | `multi-hot` | First K accounts send, rest are recipient-only (`--hot-senders`) |
| | `random` | Sender picked uniformly at random |
| **Recipient** | `ring` | A[i] → A[i+1 mod n] *(default)* |
| | `star-fan-out` | Hub → random other (overrides sender to hub; `--hub-pos`) |
| | `star-fan-in` | Any non-hub → hub (`--hub-pos`) |
| | `random-uniform` | Random pair, no self-send |
| | `random-no-repeat` | Like uniform but no immediate repeat of same pair |
| | `partitioned` | Only send within same group (`--partition-size`) |
| | `bursty` | Target a random subset for T seconds, then switch (`--campaign-duration`) |
| **Amount** | `fixed` | Constant amount every tx *(default)* |
| | `uniform-random` | Uniform random in [min, max] |
| | `log-normal` | Many small, occasional large (`--log-sigma`; clamped to [min, max]) |
| | `step-schedule` | Cycle through amounts on a timer (`--step-amounts`, `--step-duration`) |
| | `balance-aware` | Half of (balance − reserve), clamped to [min, max] |
| **Timing** | `per-block` | One tx per new block *(default)* |
| | `fixed-tps` | Constant transactions per second (`--target-tps`) |
| | `poisson` | Exponential inter-arrival, average = target TPS |
| | `bursts` | Send N rapidly, pause, repeat (`--burst-size`, `--burst-pause`) |
| | `ramp` | Linearly increase TPS (`--ramp-start-tps` → `--ramp-end-tps` over `--ramp-duration`) |
| | `jittered` | Base interval ± random jitter (`--jitter-base`, `--jitter-range`) |

**All flags:**

| Flag | Default | Description |
|------|---------|-------------|
| `--rpc` | *(required)* | RPC endpoint URL |
| `--mnemonic` | — | BIP-39 seed phrase (visible in shell history) |
| `--prompt-mnemonic` | off | Prompt for mnemonic via hidden input |
| `--indices` | `0,1,2` | Comma-separated HD derivation indices |
| `--num-accounts` | — | Derive N accounts (indices 0..N-1); overrides `--indices` |
| `--private-keys` | — | Comma-separated hex private keys (with or without `0x`) |
| `--private-keys-file` | — | File with one hex private key per line (`#` comments OK) |
| `--sender-mode` | `round-robin` | Sender selection strategy |
| `--single-sender-pos` | `0` | Account position for `single` mode |
| `--sender-weights` | — | Comma-separated weights for `weighted` mode |
| `--hot-senders` | `1` | Hot sender count for `multi-hot` mode |
| `--recipient-mode` | `ring` | Recipient selection strategy |
| `--hub-pos` | `0` | Hub position for `star-fan-out` / `star-fan-in` |
| `--partition-size` | `2` | Group size for `partitioned` mode |
| `--campaign-duration` | `30` | Seconds per subset for `bursty` recipient mode |
| `--campaign-subset` | half | Target subset size for `bursty` mode |
| `--amount-mode` | `fixed` | Amount distribution strategy |
| `--amount-eth` | `0.0001` | Fixed ETH per tx |
| `--amount-min-eth` | `0.00001` | Min ETH for random / log-normal / balance-aware |
| `--amount-max-eth` | `0.01` | Max ETH for random / log-normal / balance-aware |
| `--log-sigma` | `1.0` | Sigma for log-normal (higher = heavier tail) |
| `--step-amounts` | — | Comma-separated ETH amounts for `step-schedule` |
| `--step-duration` | `60` | Seconds per step for `step-schedule` |
| `--timing-mode` | `per-block` | Timing / rate strategy |
| `--target-tps` | `5` | Target TPS for `fixed-tps` / `poisson` |
| `--burst-size` | `50` | Txs per burst for `bursts` timing |
| `--burst-pause` | `10` | Pause seconds between bursts |
| `--ramp-start-tps` | `1` | Starting TPS for `ramp` mode |
| `--ramp-end-tps` | `50` | Target TPS for `ramp` mode |
| `--ramp-duration` | `300` | Ramp duration in seconds |
| `--jitter-base` | `1.0` | Base interval seconds for `jittered` mode |
| `--jitter-range` | `0.5` | ± jitter range seconds |
| `--poll-interval` | `0.2` | Loop sleep when idle |
| `--tip-wei` | `1000` | Priority fee (tip) in wei |
| `--max-fee-multiplier` | `2` | `maxFee = baseFee × multiplier + tip` |
| `--topup-enabled` | off | Auto-replenish underfunded accounts |
| `--topup-funder-pos` | `0` | Funder account position |
| `--topup-target-eth` | `0.01` | Top-up accounts to this ETH balance |
| `--reserve-eth` | `0.001` | Reserve ETH kept per account |
| `--max-inflight` | `64` | Max pending txs before pausing sends |

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

## Repository Structure

```
dakota-network/
├── LICENSE                            # Apache 2.0 + patent notice
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
│   ├── bytecode_replacer/
│   │   ├── replace_bytecode.py        # Bulk bytecode replacer for genesis files
│   │   ├── old.txt                    # Old bytecode to find (paste here)
│   │   └── new.txt                    # New bytecode to replace with (paste here)
│   ├── keywizard/
│   │   └── dakota_keywizard.py       # EOA, Besu node key, and Tessera key generator
│   ├── tx_simulator/
│   │   └── tx_simulator.py            # Block-paced ETH transfer loop (QBFT/PoA)
│   └── solc_compiler/
│       ├── compile.py                # Local Solidity compiler (py-solc-x)
│       └── compiled_output/          # ABI and artifact output
├── Node/                             # Sample node directory structure
│   ├── genesisPalceholder.json       # Placeholder genesis (production file too large for repo)
│   └── Node/
│       ├── data/
│       │   ├── key                   # Besu node private key (P2P / validator signing)
│       │   └── key.pub               # Besu node public key
│       └── Tessera/
│           ├── tessera-config1.json   # Tessera privacy manager configuration
│           ├── node1.key             # Tessera private key
│           └── node1.pub             # Tessera public key
└── README.md
```

---

## License

All project-owned smart contracts and tools are licensed under the **Apache License, Version 2.0**.

This software is part of a patented system. See the [LICENSE](LICENSE) file for the full license text and patent notice, and <https://cryftlabs.org/licenses> for additional details.

OpenZeppelin-derived contracts under `Contracts/Genesis/proxy/`, `Contracts/Genesis/utils/`, and `Contracts/Genesis/interfaces/` retain their original **MIT** license.

### Patent Enforcement

The `CodeManager` and `ComboStorage` contracts implement methods claimed in [U.S. Patent Application Serial No. 18/930,857](https://patents.google.com/patent/US20250139608A1/en). **Any unauthorized use, reproduction, or deployment of these contracts or substantially similar implementations will be pursued through legal action. All costs, damages, and attorney fees will be sought against the infringing party.** Contact <https://cryftlabs.org/licenses> for licensing.
