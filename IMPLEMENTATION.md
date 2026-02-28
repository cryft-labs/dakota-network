# Implementation Guide — Patented Redeemable Code Architecture

> **PATENT & LICENSING NOTICE**
>
> The architecture described in this guide — including the three-layer system of CodeManager (public registry/router), gift contracts (IRedeemable authority), and PrivateComboStorage (Pente privacy group) — is covered by [U.S. Patent Application Serial No. 18/930,857: *"Card System Utilizing On-Chain Managed Redeemable Gift Code"*](https://patents.google.com/patent/US20250139608A1/en), held by Cryft Labs. The patent covers the complete system architecture, data flow, hash-based code verification, privacy-preserving storage, and the public/private routing mechanism.
>
> **Implementing, deploying, or operating the described system — or any substantially similar architecture — requires a license from Cryft Labs.** This includes deploying the contracts, implementing the standardized interfaces, or operating a privacy group that routes redemption state changes to a public chain.
>
> This guide is provided for **licensed parties only**. See <https://cryftlabs.org/licenses> for licensing inquiries.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Layer 1 — Besu Network Setup](#3-layer-1--besu-network-setup)
   - 3.1 [Install Besu (Ubuntu)](#31-install-besu-ubuntu)
   - 3.2 [Genesis Configuration](#32-genesis-configuration)
   - 3.3 [Genesis Contract Allocation](#33-genesis-contract-allocation)
   - 3.4 [Start a Node](#34-start-a-node)
   - 3.5 [Security & Permissions](#35-security--permissions)
4. [Layer 2 — Paladin / Pente Privacy Setup](#4-layer-2--paladin--pente-privacy-setup)
   - 4.1 [Method A — Docker](#41-method-a--docker-no-kubernetes-required)
   - 4.2 [Method B — Build from Source](#42-method-b--build-from-source)
   - 4.3 [Method C — k3s + Helm](#43-method-c--k3s--helm-kubernetes-operator)
   - 4.4 [Paladin Privacy Domains](#44-paladin-privacy-domains)
   - 4.5 [Paladin UI](#45-paladin-ui)
   - 4.6 [Paladin Resources](#46-paladin-resources)
   - 4.7 [Create a Pente Privacy Group](#47-create-a-pente-privacy-group)
   - 4.8 [Authorize Privacy Group on CodeManager](#48-authorize-the-privacy-group-on-codemanager)
   - 4.9 [Documentation & References](#49-documentation--references)
5. [Layer 3 — Contract Deployment](#5-layer-3--contract-deployment)
6. [Standardized Interfaces for Gift Contracts](#6-standardized-interfaces-for-gift-contracts)
7. [Implementing a Custom Gift Contract](#7-implementing-a-custom-gift-contract)
8. [Bulk Code Storage via Pente](#8-bulk-code-storage-via-pente)
9. [Redemption Flow (End to End)](#9-redemption-flow-end-to-end)
10. [Web Application Integration (thirdweb + Paladin API)](#10-web-application-integration-thirdweb--paladin-api)
11. [ERC-721 / ERC-6551 / ERC-1155 Token Patterns](#11-erc-721--erc-6551--erc-1155-token-patterns)
12. [Gas Sponsorship](#12-gas-sponsorship)
13. [Deployment Checklist](#13-deployment-checklist)

---

## 1. Architecture Overview

The patented system uses a three-layer architecture where no single layer holds all the data needed to compromise a redeemable code:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PUBLIC CHAIN (Besu)                          │
│                                                                     │
│  ┌──────────────────┐              ┌────────────────────────────┐   │
│  │   CodeManager    │─── resolve ─▶│      Gift Contract         │   │
│  │   (Registry +    │   UID→gift   │      (IRedeemable)         │   │
│  │    Router)       │              │      SOLE STATE AUTHORITY   │   │
│  │                  │◀── forward ──│                             │   │
│  │  • UID registry  │   calls via  │  • frozen / unfrozen state │   │
│  │  • Governance    │  IRedeemable │  • redeemed tracking       │   │
│  │  • Fee vault     │              │  • content assignment      │   │
│  │  • Privacy group │              │  • redemption behavior     │   │
│  │    authorization │              │    (NFT transfer, mint,    │   │
│  └────────┬─────────┘              │     counter, etc.)         │   │
│           │ ▲                      └────────────────────────────┘   │
│           │ │                                                       │
│           │ │ PenteExternalCall (atomic routing)                    │
│           │ │                                                       │
│  ┌────────▼─┴───────────────────────────────────────────────────┐   │
│  │                  PENTE PRIVACY GROUP                          │   │
│  │  ┌──────────────────────┐                                    │   │
│  │  │ PrivateComboStorage  │  • Hash+salt code pairs (private)  │   │
│  │  │                      │  • PIN-based O(1) bucket lookup    │   │
│  │  │                      │  • Private frozen/redeemed state   │   │
│  │  │                      │  • Batch code storage              │   │
│  │  │                      │  • Hash verification (no cleartext)│   │
│  │  └──────────────────────┘                                    │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer | Contract | Responsibility |
|-------|----------|----------------|
| **Public Registry** | CodeManager | UID registration, deterministic ID generation, governance (2/3 supermajority), Pente router — forwards calls to gift contracts. Stores **no** per-UID state. |
| **Public Authority** | Gift Contract (IRedeemable) | Sole authority on per-UID state: frozen status, content assignment, redemption behavior. Decides how redemption works (single-use, multi-use, NFT transfer, etc.). |
| **Private Storage** | PrivateComboStorage | Hash+salt code storage within a Pente privacy group. Verifies codes via hash comparison. Emits `PenteExternalCall` events to atomically route state changes through CodeManager to the gift contract. |

### Key Design Principles

- **No cleartext codes on-chain.** Codes are represented as `keccak256(pin + code)` hashes. The PIN acts as a bucket key for O(1) lookup.
- **Gift contract authority.** CodeManager delegates all per-UID state management. If the gift contract reverts, the entire Pente transition rolls back atomically.
- **Default frozen state.** New UIDs default to frozen=true until explicitly unfrozen, preventing premature redemption.
- **Privacy-preserving verification.** The Pente privacy group verifies codes privately, then triggers public state updates via `PenteExternalCall`.

---

## 2. Prerequisites

### Software

| Component | Version | Purpose |
|-----------|---------|---------|
| **Hyperledger Besu** | 26.1.0 | EVM blockchain client (QBFT consensus) |
| **Java** | 21 | Besu runtime |
| **Paladin** | Latest | Privacy manager (Pente privacy groups) |
| **Docker** | 24+ | Paladin container runtime (no Kubernetes required) |
| **solc** | 0.8.34 | Solidity compiler |
| **Node.js** | 18+ | Web application / thirdweb SDK |
| **Python** | 3.10+ | Compilation tooling |

> **Note:** Paladin can also be deployed via Kubernetes (k3s + Helm) for multi-node production environments. See [Method C in the README](README.md) for the Kubernetes approach. Prepackaged Paladin binaries for licensed parties are planned once the system is established.

### Accounts & Services

| Service | Purpose |
|---------|---------|
| **thirdweb** | In-app wallets, gas sponsorship, contract interaction API |
| **IPFS provider** (Pinata / web3.storage) | NFT metadata hosting |
| **Blockscout** (self-hosted) | Chain explorer for ERC-721/1155/6551 display |

---

## 3. Layer 1 — Besu Network Setup

### 3.1 Install Besu (Ubuntu)

Besu is deployed as a **managed systemd service** under a dedicated non-root runtime user (`besurun`). All node-specific configuration is driven by an environment file — not by hardcoded command-line flags in the service unit.

#### Service Architecture

```text
systemd (besu.service)
  └─▶ /usr/local/lib/dakota/run-besu.sh   (wrapper script)
        └─▶ sources /etc/dakota/besu-current.env   (node config)
              └─▶ launches /usr/local/bin/besu   (Besu binary)
```

#### File Layout

| Path | Purpose |
|------|--------|
| `/etc/dakota/besu-current.env` | Active runtime configuration for the node |
| `/usr/local/lib/dakota/run-besu.sh` | Wrapper script used by systemd to launch Besu |
| `/var/lib/dakota/besu/genesis.json` | Node genesis file |
| `/var/lib/dakota/besu/data` | Besu data directory (chain DB, caches, runtime state) |

#### Step 1 — Install Packages and Besu Binary

```bash
sudo apt update
sudo apt install -y curl unzip openjdk-21-jdk ca-certificates

cd /tmp
curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
  -o besu-26.1.0.zip \
  https://github.com/hyperledger/besu/releases/download/26.1.0/besu-26.1.0.zip
unzip -t /tmp/besu-26.1.0.zip >/dev/null   # verify integrity
sudo unzip -q -o besu-26.1.0.zip -d /opt
sudo ln -sfn /opt/besu-26.1.0/bin/besu /usr/local/bin/besu
besu --version
```

**SHA-256 checksums (26.1.0):**
```
356bae18a4c08a2135aa006e62a550b52428e1d613c08aa97c40ec8b908ae6cf  besu-26.1.0.zip
de6356bf2db9e7a68dc3de391864dc373a0440f51fbf6d78d63d1e205091248e  besu-26.1.0.tar.gz
```

#### Step 2 — Create the Runtime User and Directory Structure

The target directory layout for a Dakota / Cryft Besu node is:

```text
/etc/dakota/
└── besu-current.env              # active node configuration (sourced, not executed)

/usr/local/lib/dakota/
└── run-besu.sh                   # wrapper script launched by systemd

/var/lib/dakota/besu/
├── genesis.json                  # network genesis (root-owned, besurun-readable)
└── data/
    ├── key                       # Besu node private key  (besurun:600)
    └── key.pub                   # Besu node public key   (besurun:644)
```

Create everything in one pass:

```bash
# Create the dedicated service account (no login shell, no home dir)
sudo useradd --system --shell /usr/sbin/nologin --no-create-home besurun

# Create the directory structure
sudo mkdir -p /etc/dakota
sudo mkdir -p /usr/local/lib/dakota
sudo mkdir -p /var/lib/dakota/besu/data

# Copy the genesis file into place
sudo cp genesis.json /var/lib/dakota/besu/genesis.json
```

#### Step 3 — Create the Environment File

Create `/etc/dakota/besu-current.env` with the node-specific configuration. This is the **canonical source** of all runtime values for the node:

```bash
sudo tee /etc/dakota/besu-current.env > /dev/null << 'ENVEOF'
# ── Dakota / Cryft Besu Node Configuration ──────────────────────────
# This file is sourced (not executed) by /usr/local/lib/dakota/run-besu.sh

# ── Identity ─────────────────────────────────────────────────────────
NODE_ID="node1"
NODE_LABEL="Dakota Validator 1"
RUN_USER="besurun"
RUN_GROUP="besurun"

# ── Paths ────────────────────────────────────────────────────────────
BESU_BIN="/usr/local/bin/besu"
GENESIS_FILE="/var/lib/dakota/besu/genesis.json"
BESU_DATA_PATH="/var/lib/dakota/besu/data"

# ── P2P ──────────────────────────────────────────────────────────────
P2P_HOST="0.0.0.0"
P2P_PORT="30303"
NAT_METHOD="NONE"

# ── HTTP RPC ─────────────────────────────────────────────────────────
RPC_HTTP_ENABLED="true"
RPC_HTTP_HOST="0.0.0.0"
RPC_HTTP_PORT="8545"
RPC_HTTP_API="ETH,NET,QBFT"
HOST_ALLOWLIST="*"
RPC_HTTP_CORS_ORIGINS="all"

# ── WebSocket RPC ────────────────────────────────────────────────────
RPC_WS_ENABLED="true"
RPC_WS_HOST="0.0.0.0"
RPC_WS_PORT="8546"
RPC_WS_API="ETH,NET,QBFT"

# ── Metrics ──────────────────────────────────────────────────────────
METRICS_ENABLED="false"
METRICS_HOST="0.0.0.0"
METRICS_PORT="9545"

# ── Logging ──────────────────────────────────────────────────────────
LOGGING="INFO"
MIN_GAS_PRICE="0"

# ── Bootnodes ────────────────────────────────────────────────────────
BOOTNODES_ENABLED="true"
BOOTNODE_ENODE="enode://<PUBKEY>@<BOOTNODE_IP>:30303"

# ── Extra Arguments ──────────────────────────────────────────────────
EXTRA_BESU_ARGS="--sync-min-peers=3"

# ── Data Reset (use with extreme caution) ────────────────────────────
RESET_BESU_DATA_ON_START="false"
RESET_BESU_DATA_KEEP_KEYS="true"
RESET_BESU_DATA_CONFIRM="false"
ENVEOF
```

> **Important:** Restrict `HOST_ALLOWLIST` and `RPC_HTTP_CORS_ORIGINS` for production. The values `*` and `all` are shown here for initial setup convenience.

#### Step 4 — Create the Wrapper Script

Create `/usr/local/lib/dakota/run-besu.sh`. This script is responsible for sourcing the env file, validating required variables, assembling the Besu command line, and optionally performing a controlled data reset:

```bash
sudo tee /usr/local/lib/dakota/run-besu.sh > /dev/null << 'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

# ── Source the active configuration ──────────────────────────────────
ENV_FILE="/etc/dakota/besu-current.env"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
source "$ENV_FILE"

# ── Validate required variables ──────────────────────────────────────
for var in BESU_BIN GENESIS_FILE BESU_DATA_PATH P2P_HOST P2P_PORT \
           RPC_HTTP_PORT RPC_WS_PORT; do
  if [[ -z "${!var:-}" ]]; then
    echo "FATAL: required variable $var is not set in $ENV_FILE" >&2
    exit 1
  fi
done

if [[ ! -x "$BESU_BIN" ]]; then
  echo "FATAL: Besu binary not found or not executable: $BESU_BIN" >&2
  exit 1
fi

# ── Optional: controlled data reset ──────────────────────────────────
if [[ "${RESET_BESU_DATA_ON_START:-false}" == "true" \
   && "${RESET_BESU_DATA_CONFIRM:-false}" == "true" ]]; then
  echo "WARNING: resetting Besu data at $BESU_DATA_PATH"
  if [[ "${RESET_BESU_DATA_KEEP_KEYS:-true}" == "true" ]]; then
    find "$BESU_DATA_PATH" -mindepth 1 -not -name 'key' -not -name 'key.pub' -delete 2>/dev/null || true
  else
    rm -rf "${BESU_DATA_PATH:?}"/*
  fi
fi

# ── Assemble the Besu command ────────────────────────────────────────
CMD=(
  "$BESU_BIN"
  --genesis-file="$GENESIS_FILE"
  --data-path="$BESU_DATA_PATH"
  --p2p-host="$P2P_HOST"
  --p2p-port="$P2P_PORT"
  --nat-method="${NAT_METHOD:-NONE}"
  --min-gas-price="${MIN_GAS_PRICE:-0}"
  --logging="${LOGGING:-INFO}"
)

# HTTP RPC
if [[ "${RPC_HTTP_ENABLED:-false}" == "true" ]]; then
  CMD+=(
    --rpc-http-enabled
    --rpc-http-host="${RPC_HTTP_HOST:-127.0.0.1}"
    --rpc-http-port="$RPC_HTTP_PORT"
    --rpc-http-api="${RPC_HTTP_API:-ETH,NET}"
    --host-allowlist="${HOST_ALLOWLIST:-localhost}"
    --rpc-http-cors-origins="${RPC_HTTP_CORS_ORIGINS:-none}"
  )
fi

# WebSocket RPC
if [[ "${RPC_WS_ENABLED:-false}" == "true" ]]; then
  CMD+=(
    --rpc-ws-enabled
    --rpc-ws-host="${RPC_WS_HOST:-127.0.0.1}"
    --rpc-ws-port="$RPC_WS_PORT"
    --rpc-ws-api="${RPC_WS_API:-ETH,NET}"
  )
fi

# Metrics
if [[ "${METRICS_ENABLED:-false}" == "true" ]]; then
  CMD+=(
    --metrics-enabled
    --metrics-host="${METRICS_HOST:-127.0.0.1}"
    --metrics-port="${METRICS_PORT:-9545}"
  )
fi

# Bootnodes
if [[ "${BOOTNODES_ENABLED:-false}" == "true" && -n "${BOOTNODE_ENODE:-}" ]]; then
  CMD+=(--bootnodes="$BOOTNODE_ENODE")
fi

# Extra arguments (word-split intentionally)
if [[ -n "${EXTRA_BESU_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  CMD+=($EXTRA_BESU_ARGS)
fi

echo "[run-besu] launching: ${CMD[*]}"
exec "${CMD[@]}"
WRAPEOF
```

#### Step 5 — Create the systemd Service Unit

```bash
sudo tee /etc/systemd/system/besu.service > /dev/null << 'UNITEOF'
[Unit]
Description=Hyperledger Besu (Dakota Network)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=besurun
Group=besurun
ExecStart=/usr/local/lib/dakota/run-besu.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
LimitNPROC=65536

# Hardening
ProtectSystem=strict
ReadWritePaths=/var/lib/dakota/besu
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNITEOF
```

#### Step 6 — Set Ownership and Permissions

```bash
# Configuration directory — root-owned, group-readable by besurun
sudo chown root:besurun /etc/dakota
sudo chmod 750 /etc/dakota

# Environment file — root-owned, group-readable by besurun
sudo chown root:besurun /etc/dakota/besu-current.env
sudo chmod 640 /etc/dakota/besu-current.env

# Wrapper script — root-owned, group-executable by besurun
sudo chown root:besurun /usr/local/lib/dakota/run-besu.sh
sudo chmod 750 /usr/local/lib/dakota/run-besu.sh

# Besu runtime data — owned by besurun
sudo chown -R besurun:besurun /var/lib/dakota/besu
sudo find /var/lib/dakota/besu -type d -exec chmod 750 {} \;

# Genesis file — root-owned, readable by besurun
sudo chown root:besurun /var/lib/dakota/besu/genesis.json
sudo chmod 640 /var/lib/dakota/besu/genesis.json

# Restore SELinux contexts if applicable
sudo restorecon -Rv /etc/dakota /usr/local/lib/dakota /var/lib/dakota/besu 2>/dev/null || true
```

#### Step 7 — Enable and Start the Service

```bash
sudo systemctl daemon-reload
sudo systemctl enable besu
sudo systemctl start besu
```

#### Step 8 — Validate

```bash
systemctl status besu
systemctl cat besu
systemctl show -p User -p Group besu
journalctl -u besu -f -n 100

# Verify file layout
ls -ld /etc/dakota /usr/local/lib/dakota /var/lib/dakota/besu
ls -l /etc/dakota/besu-current.env /usr/local/lib/dakota/run-besu.sh
```

Expected output from `systemctl show`:
```
User=besurun
Group=besurun
```

#### Upgrading from an older Besu (and removing Tessera)

Tessera is no longer used — Paladin/Pente replaces it for private transaction support. The following script stops services, removes Tessera completely (systemd, binaries, config), removes old Besu versions, installs 26.1.0, and preserves the systemd service model:

```bash
(
  set -euo pipefail

  echo "==[1] Packages =="
  sudo apt update
  sudo apt install -y curl unzip openjdk-21-jdk ca-certificates

  echo "==[2] Stop services =="
  sudo systemctl stop besu 2>/dev/null || true
  sudo systemctl stop tessera 2>/dev/null || true

  echo "==[3] Remove Tessera (system + path + local config dir) =="
  sudo systemctl disable tessera 2>/dev/null || true
  sudo systemctl reset-failed tessera 2>/dev/null || true
  sudo rm -f /etc/systemd/system/tessera.service
  sudo rm -f /lib/systemd/system/tessera.service
  sudo rm -f /usr/local/bin/tessera
  sudo rm -f /usr/bin/tessera
  sudo rm -rf /opt/tessera-*
  sudo systemctl daemon-reload 2>/dev/null || true

  echo "==[4] Remove old Besu =="
  sudo rm -rf /opt/besu-24.10.0
  sudo rm -rf /opt/besu-26.1.0

  echo "==[5] Download Besu 26.1.0 =="
  builtin cd /tmp
  rm -f besu-26.1.0.zip
  curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
    -o besu-26.1.0.zip \
    https://github.com/hyperledger/besu/releases/download/26.1.0/besu-26.1.0.zip

  echo "==[6] Verify zip file =="
  ls -lh /tmp/besu-26.1.0.zip
  unzip -t /tmp/besu-26.1.0.zip >/dev/null

  echo "==[7] Install Besu =="
  sudo unzip -q -o /tmp/besu-26.1.0.zip -d /opt

  echo "==[8] Symlink =="
  sudo ln -sfn /opt/besu-26.1.0/bin/besu /usr/local/bin/besu

  echo "==[9] Verify install =="
  /usr/local/bin/besu --version || /opt/besu-26.1.0/bin/besu --version

  echo "==[10] Restart service =="
  sudo systemctl daemon-reload
  sudo systemctl start besu
) && echo "Besu 26.1.0 installed, Tessera removed. Service restarted."
```

> **Note:** After an upgrade, the existing `/etc/dakota/besu-current.env`, wrapper script, and `besu.service` unit remain in place. Only the `/opt/besu-26.1.0` binary is replaced.

#### Legacy Cleanup

Some hosts may still contain leftover service skeletons from an earlier approach. These are **not** part of the active deployment pattern and should be removed:

```bash
# Remove stale Paladin/Tessera service remnants
sudo rm -f /etc/systemd/system/paladin.service
sudo rm -f /etc/dakota/paladin-current.env
sudo rm -f /etc/dakota/paladin-node*.env
sudo systemctl daemon-reload 2>/dev/null || true
```

#### Breaking Changes in 26.1.0

- The experimental CLI flag `--Xenable-extra-debug-tracers` has been **removed**. The call tracer (`callTracer`) is now always available for `debug_trace*` methods.
- `eth_getLogs` and `trace_filter` now return an **error** (instead of an empty list) if `fromBlock > toBlock` or `toBlock` extends beyond chain head.
- Plugin API changes: `BlockHeader`, `Log`, `TransactionProcessingResult`, and `TransactionReceipt` now use specific types for `LogsBloomFilter`, `LogTopic`, and `Log`.

#### Upcoming Deprecations (post-26.1.0)

The Besu maintainers have announced the following features will be **removed** in future releases ([details](https://www.lfdecentralizedtrust.org/blog/sunsetting-tessera-and-simplifying-hyperledger-besu)):

| Feature | Status | Replacement |
|---------|--------|-------------|
| **Tessera privacy** | **Deprecated & removed** | [Paladin](https://github.com/LFDT-Paladin/paladin) |
| Smart-contract-based permissioning | Deprecated | Plugin API |
| Proof of Work consensus | Deprecated | Plugin API |
| Fast Sync | Deprecated | Snap Sync (direct migration) |
| ETC / Mordor / Holesky networks | Deprecated | — |
| Decimal block number parameters | Deprecated | Hex-only block numbers |

> **Tessera has been sunset.** The Besu project officially recommends migrating to [Paladin](https://github.com/LFDT-Paladin/paladin) for programmable privacy on EVM.

#### Generate Node Keys

Each node needs a unique P2P / validator signing key pair. Generate them with Besu and place them in the data directory:

```bash
# Generate a new key pair
besu --data-path=/tmp/besu-keygen public-key export \
  --to=/tmp/besu-keygen/key.pub

# Move into the Besu data directory
sudo mv /tmp/besu-keygen/key     /var/lib/dakota/besu/data/key
sudo mv /tmp/besu-keygen/key.pub /var/lib/dakota/besu/data/key.pub
rm -rf /tmp/besu-keygen

# Set ownership and permissions
sudo chown besurun:besurun /var/lib/dakota/besu/data/key /var/lib/dakota/besu/data/key.pub
sudo chmod 600 /var/lib/dakota/besu/data/key
sudo chmod 644 /var/lib/dakota/besu/data/key.pub
```

Alternatively, the `Tools/KeyWizard/dakota_keywizard.py` script can generate Besu node keys.

> **Never reuse keys across nodes.** Each validator and RPC node must have its own unique key pair.

### 3.2 Genesis Configuration

The genesis file lives at `/var/lib/dakota/besu/genesis.json` and must activate all forks through Osaka from block 0. Key parameters:

```json
{
  "config": {
    "chainId": 112311,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "pragueTime": 0,
    "osakaTime": 0,
    "bpo1Time": 0,
    "bpo2Time": 0,
    "qbft": {
      "blockperiodseconds": 1,
      "emptyblockperiodseconds": 64,
      "epochlength": 64000,
      "requesttimeoutseconds": 86
    }
  }
}
```

> **`pragueTime: 0`** is required for EIP-7702 delegation and Pente privacy group support.

### 3.3 Genesis Contract Allocation

The genesis `alloc` section must include pre-deployed system contracts:

| Address | Contract | Purpose |
|---------|----------|---------|
| `0x...1111` | ValidatorSmartContractAllowList | QBFT validator governance |
| `0x...cafE` | GasManager | Block reward distribution, gas funding |
| `0x...c0DE` | CodeManager (proxy) | UID registry + Pente router |
| `0x...FacAdE` | ProxyAdmin | Upgrade dispatch for all proxies |
| `0x...de1E6A7E` | DakotaDelegation (proxy) | EIP-7702 delegation target |
| `0x...FEeD` | GasSponsor (proxy) | Gas sponsorship treasury |

### 3.4 Start a Node

Besu is managed entirely through systemd. **Do not run Besu as a root-owned ad-hoc process.** All node-specific configuration is in `/etc/dakota/besu-current.env`.

#### Starting the Service

```bash
sudo systemctl start besu
```

#### Stopping the Service

```bash
sudo systemctl stop besu
```

#### Checking Status

```bash
systemctl status besu
journalctl -u besu -f -n 100
```

#### Changing Node Configuration

All runtime configuration changes are made by editing the env file and restarting the service:

```bash
sudo nano /etc/dakota/besu-current.env    # edit the configuration
sudo systemctl restart besu               # apply changes
journalctl -u besu -f -n 50               # verify startup
```

> **Important:** Do not bypass the wrapper script or embed node-specific flags directly into the systemd unit. The env-driven design keeps configuration portable and auditable.

> **Note:** The `RPC_WS_*` variables enable WebSocket RPC, required if connecting Paladin to this node.

### 3.5 Security & Permissions

#### Runtime Principle

Besu runs as the dedicated service account `besurun:besurun`. Root is only used for package installation, file placement, ownership/permission correction, service registration, and controlled maintenance actions. **At runtime, Besu itself operates under `besurun`.**

#### Ownership and Permission Model

| Path | Owner | Group | Mode | Purpose |
|------|-------|-------|------|---------|
| `/etc/dakota` | `root` | `besurun` | `750` | Config directory — root controls, besurun traverses |
| `/etc/dakota/besu-current.env` | `root` | `besurun` | `640` | Active config — root edits, besurun reads |
| `/usr/local/lib/dakota/run-besu.sh` | `root` | `besurun` | `750` | Wrapper — root controls, besurun executes |
| `/var/lib/dakota/besu` | `besurun` | `besurun` | `750` | Runtime base — besurun owns |
| `/var/lib/dakota/besu/data` | `besurun` | `besurun` | `750` | Chain data — besurun writes |
| `/var/lib/dakota/besu/genesis.json` | `root` | `besurun` | `640` | Genesis — root controls, besurun reads |
| `/var/lib/dakota/besu/data/key` | `besurun` | `besurun` | `600` | Node private key — besurun only |

#### Permission Repair Commands

If the service fails with permission errors, run:

```bash
sudo chown root:besurun /etc/dakota
sudo chmod 750 /etc/dakota

sudo chown root:besurun /etc/dakota/besu-current.env
sudo chmod 640 /etc/dakota/besu-current.env

sudo chown root:besurun /usr/local/lib/dakota/run-besu.sh
sudo chmod 750 /usr/local/lib/dakota/run-besu.sh

sudo chown -R besurun:besurun /var/lib/dakota/besu
sudo find /var/lib/dakota/besu -type d -exec chmod 750 {} \;

sudo chown root:besurun /var/lib/dakota/besu/genesis.json
sudo chmod 640 /var/lib/dakota/besu/genesis.json

sudo restorecon -Rv /etc/dakota /usr/local/lib/dakota /var/lib/dakota/besu 2>/dev/null || true
```

#### Permission Validation Checklist

```bash
# Verify service runtime user
systemctl show -p User -p Group besu
# Expected: User=besurun  Group=besurun

# Verify directory ownership and modes
ls -ld /etc/dakota /usr/local/lib/dakota /var/lib/dakota/besu
ls -l /etc/dakota/besu-current.env /usr/local/lib/dakota/run-besu.sh
ls -l /var/lib/dakota/besu/genesis.json
ls -la /var/lib/dakota/besu/data/key /var/lib/dakota/besu/data/key.pub

# Verify service is starting correctly
systemctl status besu
journalctl -u besu --no-pager -n 30
```

#### Operational Rules

1. **Preserve the `besurun` runtime model.** Do not switch execution back to root.
2. **Preserve the env-driven design.** Do not replace the env file with scattered one-off shell edits.
3. **Preserve the wrapper-based launch flow.** Do not bypass the wrapper — it contains required validation and optional reset logic.
4. **The env file must be sourced, not executed.** The wrapper uses `source /etc/dakota/besu-current.env`. Attempting to execute the env file as a command causes permission and startup failures.
5. **Treat `/etc/dakota/besu-current.env` as part of the live service contract.** Any implementation or repair guidance must account for this file and its readability.

#### Network Security

- Ensure your firewall allows port `30303` (P2P) and `8545` (HTTP-RPC).
- Restrict `RPC_HTTP_API`, `HOST_ALLOWLIST`, and `RPC_HTTP_CORS_ORIGINS` in the env file for production — the defaults `*` / `all` are for initial setup only.
- Node private keys (`/var/lib/dakota/besu/data/key`) must be mode `600` and owned by `besurun`.
- If SELinux is enabled, verify contexts are valid after any file placement.

---

## 4. Layer 2 — Paladin / Pente Privacy Setup

[Paladin](https://github.com/LFDT-Paladin/paladin) is the recommended replacement for Tessera. It provides programmable privacy-preserving tokens on EVM, including ZKP tokens, notarized tokens, and private smart contracts (Pente privacy groups). Paladin connects to your Besu node via HTTP + WebSocket RPC. **Kubernetes is not required** — Paladin can run as a standalone Docker container.

> **Why Paladin?** Tessera has been officially sunset by the Besu maintainers. Paladin provides a modern, app-layer privacy solution that doesn't require modifications to the Besu client itself. See the [announcement](https://www.lfdecentralizedtrust.org/blog/sunsetting-tessera-and-simplifying-hyperledger-besu).

> **Prepackaged distributions:** Cryft Labs plans to provide prepackaged Paladin binaries and turnkey installation scripts for licensed parties once the system is established. Until then, use one of the installation methods below.

#### Prerequisites (all methods)

| Component | Required |
|-----------|----------|
| **Besu node** | Running with HTTP (`8545`) + WebSocket (`8546`) RPC enabled |
| **Docker** | Required for Docker method; optional for build-from-source |
| **Go 1.22+** | Required only for build-from-source |
| **PostgreSQL 15+** or **SQLite** | Paladin state store (Postgres recommended for production; SQLite for development) |

---

### 4.1 Method A — Docker (No Kubernetes Required)

This is the simplest approach. Run the Paladin container directly on any machine with Docker installed — no Kubernetes, Helm, or kubectl needed.

**Step 1 — Create a config file:**

```yaml
# paladin-config.yaml
log:
  level: info
db:
  type: sqlite                          # or "postgres" for production
  sqlite:
    dsn: /data/paladin.db
    autoMigrate: true
  # postgres:
  #   dsn: "postgres://paladin:password@localhost:5432/paladin?sslmode=disable"
  #   autoMigrate: true
blockchain:
  http:
    url: http://host.docker.internal:8545    # or <BESU_IP>:8545
  ws:
    url: ws://host.docker.internal:8546      # or <BESU_IP>:8546
signer:
  keyStore:
    type: static
    static:
      keys:
        signer1:
          encoding: hex
          inline: "<YOUR_PRIVATE_KEY_HEX>"   # operator signing key
publicTxManager:
  gasLimit:
    gasEstimateFactor: 2.0
```

> **Connecting to local Besu:** Use `host.docker.internal` (Docker Desktop on Mac/Windows) or your machine's LAN IP (Linux). On Linux without Docker Desktop, add `--add-host=host.docker.internal:host-gateway` to the docker run command.

**Step 2 — Create a data directory:**

```bash
mkdir -p ~/paladin-data
cp paladin-config.yaml ~/paladin-data/config.yaml
```

**Step 3 — Run Paladin:**

```bash
docker run -d \
  --name paladin \
  --restart unless-stopped \
  -p 8548:8548 \
  -p 8549:8549 \
  -p 9000:9000 \
  -v ~/paladin-data:/data \
  ghcr.io/lfdt-paladin/paladin:latest \
  paladin -c /data/config.yaml
```

**Step 4 — Verify:**

```bash
# Check the container is running
docker logs paladin --tail=30

# Test the JSON-RPC endpoint
curl -s http://localhost:8548/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"ptx_queryTransactions","params":[{}]}'
```

**Step 5 — Access the UI:**

Open `http://localhost:8548/ui` in your browser.

**Managing the container:**

```bash
docker stop paladin          # stop
docker start paladin         # restart
docker logs -f paladin       # follow logs
docker rm -f paladin         # remove (data persists in ~/paladin-data)
```

**Using Postgres instead of SQLite (recommended for production):**

```bash
# Start Postgres alongside Paladin
docker run -d --name paladin-db \
  -e POSTGRES_USER=paladin \
  -e POSTGRES_PASSWORD=paladin \
  -e POSTGRES_DB=paladin \
  -p 5432:5432 \
  postgres:15

# Update paladin-config.yaml to use postgres:
#   db:
#     type: postgres
#     postgres:
#       dsn: "postgres://paladin:paladin@host.docker.internal:5432/paladin?sslmode=disable"
#       autoMigrate: true
```

---

### 4.2 Method B — Build from Source

For developers, air-gapped environments, or custom builds. Paladin is a Go project (85% Go) with Gradle orchestrating the full build.

**Prerequisites:**
- Go 1.22+ (`go version`)
- JDK 17+ (`java -version`)
- Node.js 18+ (`node --version`)
- Protoc (`protoc --version`) — [install](https://grpc.io/docs/protoc-installation/)
- Docker (for building domain plugins)
- PostgreSQL or SQLite

**Build:**

```bash
git clone https://github.com/LFDT-Paladin/paladin.git
cd paladin
./gradlew build
```

This produces the `paladin` binary and domain plugin shared libraries (`.so` files for Noto, Pente, Zeto).

**Run:**

```bash
# Create config (same format as Method A, but with local file paths for domain plugins)
./paladin -c /path/to/paladin-config.yaml
```

> See the [Paladin configuration reference](https://lfdt-paladin.github.io/paladin/head/administration/configuration/) for the full set of config options.

---

### 4.3 Method C — k3s + Helm (Kubernetes Operator)

For multi-node production deployments, the Kubernetes operator provides managed lifecycle, auto-scaling, and declarative configuration. k3s is a lightweight single-binary Kubernetes distribution — it adds minimal overhead on a single server.

**Step 1 — Install k3s + Helm:**
```bash
curl -sfL https://get.k3s.io | sh -
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
kubectl get nodes
```

For local development, [kind](https://kind.sigs.k8s.io/) is an alternative:
```bash
curl https://raw.githubusercontent.com/LFDT-Paladin/paladin/refs/heads/main/operator/paladin-kind.yaml -L -O
kind create cluster --name paladin --config paladin-kind.yaml
```

**Step 2 — Install Paladin Operator CRDs:**

```bash
helm repo add paladin https://LFDT-Paladin.github.io/paladin --force-update
helm upgrade --install paladin-crds paladin/paladin-operator-crd
```

**Step 3 — Install cert-manager:**

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager --namespace cert-manager --version v1.16.1 \
  jetstack/cert-manager --create-namespace --set crds.enabled=true
```

**Step 4 — Deploy Paladin (single node, attached to Besu):**

Create a values file:

```yaml
# values-dakota.yaml
mode: customnet
paladinNodes:
  - name: dakota-node1
    baseLedgerEndpoint:
      type: endpoint
      endpoint:
        # --- Local Besu (same machine) ---
        jsonrpc: http://host.docker.internal:8545
        ws: ws://host.docker.internal:8546
        # --- OR Remote Besu ---
        # jsonrpc: http://<BESU_NODE_IP>:8545
        # ws: ws://<BESU_NODE_IP>:8546
        auth:
          enabled: false
    domains:
      - noto
      - zeto
      - pente
    registries:
      - evm-registry
    transports:
      - name: grpc
        plugin:
          type: c-shared
          library: /app/transports/libgrpc.so
        config:
          port: 9000
          address: 0.0.0.0
        ports:
          transportGrpc:
            port: 9000
            targetPort: 9000
    service:
      type: NodePort
      ports:
        rpcHttp:
          port: 8548
          nodePort: 31548
        rpcWs:
          port: 8549
          nodePort: 31549
    database:
      mode: sidecarPostgres
      migrationMode: auto
    secretBackedSigners:
      - name: signer-auto-wallet
        secret: dakota-node1.keys
        type: autoHDWallet
        keySelector: ".*"
    paladinRegistration:
      registryAdminNode: dakota-node1
      registryAdminKey: registry.operator
      registry: evm-registry
    config: |
      log:
        level: info
      publicTxManager:
        gasLimit:
          gasEstimateFactor: 2.0
```

> **Connecting to local Besu:** Use the machine's actual IP for k3s (not `localhost`). For kind, use `host.docker.internal`.
>
> **Connecting to remote Besu:** Replace with the remote node's IP/hostname. Ensure ports `8545` and `8546` are reachable from the Kubernetes pod network.

Deploy:
```bash
helm install paladin paladin/paladin-operator -n paladin --create-namespace \
  -f values-dakota.yaml
```

**Step 5 — Verify:**

```bash
kubectl -n paladin get pods             # Paladin pod + Postgres sidecar should be Running
kubectl -n paladin get scd              # Smart contract deployments (noto, pente, zeto factories)
kubectl -n paladin get reg              # Node registration status
kubectl -n paladin logs deploy/dakota-node1 --tail=50
```

**Adding Paladin nodes on other machines:**

Use `attach` mode with the contract addresses from the primary node:

```bash
kubectl -n paladin get paladindomains,paladinregistries
```

Then on the new machine, create a values file with `mode: attach` and the contract addresses:

```yaml
# values-attach.yaml
mode: attach
smartContractsReferences:
  notoFactory:
    address: "0x..."    # from primary node output
  zetoFactory:
    address: "0x..."
  penteFactory:
    address: "0x..."
  registry:
    address: "0x..."
paladinNodes:
  - name: dakota-node2
    baseLedgerEndpoint:
      type: endpoint
      endpoint:
        jsonrpc: http://<BESU_NODE_IP>:8545
        ws: ws://<BESU_NODE_IP>:8546
        auth:
          enabled: false
    domains: [noto, zeto, pente]
    registries: [evm-registry]
    transports:
      - name: grpc
        plugin:
          type: c-shared
          library: /app/transports/libgrpc.so
        config:
          port: 9000
          address: 0.0.0.0
        ports:
          transportGrpc:
            port: 9000
            targetPort: 9000
    service:
      type: NodePort
      ports:
        rpcHttp:
          port: 8548
          nodePort: 31548
        rpcWs:
          port: 8549
          nodePort: 31549
    database:
      mode: sidecarPostgres
      migrationMode: auto
    secretBackedSigners:
      - name: signer-auto-wallet
        secret: dakota-node2.keys
        type: autoHDWallet
        keySelector: ".*"
    paladinRegistration:
      registryAdminNode: dakota-node1
      registryAdminKey: registry.operator
      registry: evm-registry
    config: |
      log:
        level: info
```

```bash
helm install paladin paladin/paladin-operator -n paladin --create-namespace \
  -f values-attach.yaml
```

**Uninstall:**

```bash
helm uninstall paladin -n paladin
helm uninstall paladin-crds
kubectl delete namespace paladin
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager
```

---

### 4.4 Paladin Privacy Domains

| Domain | Description |
|--------|-------------|
| **Noto** | Notarized tokens — issuer-backed private token transfers |
| **Zeto** | ZKP tokens — zero-knowledge proof backed private transfers |
| **Pente** | Private EVM smart contracts — privacy groups with private state |

### 4.5 Paladin UI

The Paladin node runs a web UI at `/ui`:
- **Docker:** `http://localhost:8548/ui`
- **k3s:** `http://<MACHINE_IP>:31548/ui`
- **kind:** `http://localhost:31548/ui`

### 4.6 Paladin Resources

- **Documentation:** <https://lfdt-paladin.github.io/paladin/head>
- **GitHub:** <https://github.com/LFDT-Paladin/paladin>
- **Latest release:** v0.15.0
- **Configuration reference:** <https://lfdt-paladin.github.io/paladin/head/administration/configuration/>
- **Tutorials:** <https://lfdt-paladin.github.io/paladin/head/tutorials/>
- **Advanced installation (Helm):** <https://lfdt-paladin.github.io/paladin/head/getting-started/installation-advanced/>
- **Manual installation (Helm CRDs):** <https://lfdt-paladin.github.io/paladin/head/getting-started/installation-manual/>
- **Docker image:** `ghcr.io/lfdt-paladin/paladin:latest`
- **Discord:** [paladin channel on LFDT Discord](https://discord.com/channels/905194001349627914/1303371167020879903)
- **Tessera sunset announcement:** <https://www.lfdecentralizedtrust.org/blog/sunsetting-tessera-and-simplifying-hyperledger-besu>

### 4.7 Create a Pente Privacy Group

Use the Paladin JSON-RPC API to create a privacy group for code storage:

```bash
# Docker: use port 8548
# Kubernetes: use port 31548
curl -X POST http://localhost:8548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_createPrivacyGroup",
    "params": [{
      "name": "code-storage-group",
      "members": ["dakota-node1"],
      "evmVersion": "shanghai",
      "endorsementType": "group_scoped_identities",
      "externalCallsEnabled": true
    }]
  }'
```

> **`externalCallsEnabled: true`** is critical — this allows PrivateComboStorage to emit `PenteExternalCall` events that route to CodeManager on the public chain.

The response contains a `privacyGroupAddress` — record this for PrivateComboStorage deployment.

### 4.8 Authorize the Privacy Group on CodeManager

After creating the privacy group, the CodeManager voters must authorize it:

```javascript
// Each voter calls voteToAuthorizePrivacyGroup
// Requires 2/3 supermajority to pass
await codeManager.voteToAuthorizePrivacyGroup(privacyGroupAddress);
```

Once the supermajority is reached, `isAuthorizedPrivacyGroup[privacyGroupAddress]` becomes `true`, allowing PrivateComboStorage's `PenteExternalCall` events to be accepted by CodeManager's router functions.

### 4.9 Documentation & References

#### Besu

Besu documentation has moved to a self-hosted versioned model.

- **Versioned documentation index:** <https://lf-hyperledger.atlassian.net/wiki/spaces/BESU/pages/22156555/Versioned+documentation>
- **Besu GitHub releases:** <https://github.com/hyperledger/besu/releases/tag/26.1.0>
- **Besu 26.1.0 release notes:** <https://github.com/hyperledger/besu/releases/tag/26.1.0>

#### Paladin (Privacy Manager)

Paladin replaces Tessera as the recommended privacy solution for Besu networks.

- **Paladin docs:** <https://lfdt-paladin.github.io/paladin/head>
- **Paladin GitHub:** <https://github.com/LFDT-Paladin/paladin>
- **Docker image:** `ghcr.io/lfdt-paladin/paladin:latest`
- **Configuration reference:** <https://lfdt-paladin.github.io/paladin/head/administration/configuration/>
- **Installation guide (Helm):** <https://lfdt-paladin.github.io/paladin/head/getting-started/installation>
- **Advanced installation (Helm):** <https://lfdt-paladin.github.io/paladin/head/getting-started/installation-advanced/>
- **Tessera sunset announcement:** <https://www.lfdecentralizedtrust.org/blog/sunsetting-tessera-and-simplifying-hyperledger-besu>

---

## 5. Layer 3 — Contract Deployment

### 5.1 Compilation

Use the included compiler tool:

```bash
python Tools/SolcCompiler/compile.py
```

This auto-detects pragma versions, resolves imports (vendored OZ 4.9.6 for Genesis contracts, GitHub download for others), and outputs ABI + bytecode to `Tools/SolcCompiler/compiled_output/`. The default EVM target is `osaka`; validator contracts (pragma `<0.8.20`) are automatically clamped to `london`.

### 5.2 Deployment Order

Contracts must be deployed in this order due to address dependencies:

| Step | Contract | Network | Upgradeable | Notes |
|------|----------|---------|-------------|-------|
| 1 | **ProxyAdmin** | Public | No | Guardian-gated upgrade dispatch |
| 2 | **CodeManager** | Public | Yes (TransparentUpgradeableProxy) | Set `registrationFee`, `feeVault`, initial voters |
| 3 | **Gift Contract** | Public | Yes (recommended) | Implements `IRedeemable` — your ERC-721, ERC-1155, or custom contract |
| 4 | Create **Pente Privacy Group** | Paladin | — | `externalCallsEnabled: true` |
| 5 | Authorize privacy group | Public | — | `voteToAuthorizePrivacyGroup()` (2/3 supermajority) |
| 6 | **PrivateComboStorage** | Pente | No | Set `codeManager` address before deployment |
| 7 | **DakotaDelegation** | Public | Yes | EIP-7702 delegation target |
| 8 | **GasSponsor** | Public | Yes | Gas sponsorship treasury |
| 9 | **ERC-6551 Registry** | Public | No | Canonical address or deploy via CREATE2 |
| 10 | **ERC-6551 Account Impl** | Public | No | Smart account logic for TBAs |
| 11 | **ERC-1155 Traits** | Public | Optional | Multi-token trait collection |

### 5.3 CodeManager Initialization

After proxy deployment:

```javascript
// Initialize (called once via proxy)
await codeManager.initialize();

// Configure governance
await codeManager.voteToUpdateRegistrationFee(ethers.parseEther("0.001"));
await codeManager.voteToUpdateFeeVault(feeVaultAddress);
```

### 5.4 PrivateComboStorage Deployment

Before compiling PrivateComboStorage, update the `codeManager` constant to match your deployed CodeManager proxy address:

```solidity
// In PrivateComboStorage.sol — update before deployment
address public constant codeManager = address(0x000000000000000000000000000000000000c0DE);
```

Deploy into the Pente privacy group via Paladin:

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_deploy",
    "params": [{
      "privacyGroupAddress": "<PRIVACY_GROUP_ADDRESS>",
      "from": "dakota-node1",
      "bytecode": "<PRIVATE_COMBO_STORAGE_BYTECODE>",
      "abi": <PRIVATE_COMBO_STORAGE_ABI>
    }]
  }'
```

---

## 6. Standardized Interfaces for Gift Contracts

Gift contracts **must** implement the `IRedeemable` interface. This is the standardized contract boundary through which CodeManager routes all per-UID state management.

### 6.1 IRedeemable — Required Interface

Every gift contract deployed on the public chain must implement these 6 functions:

```solidity
interface IRedeemable {
    // ── Read Functions ──────────────────────────────────

    /// @notice Returns true if the unique ID is currently frozen.
    function isUniqueIdFrozen(string memory uniqueId) external view returns (bool);

    /// @notice Returns true if the unique ID has already been redeemed.
    function isUniqueIdRedeemed(string memory uniqueId) external view returns (bool);

    /// @notice Returns the content identifier associated with a unique ID.
    function getUniqueIdContent(string memory uniqueId) external view returns (string memory);

    // ── Management Functions (called by CodeManager) ────

    /// @notice Set frozen status for a unique ID.
    function setFrozen(string memory uniqueId, bool frozen) external;

    /// @notice Set the redeemable content for a unique ID.
    function setContent(string memory uniqueId, string memory contentId) external;

    /// @notice Record a redemption for a unique ID.
    function recordRedemption(string memory uniqueId, address redeemer) external;
}
```

### 6.2 Interface Behavior Requirements

| Function | Behavior Requirement |
|----------|---------------------|
| `isUniqueIdFrozen` | **Must return `true` for any UID that has not been explicitly unfrozen.** This ensures codes default to a frozen/non-redeemable state upon registration. |
| `isUniqueIdRedeemed` | Return whether the UID has been consumed. Semantics are contract-specific (e.g., "NFT left the vault", "counter > 0", "boolean flag"). |
| `getUniqueIdContent` | Return the content identifier (IPFS CID, URL, token ID, etc.) associated with the UID. May return empty string if content is managed at batch level. |
| `setFrozen` | **Must restrict caller to CodeManager only** (`require(msg.sender == codeManagerAddress)`). Freeze/unfreeze the UID. |
| `setContent` | **Must restrict caller to CodeManager only.** Update the content association. May be a no-op if content is batch-managed. |
| `recordRedemption` | **Must restrict caller to CodeManager only.** Execute the redemption action (transfer NFT, increment counter, mint token, etc.). **Must revert** if the redemption is not allowed — this causes the entire Pente transition to roll back atomically. |

### 6.3 ICodeManager — Registry Interface

Used by gift contracts to register UIDs and query registration data:

```solidity
interface ICodeManager {
    struct ContractData {
        address giftContract;
        string chainId;
    }

    function getUniqueIdDetails(string memory uniqueId)
        external view returns (address giftContract, string memory chainId, uint256 counter);

    function validateUniqueId(string memory uniqueId) external view returns (bool isValid);

    function getContractData(string memory contractIdentifier)
        external view returns (ContractData memory);

    function getIdentifierCounter(address giftContract, string memory chainId)
        external view returns (string memory contractIdentifier, uint256 counter);

    function isWhitelistedAddress(address addr) external view returns (bool);

    function registrationFee() external view returns (uint256);

    function registerUniqueIds(
        address giftContract, string memory chainId, uint256 quantity
    ) external payable;
}
```

### 6.4 IComboStorage — Private Storage Interface

The interface for the private contract running inside the Pente privacy group:

```solidity
interface IComboStorage {
    function isRedemptionVerified(string memory uniqueId) external view returns (bool);
    function redemptionRedeemer(string memory uniqueId) external view returns (address);
    function isFrozen(string memory uniqueId) external view returns (bool);
    function isRedeemed(string memory uniqueId) external view returns (bool);
    function getContentId(string memory uniqueId) external view returns (string memory);
}
```

---

## 7. Implementing a Custom Gift Contract

Licensees can implement custom gift contracts using the provided ERC-721, ERC-6551, and ERC-1155 patterns. The gift contract is where licensees have the most creative freedom — the interface is standardized, but the internal logic is entirely up to you.

### 7.1 ERC-721 Gift Contract (NFT Transfer on Redemption)

This is the pattern used by `CryftGreetingCards`. The contract holds NFTs in a "vault" (itself). Redemption transfers the NFT to the redeemer.

```solidity
contract MyGiftCards is ERC721Upgradeable, IRedeemable {
    address public codeManagerAddress;
    mapping(uint256 => bool) private _frozen;

    // Required: restrict management calls to CodeManager
    modifier onlyCodeManager() {
        require(msg.sender == codeManagerAddress, "Only CodeManager");
        _;
    }

    // ── IRedeemable Read Functions ──────────────────────

    function isUniqueIdFrozen(string memory uniqueId) public view override returns (bool) {
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        if (!valid || !_exists(tokenId)) return true;  // default frozen
        return _frozen[tokenId];
    }

    function isUniqueIdRedeemed(string memory uniqueId) public view override returns (bool) {
        (bool valid, uint256 tokenId) = _parseTokenId(uniqueId);
        if (!valid || !_exists(tokenId)) return false;
        return ownerOf(tokenId) != address(this);  // redeemed = left the vault
    }

    function getUniqueIdContent(string memory) public pure override returns (string memory) {
        return "";  // content managed via tokenURI / batch metadata
    }

    // ── IRedeemable Management Functions ────────────────

    function setFrozen(string memory uniqueId, bool frozen) external override onlyCodeManager {
        (, uint256 tokenId) = _parseTokenId(uniqueId);
        _frozen[tokenId] = frozen;
    }

    function setContent(string memory, string memory) external view override onlyCodeManager {
        // No-op: content is batch-level IPFS metadata
    }

    function recordRedemption(string memory uniqueId, address redeemer) external override onlyCodeManager {
        (, uint256 tokenId) = _parseTokenId(uniqueId);
        require(ownerOf(tokenId) == address(this), "Not in vault");
        require(!_frozen[tokenId], "Token is frozen");
        _transfer(address(this), redeemer, tokenId);
    }
}
```

### 7.2 ERC-1155 Gift Contract (Multi-Token Redemption)

For codes that award fungible or semi-fungible tokens (trait tokens, consumables, currency bundles):

```solidity
contract TraitRedemption is ERC1155Upgradeable, IRedeemable {
    address public codeManagerAddress;
    mapping(string => bool) private _frozen;
    mapping(string => bool) private _redeemed;
    mapping(string => string) private _contentId;
    mapping(string => uint256) private _traitId;        // UID → ERC-1155 token ID
    mapping(string => uint256) private _traitAmount;     // UID → quantity

    modifier onlyCodeManager() {
        require(msg.sender == codeManagerAddress, "Only CodeManager");
        _;
    }

    function isUniqueIdFrozen(string memory uid) public view override returns (bool) {
        return _frozen[uid];  // defaults to false; set true on registration
    }

    function isUniqueIdRedeemed(string memory uid) public view override returns (bool) {
        return _redeemed[uid];
    }

    function getUniqueIdContent(string memory uid) public view override returns (string memory) {
        return _contentId[uid];
    }

    function setFrozen(string memory uid, bool frozen) external override onlyCodeManager {
        _frozen[uid] = frozen;
    }

    function setContent(string memory uid, string memory contentId) external override onlyCodeManager {
        _contentId[uid] = contentId;
    }

    function recordRedemption(string memory uid, address redeemer) external override onlyCodeManager {
        require(!_redeemed[uid], "Already redeemed");
        require(!_frozen[uid], "Frozen");
        _redeemed[uid] = true;
        _mint(redeemer, _traitId[uid], _traitAmount[uid], "");
    }
}
```

### 7.3 ERC-6551 TBA Gift Contract (Redeem Traits into NFT's Account)

For codes that award ERC-1155 traits directly into an ERC-721 token's Token Bound Account:

```solidity
contract TBATraitRedemption is IRedeemable {
    IERC1155 public traitContract;
    IERC6551Registry public registry;
    address public accountImplementation;
    address public codeManagerAddress;

    mapping(string => bool) private _frozen;
    mapping(string => bool) private _redeemed;
    mapping(string => uint256) private _traitId;
    mapping(string => uint256) private _targetTokenId;  // UID → parent NFT tokenId

    function recordRedemption(string memory uid, address) external override {
        require(msg.sender == codeManagerAddress, "Only CodeManager");
        require(!_redeemed[uid] && !_frozen[uid], "Cannot redeem");
        _redeemed[uid] = true;

        // Compute the TBA address for the parent NFT
        address tba = registry.account(
            accountImplementation, bytes32(0), block.chainid,
            address(this), _targetTokenId[uid]
        );

        // Mint trait directly into the TBA
        traitContract.mint(tba, _traitId[uid], 1, "");
    }

    // ... remaining IRedeemable functions ...
}
```

---

## 8. Bulk Code Storage via Pente

### 8.1 Off-Chain Code Generation

Codes are generated off-chain and never stored in cleartext on any chain:

```
For each code:
  1. Generate random code string (e.g., "FIRE-SWORD-2026-X7K9")
  2. Extract PIN prefix (e.g., first 4 chars: "FIRE")
  3. Compute giftCode = PIN + code = "FIRE" + "FIRE-SWORD-2026-X7K9"
  4. Compute codeHash = keccak256(giftCode)
  5. Store: { uniqueId, pin: "FIRE", codeHash }
```

### 8.2 Register UIDs on CodeManager

Before storing codes in the privacy group, register the UID range on CodeManager:

```javascript
// Register 1000 UIDs for your gift contract
const quantity = 1000;
const fee = await codeManager.registrationFee();
const totalFee = fee * BigInt(quantity);

await codeManager.registerUniqueIds(
    giftContractAddress,
    "112311",            // chainId
    quantity,
    { value: totalFee }
);
```

This creates deterministic UIDs in the format `<contractIdentifier>-<counter>` where:
```
contractIdentifier = toHexString(keccak256(codeManagerAddress, giftContractAddress, chainId))
```

### 8.3 Batch Store in PrivateComboStorage

Store the hashed codes into the Pente privacy group:

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_invoke",
    "params": [{
      "privacyGroupAddress": "<PRIVACY_GROUP_ADDRESS>",
      "from": "dakota-node1",
      "to": "<PRIVATE_COMBO_STORAGE_ADDRESS>",
      "function": "storeDataBatch(string[],string[],bytes32[])",
      "inputs": [
        ["uid-1", "uid-2", "uid-3"],
        ["FIRE", "ICE9", "GOLD"],
        ["0xabc123...", "0xdef456...", "0x789012..."]
      ]
    }]
  }'
```

Key behaviors:
- All stored codes **default to `frozen=true`** — they cannot be redeemed until explicitly unfrozen
- Duplicate hashes, full PIN slots (max 32 per PIN), and invalid UIDs are skipped with `status=false`
- The transaction always succeeds — partial storage is allowed
- Maximum 32 hashes per PIN bucket (configurable via `MAX_PER_PIN`)

### 8.4 Unfreeze Codes for Redemption

After storing, unfreeze the codes you want to make redeemable:

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_invoke",
    "params": [{
      "privacyGroupAddress": "<PRIVACY_GROUP_ADDRESS>",
      "from": "dakota-node1",
      "to": "<PRIVATE_COMBO_STORAGE_ADDRESS>",
      "function": "setFrozen(string,bool)",
      "inputs": ["uid-1", false]
    }]
  }'
```

This emits a `PenteExternalCall` that atomically calls `CodeManager.setUidFrozen(uid, false)`, which forwards to `giftContract.setFrozen(uid, false)`.

---

## 9. Redemption Flow (End to End)

### 9.1 Complete Data Flow

```
User enters PIN + code in web app
         │
         ▼
Web app computes codeHash = keccak256(pin + code)
         │
         ▼
Web app calls backend API with { pin, codeHash }
         │
         ▼
Backend calls Paladin RPC → PrivateComboStorage.redeemCode(pin, codeHash)
         │
         ▼
PrivateComboStorage (inside Pente privacy group):
  1. Looks up pinToHash[pin][codeHash] → finds CodeMetadata
  2. Checks: exists? not frozen? not redeemed?
  3. Updates private state: redeemed = true
  4. Deletes hash entry, decrements PIN slot count
  5. Emits PenteExternalCall(codeManager, abi.encode("recordRedemption(uid, redeemer)"))
         │
         ▼
Pente endorsement: privacy group members endorse the transition
         │
         ▼
Paladin submits PenteExternalCall to public chain
         │
         ▼
CodeManager.recordRedemption(uniqueId, redeemer):
  1. Requires msg.sender is authorized privacy group
  2. Resolves UID → gift contract via getUniqueIdDetails()
  3. Calls giftContract.recordRedemption(uniqueId, redeemer)
  4. Emits RedemptionRouted event
         │
         ▼
Gift Contract.recordRedemption(uniqueId, redeemer):
  • ERC-721: transfers NFT from vault to redeemer
  • ERC-1155: mints tokens to redeemer
  • Custom: whatever the licensee implements
  • If not allowed → REVERTS → entire Pente transition rolls back
         │
         ▼
Transaction confirmed. User receives their redeemed content.
```

### 9.2 Redemption Code (Backend)

```javascript
async function redeemCode(pin, code, redeemerAddress) {
    // Compute hash off-chain — no cleartext on-chain
    const giftCode = pin + code;
    const codeHash = ethers.keccak256(ethers.toUtf8Bytes(giftCode));

    // Call PrivateComboStorage via Paladin RPC
    const result = await fetch("http://localhost:31548/rpc", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "pente_invoke",
            params: [{
                privacyGroupAddress: PRIVACY_GROUP_ADDRESS,
                from: "dakota-node1",
                to: PRIVATE_COMBO_STORAGE_ADDRESS,
                function: "redeemCode(string,bytes32)",
                inputs: [pin, codeHash]
            }]
        })
    });

    return await result.json();
}
```

---

## 10. Web Application Integration (thirdweb + Paladin API)

### 10.1 Architecture

```
┌─────────────────────┐     ┌─────────────────────┐     ┌──────────────────────┐
│   Frontend          │     │   Backend (Node.js)  │     │   Infrastructure     │
│   React + thirdweb  │────▶│                      │────▶│                      │
│                     │     │ • thirdweb server     │     │ • Besu (8545/8546)   │
│ • User auth         │     │   wallet             │     │ • Paladin (31548)    │
│ • Code entry UI     │     │ • Paladin RPC client │     │ • Blockscout         │
│ • NFT gallery       │     │ • Code generation    │     │                      │
│ • TBA explorer      │     │ • Redemption flow    │     │ CodeManager (c0DE)   │
│ • Trait viewer      │     │ • Admin operations   │     │ Gift Contract        │
│                     │     │                      │     │ PrivateComboStorage  │
│ defineChain(112311) │     │ x-secret-key auth    │     │ DakotaDelegation     │
└─────────────────────┘     └─────────────────────┘     └──────────────────────┘
```

### 10.2 Frontend — Define Custom Chain

```typescript
import { defineChain } from "thirdweb";

const dakotaChain = defineChain({
    id: 112311,
    rpc: "https://your-rpc-endpoint:8545",
    nativeCurrency: { name: "Cryft", symbol: "CRYFT", decimals: 18 },
    blockExplorers: [{ name: "Blockscout", url: "https://your-blockscout.com" }],
});
```

### 10.3 Frontend — User Authentication

thirdweb in-app wallets provide embedded EOA wallets with social/email auth:

```typescript
import { ThirdwebProvider, ConnectWallet } from "@thirdweb-dev/react";

function App() {
    return (
        <ThirdwebProvider clientId="<your-client-id>" activeChain={dakotaChain}>
            <ConnectWallet />
        </ThirdwebProvider>
    );
}
```

Supported auth methods: email OTP, phone OTP, Google, Apple, Discord, passkeys, SIWE, guest wallets, custom JWT.

### 10.4 Backend — Contract Writes via thirdweb API

All public-chain writes can go through the thirdweb API. EIP-7702 is the default execution mode — gas is sponsored automatically:

```javascript
// Write to any contract on chain 112311
const response = await fetch("https://api.thirdweb.com/v1/contracts/write", {
    method: "POST",
    headers: {
        "x-secret-key": process.env.THIRDWEB_SECRET_KEY,
        "Content-Type": "application/json",
    },
    body: JSON.stringify({
        calls: [{
            contractAddress: "<contract-address>",
            method: "function methodName(uint256 param1, address param2)",
            params: [42, "0x..."],
        }],
        chainId: 112311,
        from: "<wallet-address>",
    }),
});
```

### 10.5 Backend — Paladin RPC for Private Operations

Private operations (code storage, redemption verification) go through the Paladin JSON-RPC API:

```javascript
async function paladinInvoke(contractAddress, functionSig, inputs) {
    const response = await fetch("http://localhost:31548/rpc", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            jsonrpc: "2.0",
            id: Date.now(),
            method: "pente_invoke",
            params: [{
                privacyGroupAddress: PRIVACY_GROUP_ADDRESS,
                from: "dakota-node1",
                to: contractAddress,
                function: functionSig,
                inputs: inputs,
            }],
        }),
    });
    return await response.json();
}

// Store codes (private)
await paladinInvoke(COMBO_STORAGE, "storeDataBatch(string[],string[],bytes32[])", [uids, pins, hashes]);

// Unfreeze codes (private → triggers public via PenteExternalCall)
await paladinInvoke(COMBO_STORAGE, "setFrozen(string,bool)", [uid, false]);

// Redeem code (private → triggers public via PenteExternalCall)
await paladinInvoke(COMBO_STORAGE, "redeemCode(string,bytes32)", [pin, codeHash]);
```

### 10.6 Backend — Query Public State

Public state can be queried via thirdweb SDK or direct Besu RPC:

```javascript
// Check if a UID is frozen (reads from gift contract via CodeManager pass-through)
const frozen = await codeManager.isUniqueIdFrozen(uniqueId);

// Check if redeemed
const redeemed = await codeManager.isUniqueIdRedeemed(uniqueId);

// Get content
const content = await codeManager.getUniqueIdContent(uniqueId);

// Validate a UID
const valid = await codeManager.validateUniqueId(uniqueId);

// Get UID details
const { giftContract, chainId, counter } = await codeManager.getUniqueIdDetails(uniqueId);
```

### 10.7 Full Redemption API Endpoint

```javascript
// POST /api/redeem
export async function POST(req) {
    const { pin, code, userWallet } = await req.json();

    // 1. Compute hash off-chain
    const codeHash = ethers.keccak256(ethers.toUtf8Bytes(pin + code));

    // 2. Redeem via Pente (private verification + public state update)
    const paladinResult = await paladinInvoke(
        COMBO_STORAGE,
        "redeemCode(string,bytes32)",
        [pin, codeHash]
    );

    if (paladinResult.error) {
        return Response.json({ error: paladinResult.error.message }, { status: 400 });
    }

    // 3. The PenteExternalCall atomically:
    //    - calls CodeManager.recordRedemption(uid, redeemer)
    //    - which calls giftContract.recordRedemption(uid, redeemer)
    //    - gift contract executes the redemption action

    return Response.json({
        success: true,
        transactionId: paladinResult.result,
    });
}
```

---

## 11. ERC-721 / ERC-6551 / ERC-1155 Token Patterns

The repository includes production contracts that licensees can use or extend:

### 11.1 Provided Contracts

| Contract | Standard | Source | Purpose |
|----------|----------|--------|---------|
| **CryftGreetingCards** | ERC-721 | `Contracts/Tokens/GreetingCards.sol` | NFT gift cards with vault pattern — implements `IRedeemable` |
| **DakotaDelegation** | EIP-7702 | `Contracts/Genesis/7702/DakotaDelegation.sol` | Delegation target for EOA smart features |
| **GasSponsor** | — | `Contracts/Genesis/7702/GasSponsor.sol` | Gas sponsorship treasury |

Licensees should deploy their own ERC-6551 and ERC-1155 contracts using standard implementations (OpenZeppelin, thirdweb, etc.) or use thirdweb's deployment tooling.

### 11.2 ERC-6551 Token Bound Accounts

Each ERC-721 NFT gets its own smart contract wallet (TBA) via ERC-6551. When the NFT is sold or transferred, the TBA and all its contents travel with it.

**Canonical ERC-6551 Registry:** `0x000000006551c19487814612e58FE06813775758`

```typescript
// Create a TBA for NFT #42
const tx = await registry.createAccount(
    accountImplementation,    // your deployed account impl
    "0x" + "00".repeat(32),   // salt
    112311n,                  // chainId
    nftCollectionAddress,     // ERC-721 contract
    42n                       // tokenId
);

// Compute TBA address (deterministic — same every time)
const tbaAddress = await registry.account(
    accountImplementation, "0x" + "00".repeat(32), 112311n, nftCollectionAddress, 42n
);
```

### 11.3 ERC-1155 Trait Tokens

Multi-token traits (hats, weapons, skins, attributes, abilities) are minted into TBAs:

```javascript
// Mint trait token #7 (Gold Helmet) into NFT #42's TBA
await traitContract.mint(tbaAddress, 7, 1, "0x");

// Read TBA contents
const balance = await traitContract.balanceOf(tbaAddress, 7);
// balance = 1n
```

### 11.4 Combined Flow: Code Redemption → NFT → TBA → Traits

```
1. User purchases NFT from gift contract (ERC-721)
   → UIDs registered on CodeManager
   → Codes stored in PrivateComboStorage

2. User creates TBA for their NFT (ERC-6551)
   → TBA address is deterministic

3. User redeems code
   → PrivateComboStorage verifies
   → PenteExternalCall → CodeManager → gift contract
   → Gift contract mints ERC-1155 trait into user's TBA

4. User sells NFT on marketplace
   → TBA and all traits transfer automatically with the NFT
```

### 11.5 Batch Transactions via EIP-7702

EIP-7702 natively supports batching multiple calls in one transaction. This enables atomic operations like "redeem code + mint trait into TBA" in one transaction:

```javascript
const response = await fetch("https://api.thirdweb.com/v1/contracts/write", {
    method: "POST",
    headers: {
        "x-secret-key": process.env.THIRDWEB_SECRET_KEY,
        "Content-Type": "application/json",
    },
    body: JSON.stringify({
        calls: [
            {
                contractAddress: ERC1155_TRAITS_ADDRESS,
                method: "function mint(address to, uint256 id, uint256 amount, bytes data)",
                params: [tbaAddress, 7, 1, "0x"],
            },
            {
                contractAddress: ERC1155_TRAITS_ADDRESS,
                method: "function mint(address to, uint256 id, uint256 amount, bytes data)",
                params: [tbaAddress, 12, 3, "0x"],
            },
        ],
        chainId: 112311,
        from: userWalletAddress,
    }),
});
```

---

## 12. Gas Sponsorship

### 12.1 thirdweb Hosted Sponsorship

Every `POST /v1/contracts/write` call is automatically gas-sponsored by your thirdweb project. Configure policies in the thirdweb dashboard:

- Global spend limits (daily/monthly caps)
- Chain restrictions (only chain 112311)
- Contract restrictions (only your deployed contracts)
- Wallet allowlists/blocklists

### 12.2 Self-Hosted Sponsorship (GasSponsor Contract)

For independent gas sponsorship without thirdweb dependency:

```javascript
// Deposit CRYFT as a sponsor
await gasSponsor.deposit({ value: ethers.parseEther("100") });

// Authorize a relayer to claim gas reimbursement
await gasSponsor.authorizeRelayer(relayerAddress);

// Set limits
await gasSponsor.setMaxClaimPerTx(ethers.parseEther("0.01"));
await gasSponsor.setDailyLimit(ethers.parseEther("10"));

// Restrict to specific contracts
await gasSponsor.addAllowedTarget(codeManagerAddress);
await gasSponsor.addAllowedTarget(giftContractAddress);
```

GasSponsor is deployed at `0x...FEeD` and is upgradeable via TransparentUpgradeableProxy.

---

## 13. Deployment Checklist

### Infrastructure
- [ ] Besu 26.1.0 installed with all forks through Osaka enabled from genesis
- [ ] All validator/RPC nodes running and synced
- [ ] Paladin deployed (Docker or Kubernetes — see Section 4)
- [ ] Pente privacy group created with `externalCallsEnabled: true`
- [ ] Blockscout self-hosted and indexing chain 112311
- [ ] RPC endpoints accessible to backend / thirdweb

### thirdweb
- [ ] Project created with API keys (`x-client-id`, `x-secret-key`)
- [ ] Custom chain defined (`defineChain({ id: 112311, ... })`)
- [ ] Gas sponsorship policies configured
- [ ] Server wallet created for backend operations

### Contract Deployment
- [ ] ProxyAdmin deployed
- [ ] CodeManager deployed via proxy, initialized, voters configured
- [ ] Gift contract deployed, implements `IRedeemable`
- [ ] Privacy group authorized on CodeManager (`voteToAuthorizePrivacyGroup`)
- [ ] PrivateComboStorage deployed in Pente privacy group
- [ ] DakotaDelegation deployed via proxy (EIP-7702 target)
- [ ] GasSponsor deployed via proxy, funded
- [ ] ERC-6551 Registry deployed or verified at canonical address
- [ ] ERC-6551 Account Implementation deployed
- [ ] ERC-1155 Trait collection deployed (if using TBA traits)

### Code Lifecycle
- [ ] UID range registered on CodeManager (`registerUniqueIds`)
- [ ] Codes generated off-chain (PIN + code → hash)
- [ ] Hashes batch-stored in PrivateComboStorage (`storeDataBatch`)
- [ ] Codes unfrozen for redemption (`setFrozen(uid, false)`)
- [ ] Redemption tested end-to-end (PIN+hash → Pente → CodeManager → gift contract)

### Integration
- [ ] Frontend connects to chain 112311 via thirdweb SDK
- [ ] User authentication working (email / social / passkey)
- [ ] Code redemption UI working
- [ ] NFT gallery displaying tokens from gift contract
- [ ] TBA creation and trait minting working (if applicable)
- [ ] Blockscout showing NFTs, TBAs, and trait holdings
- [ ] Gas sponsorship verified (users pay nothing)

---

## Source Files Reference

| File | Description |
|------|-------------|
| `Contracts/Genesis/BesuGenesis.7z` | Besu genesis file (7z-compressed; extract before use) |
| `Contracts/CodeManagement/CodeManager.sol` | Public registry + Pente router (v3.0, upgradeable) |
| `Contracts/CodeManagement/PrivateComboStorage.sol` | Pente privacy group contract (v1.0) |
| `Contracts/CodeManagement/Interfaces/ICodeManager.sol` | Registry interface |
| `Contracts/CodeManagement/Interfaces/IRedeemable.sol` | Gift contract interface (6 functions) |
| `Contracts/CodeManagement/Interfaces/IComboStorage.sol` | Private storage interface (5 functions) |
| `Contracts/Genesis/7702/DakotaDelegation.sol` | EIP-7702 delegation target |
| `Contracts/Genesis/7702/GasSponsor.sol` | Gas sponsorship treasury |
| `Contracts/Genesis/7702/Interfaces/IDakotaDelegation.sol` | Delegation interface |
| `Contracts/Genesis/7702/Interfaces/IGasSponsor.sol` | Gas sponsor interface |
| `Contracts/Genesis/7702/EIP-7702-Instructions.md` | EIP-7702 deployment guide |
| `Contracts/Genesis/GasManager/GasManager.sol` | Block reward + gas funding governance |
| `Contracts/Genesis/ValidatorContracts/ValidatorSmartContractAllowList.sol` | QBFT validator governance |
| `Contracts/Genesis/ValidatorContracts/ValidatorSmartContractInterface.sol` | Validator interface |
| `Contracts/Genesis/Upgradeable/` | Vendored OpenZeppelin 4.9.6 upgradeable stack (MIT) |
| `Contracts/Genesis/Upgradeable/Proxy/Transparent/ProxyAdmin.sol` | Upgrade dispatch |
| `Contracts/Tokens/GreetingCards.sol` | ERC-721 gift card implementation (implements IRedeemable) |
| `Tools/SolcCompiler/compile.py` | Solidity compiler with auto-detect + vendored/GitHub import resolution |
| `Tools/BytecodeReplacer/replace_bytecode.py` | Bulk bytecode replacer for genesis files |
| `Tools/KeyWizard/dakota_keywizard.py` | EOA and Besu node key generator |
| `Tools/TxSimulator/tx_simulator.py` | Block-paced ETH transfer loop (QBFT/PoA) |
