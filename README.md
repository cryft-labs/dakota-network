# Dakota Network

Smart contracts, tools, and node configuration for the **Dakota Network** — an enterprise QBFT blockchain built on Hyperledger Besu with [Paladin](https://github.com/LFDT-Paladin/paladin) privacy, designed for permissioned environments where a fully public and decentralized network is not required.

All project-owned contracts are licensed under **Apache 2.0**. This software is part of a patented system — see the [LICENSE](LICENSE) file and <https://cryftlabs.org/licenses> for details.

> **PATENT NOTICE — U.S. Patent Application Serial No. 18/930,857**
>
> Portions of this software implement methods and systems described in [U.S. Patent Application Serial No. 18/930,857: *"Card System Utilizing On-Chain Managed Redeemable Gift Code"*](https://patents.google.com/patent/US20250139608A1/en), held by Cryft Labs.
>
> **The patented system covers the on-chain redeemable-code management architecture embodied primarily by the `CodeManager`, `ComboStorage`, and `PrivateComboStorage` contracts, including the three-layer Pente privacy integration (CodeManager router + Gift Contract authority + PrivateComboStorage in Pente privacy group).** Unauthorized reproduction, deployment, or commercial use of these contracts or any substantially similar implementation of the patented methods — on any blockchain or network — constitutes patent infringement and **will result in legal action, including injunctive relief and monetary damages, at the infringer's expense.**
>
> **IMPLEMENTATION NOTICE:** The accompanying implementation guide describes a patented architecture covering all 20 patent claims. **Implementing, deploying, or operating the described system — including any substantially similar three-layer architecture using a public registry/router, an authoritative gift contract, and a private verification layer — requires a license from Cryft Labs.** The implementation guide and source code are provided for **licensed parties only**. See <https://cryftlabs.org/licenses> for licensing inquiries.
>
> The `CryftGreetingCards` ERC-721 contract is a client of the redeemable-code service and is **not** itself the subject of the patent claims. Third parties may interface with the Cryft redeemable-code service (CodeManager / ComboStorage) under a valid license or when the applicable fees and permissions have been granted. See <https://cryftlabs.org/licenses> for licensing inquiries.

---

## Prerequisites

### Java

| Component | Version | Java |
|-----------|---------|------|
| **Besu** | 26.1.0 | Java 21 |

### Solidity

| Component | Version | Notes |
|-----------|---------|-------|
| **solc** | 0.8.34 | All contracts except ValidatorSmartContractAllowList |
| **solc** | 0.8.19 | ValidatorSmartContractAllowList only (pragma `<0.8.20`) |

### Paladin (Privacy Manager)

Paladin provides the Pente privacy domain used by PrivateComboStorage. It can be installed in several ways:

| Method | Complexity | Best For |
|--------|-----------|----------|
| **Docker** (recommended) | Low | Single-node, bare-metal servers, no K8s experience needed |
| **Build from source** | Medium | Developers, custom builds, air-gapped environments |
| **k3s + Helm** (Kubernetes) | Medium | Multi-node production, operator-managed lifecycle |

> **Prepackaged binaries:** Cryft Labs plans to provide prepackaged Paladin distributions for licensed parties once the system is established. Until then, use one of the methods below.

---

## Installation (Ubuntu)

**Fresh install:**
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

### Upgrading from an older Besu (and removing Tessera)

Tessera is no longer used — Paladin/Pente replaces it for private transaction support. The following script stops services, removes Tessera completely (systemd, binaries, config), removes old Besu versions, and installs 26.1.0:

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
  sudo rm -rf ~/dakota-network/Node/Node/Tessera
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
) && echo "Besu 26.1.0 installed, Tessera removed from system/path/config dir."
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

> **Tessera has been sunset.** The Besu project officially recommends migrating to [Paladin](https://github.com/LFDT-Paladin/paladin) for programmable privacy on EVM. See the [Paladin Setup](#paladin-privacy-manager-tessera-replacement) section below.

### Copy Node Configuration

The `Node/` directory contains a sample directory structure with node keys:

```bash
cp -r Node/Node /home/user/dakota-node
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
  --rpc-ws-enabled \
  --rpc-ws-api=ETH,NET,QBFT \
  --rpc-ws-port=8546 \
  --host-allowlist="*" \
  --rpc-http-cors-origins="all" \
  --rpc-http-port=8545 \
  --p2p-host=<YOUR_IP> \
  --sync-min-peers=3
```

> **Note:** The `--rpc-ws-*` flags enable WebSocket RPC, required if connecting Paladin to this node.

### Paladin Privacy Manager (Tessera Replacement)

[Paladin](https://github.com/LFDT-Paladin/paladin) is the recommended replacement for Tessera. It provides programmable privacy-preserving tokens on EVM, including ZKP tokens, notarized tokens, and private smart contracts (Pente privacy groups). Paladin connects to your Besu node via HTTP + WebSocket RPC.

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

#### Method A — Docker (No Kubernetes Required)

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

#### Method B — Build from Source

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

#### Method C — k3s + Helm (Kubernetes Operator)

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

#### Paladin Privacy Domains

| Domain | Description |
|--------|-------------|
| **Noto** | Notarized tokens — issuer-backed private token transfers |
| **Zeto** | ZKP tokens — zero-knowledge proof backed private transfers |
| **Pente** | Private EVM smart contracts — privacy groups with private state |

#### Paladin UI

The Paladin node runs a web UI at `/ui`:
- **Docker:** `http://localhost:8548/ui`
- **k3s:** `http://<MACHINE_IP>:31548/ui`
- **kind:** `http://localhost:31548/ui`

#### Paladin Resources

- **Documentation:** <https://lfdt-paladin.github.io/paladin/head>
- **GitHub:** <https://github.com/LFDT-Paladin/paladin>
- **Latest release:** v0.15.0
- **Configuration reference:** <https://lfdt-paladin.github.io/paladin/head/administration/configuration/>
- **Tutorials:** <https://lfdt-paladin.github.io/paladin/head/tutorials/>
- **Advanced installation (Helm):** <https://lfdt-paladin.github.io/paladin/head/getting-started/installation-advanced/>
- **Manual installation (Helm CRDs):** <https://lfdt-paladin.github.io/paladin/head/getting-started/installation-manual/>
- **Discord:** [paladin channel on LFDT Discord](https://discord.com/channels/905194001349627914/1303371167020879903)

---

## Security Notes

- Replace the default keys in `Node/` before any production deployment.
- Ensure your firewall allows port `30303` (P2P) and `8545` (HTTP-RPC).
- Restrict `--rpc-http-api`, `--host-allowlist`, and `--rpc-http-cors-origins` for production.
- Customize `genesis.json` if additional parameters are required.

---

## Documentation & References

### Besu

Besu documentation has moved to a self-hosted versioned model.

- **Versioned documentation index:** <https://lf-hyperledger.atlassian.net/wiki/spaces/BESU/pages/22156555/Versioned+documentation>
- **Besu GitHub releases:** <https://github.com/hyperledger/besu/releases/tag/26.1.0>
- **Besu 26.1.0 release notes:** <https://github.com/hyperledger/besu/releases/tag/26.1.0>

### Paladin (Privacy Manager)

Paladin replaces Tessera as the recommended privacy solution for Besu networks.

- **Paladin docs:** <https://lfdt-paladin.github.io/paladin/head>
- **Paladin GitHub:** <https://github.com/LFDT-Paladin/paladin>
- **Docker image:** `ghcr.io/lfdt-paladin/paladin:latest`
- **Configuration reference:** <https://lfdt-paladin.github.io/paladin/head/administration/configuration/>
- **Installation guide (Helm):** <https://lfdt-paladin.github.io/paladin/head/getting-started/installation>
- **Advanced installation (Helm):** <https://lfdt-paladin.github.io/paladin/head/getting-started/installation-advanced/>
- **Tessera sunset announcement:** <https://www.lfdecentralizedtrust.org/blog/sunsetting-tessera-and-simplifying-hyperledger-besu>

---

## Network Configuration

### Block Timing

| Parameter | Value | Notes |
|-----------|-------|-------|
| **Block period** | 1 second | Time between blocks when transactions are pending |
| **Empty block period** | 64 seconds | Time between blocks when no transactions are pending |
| **Epoch length** | 64,000 blocks | Validator set checkpoint interval |
| **Request timeout** | 86 seconds | QBFT round-change timeout |

### Genesis File Breakdown

The genesis file (`Contracts/Genesis/besuGenesis.json`, ~1.07 GB) contains the full initial state for the network.

#### Chain Parameters

| Parameter | Value |
|-----------|-------|
| **Chain ID** | `112311` |
| **Consensus** | QBFT (Istanbul BFT) |
| **Gas limit** | 32,000,000 |
| **Block reward** | 3.2 ETH per block (sent to `miningBeneficiary`) |
| **Contract size limit** | 32,768 bytes (32 KiB) |
| **EVM fork** | Prague/Pectra (all forks enabled from genesis) |

#### Ethereum Fork Activation

All Ethereum hard forks through Prague/Pectra are activated from genesis (block 0 / timestamp 0). Pre-Merge forks use block-number activation; post-Merge forks use timestamp-based activation per Besu convention.

| Fork | Genesis Key | Activation | Notable EIPs |
|------|------------|------------|--------------|
| **Homestead** | `homesteadBlock: 0` | Block 0 | EIP-2 (tx validation), EIP-7 (DELEGATECALL) |
| **EIP-150** | `eip150Block: 0` | Block 0 | Gas cost rebalancing (Tangerine Whistle) |
| **EIP-155/158** | `eip155Block: 0` / `eip158Block: 0` | Block 0 | Replay protection, state clearing (Spurious Dragon) |
| **Byzantium** | `byzantiumBlock: 0` | Block 0 | REVERT opcode, STATICCALL, precompiles |
| **Constantinople** | `constantinopleBlock: 0` | Block 0 | SHL/SHR/SAR opcodes, CREATE2, EXTCODEHASH |
| **Petersburg** | `petersburgBlock: 0` | Block 0 | Removed EIP-1283 (SSTORE re-entrancy fix) |
| **Istanbul** | `istanbulBlock: 0` | Block 0 | ChainID opcode, SELFBALANCE, Blake2 precompile |
| **Muir Glacier** | `muirglacierblock: 0` | Block 0 | Difficulty bomb delay (no EVM changes) |
| **Berlin** | `berlinBlock: 0` | Block 0 | Access lists (EIP-2929/2930), cold/warm storage pricing |
| **London** | `londonBlock: 0` | Block 0 | EIP-1559 base fee, EIP-3529 refund reduction |
| **Shanghai** | `shanghaiTime: 0` | Timestamp 0 | PUSH0 (EIP-3855), warm COINBASE (EIP-3651), initcode limits (EIP-3860) |
| **Cancun** | `cancunTime: 0` | Timestamp 0 | Transient storage TSTORE/TLOAD (EIP-1153), MCOPY (EIP-5656), SELFDESTRUCT neutered (EIP-6780) |
| **Prague/Pectra** | `pragueTime: 0` | Timestamp 0 | EIP-7702 (EOA code delegation), EIP-7251 (max effective balance), EIP-7002 (execution layer withdrawals) |

#### Alloc Entries (32,432 total)

| Category | Count | Description |
|----------|-------|-------------|
| Addresses ending in `323` | 32,324 | Pre-deployed contract instances (greeting card service) |
| Addresses ending in `c0DE` | 100 | Pre-deployed contract instances (code management service) |
| Repeating-pattern addresses | 4 | Reserved contract slots (`0x2222...`, `0x2323...`, `0x3232...`, `0x3333...`) |
| Reserved system addresses | 7 | Governance and infrastructure contracts (see below) |
| EOA accounts | 1 | Deployer account with 32 ETH initial balance |

#### Reserved System Addresses

| Address | Comment | Purpose |
|---------|---------|---------|
| `0x0000...1111` | Validator smart contract | `ValidatorSmartContractAllowList` — QBFT validator/voter/overlord governance |
| `0x0000...cafE` | GasManager smart contract | `GasManager` — block reward beneficiary, voter-governed gas funding and burns |
| `0x0000...c0DE` | CodeManager smart contract | `CodeManager` — official Dakota code management service (patent-covered) |
| `0x0000...Face` | ERC-8004 Agent Registry | Official ERC-8004 agent identity contract |
| `0x0000...FacAdE` | ProxyAdmin smart contract | `ProxyAdmin` — guardian-gated ERC1967 upgrade dispatch |
| `0x0000...de1E6A7E` | DakotaDelegation | EIP-7702 delegation target (upgradeable — TransparentUpgradeableProxy) |
| `0x0000...FEeD` | GasSponsor | Gas sponsorship treasury (upgradeable — TransparentUpgradeableProxy) |

---

## Contracts

### Genesis Contracts (deployed at network genesis)

| Contract | Address | Runtime Size | Purpose |
|----------|---------|-------------|---------|
| **ValidatorSmartContractAllowList** | `0x0000...1111` | 20,565 B | QBFT validator, voter, and root overlord governance |
| **GasManager** | Genesis beneficiary | 14,510 B | Voter-governed gas funding, token burns, and native coin burns |
| **TransparentUpgradeableProxy** | Per-contract | 17,175 B | Multi-party overlord/guardian transparent proxy |
| **ProxyAdmin** | Per-proxy | 3,296 B | Guardian-gated ERC1967 upgrade dispatch |

---

### ValidatorSmartContractAllowList (`0x0000...1111`)

The core governance contract for the QBFT consensus layer. Deployed at genesis address `0x0000000000000000000000000000000000001111`. The initializer (`initialize()`) becomes the first voter — there is no guardian role in this contract, all operations are voter-driven.

#### Access Control

| Role | How Assigned | Powers |
|------|-------------|--------|
| **Voter** | Supermajority vote of existing voters | All governance actions below |

All state changes require **2/3 supermajority quorum**: `(totalVoterCount * 2 + 2) / 3`. The voter pool is the union of local `votersArray[]` and all addresses returned by contracts in `otherVoterContracts[]`.

#### Governance Actions (all require voter supermajority)

| Action | Function | Constraints |
|--------|----------|-------------|
| Add validator | `voteToAddValidator()` | Must not exceed `MAX_VALIDATORS` cap; not already in list |
| Remove validator | `voteToRemoveValidator()` | Must exist in local list |
| Add voter | `voteToAddVoter()` | Must not already be a voter (aggregated) |
| Remove voter | `voteToRemoveVoter()` | `getVoters().length > 1` — cannot remove the last voter |
| Add external validator contract | `voteToAddOtherValidatorContract()` | Must be a contract implementing `getValidators()` and `isValidator()` |
| Remove external validator contract | `voteToRemoveOtherValidatorContract()` | Must exist in list |
| Add external voter contract | `voteToAddOtherVoterContract()` | Must implement `getVoters()` and `isVoter()` |
| Remove external voter contract | `voteToRemoveOtherVoterContract()` | `votersArray.length > 0 \|\| otherVoterContracts.length > 1` — prevents empty voter pool |
| Add root overlord | `voteToAddRootOverlord()` | Not `address(0)`, not already an overlord |
| Remove root overlord | `voteToRemoveRootOverlord()` | Must exist in local list |
| Add external overlord contract | `voteToAddOtherOverlordContract()` | Must implement `getRootOverlords()` and `isRootOverlord()` |
| Remove external overlord contract | `voteToRemoveOtherOverlordContract()` | Must exist in list |
| Change max validators | `voteToChangeMaxValidators()` | Must be > 0 (no upper bound) |
| Change vote tally block threshold | `voteToUpdateVoteTallyBlockThreshold()` | 1 to 100,000 blocks |

#### Vote Tally Mechanics

- Each vote type + target pair has an independent tally with a start block.
- Votes expire after `voteTallyBlockThreshold` blocks (default: 1,000, ~50 min at 3s blocks).
- Expired tallies auto-reset on the next vote attempt for that target, or via the voter-only `resetExpiredTally()` function (`external onlyVoters`).
- Voter-pool changes (add/remove voter, add/remove external voter contract, revoke voter management) are blocked while any tally is active (`activeVoteCount > 0`), ensuring the supermajority threshold remains stable for in-flight votes.

#### Federated Expansion (Pluggable External Contracts)

Three categories of external contracts can be plugged in:

| Array | Interface Required | Aggregation Function |
|-------|-------------------|---------------------|
| `otherValidatorContracts[]` | `getValidators()`, `isValidator()` | `getValidators()` — union of local + all external validators |
| `otherVoterContracts[]` | `getVoters()`, `isVoter()` | `getVoters()` — union of local + all external voters |
| `otherOverlordContracts[]` | `getRootOverlords()`, `isRootOverlord()` | `getRootOverlords()` — union of local + all external overlords |

All external calls use `try/catch` — a failing external contract is silently skipped (returns 0 entries), preventing a single broken contract from bricking governance.

#### Permanent Management Revocation

Three independent management domains can be **permanently and irreversibly** revoked via voter supermajority, delegating all future governance to external contracts:

**1. Overlord Management Revocation** (`voteToRevokeOverlordManagement()`)
- Pre-conditions: `rootOverlords[]` must be empty; `otherOverlordContracts[]` must have ≥1 entry
- Effect: Blocks `ADD_ROOT_OVERLORD`, `REMOVE_ROOT_OVERLORD`, `ADD_OTHER_OVERLORD_CONTRACT`, `REMOVE_OTHER_OVERLORD_CONTRACT`

**2. Validator Management Revocation** (`voteToRevokeValidatorManagement()`)
- Pre-conditions: `validators[]` must be empty; `otherValidatorContracts[]` must have ≥1 entry; `getValidators()` must return ≥4 addresses (aggregated)
- Effect: Blocks `ADD_VALIDATOR`, `REMOVE_VALIDATOR`, `ADD_OTHER_VALIDATOR_CONTRACT`, `REMOVE_OTHER_VALIDATOR_CONTRACT`

**3. Voter Management Revocation** (`voteToRevokeVoterManagement()`) — **must be last**
- Pre-conditions: Overlord management already revoked; validator management already revoked; `votersArray[]` must be empty; `otherVoterContracts[]` must have ≥1 entry; `getVoters()` must return ≥1 address (aggregated)
- Effect: Blocks `ADD_VOTER`, `REMOVE_VOTER`, `ADD_OTHER_VOTER_CONTRACT`, `REMOVE_OTHER_VOTER_CONTRACT`

Once all three are revoked, this contract's local lists are permanently frozen. All governance is delegated to the listed external contracts. The contract continues to serve aggregation queries (`getValidators()`, `getVoters()`, `getRootOverlords()`) combining local (frozen) and external (live) data.

#### Lockout Prevention

| Scenario | Guard |
|----------|-------|
| Remove last voter | `getVoters().length > 1` enforced before removal |
| Remove last external voter contract when no local voters | `votersArray.length > 0 \|\| otherVoterContracts.length > 1` |
| Voter-pool change during active tally | `activeVoteCount == 0` required; use `resetExpiredTally()` to clean up stale tallies |
| Revoke voter management with no external voters | Requires `otherVoterContracts.length > 0` and `getVoters().length >= 1` |
| Revoke validator management with too few validators | Requires `getValidators().length >= 4` (QBFT minimum) |
| Revoke voter management before other domains | Requires overlord + validator management already revoked |
| `address(0)` as voter/validator/overlord | All entry points require `!= address(0)` |

---

### GasManager (Genesis Beneficiary)

Receives all block rewards as the QBFT beneficiary address. Provides voter-governed gas funding, token burns, and native coin burns with a two-phase vote → approve → execute pattern. Uses its own independent voter pool, separate from the validator contract's voters.

#### Access Control

| Role | How Assigned | Powers |
|------|-------------|--------|
| **Voter** | Supermajority vote of existing voters | Vote on all governance actions |
| **Guardian** | Supermajority vote of voters | Execute approved funds/burns; execute token and native coin burns. Can be individually added/removed or bulk-cleared via `voteToClearGuardians()`. Enumerable via `getGuardians()` / `getGuardianCount()`. |

#### Two-Phase Operations

Destructive operations (funding, burns) require two phases:

1. **Vote phase**: Voters reach supermajority quorum on the operation. On passing, a `bytes32` approval key is stored.
2. **Execute phase**: A guardian (or the funded address for gas funds) calls the execute function, which checks the approval key, clears it, and performs the transfer.

| Operation | Vote Function | Execute Function | Who Can Execute |
|-----------|--------------|-----------------|-----------------|
| Fund gas to address | `voteToFundGas(to, amount)` | `executeFundGas(to, amount)` | Guardian or `to` address |
| Burn ERC-20 tokens | `voteToBurnTokens(token, amount)` | `executeTokenBurn(token, amount)` | Guardian only |
| Burn native coin | `voteToBurnNativeCoin(amount)` | `executeCoinBurn(amount)` | Guardian only |

All execute functions are protected by `ReentrancyGuard` and use `.call{value:}` for transfers. The `executeFundGas` function also verifies the exact balance delta after transfer.

#### Guardian Management

| Action | Function | Notes |
|--------|----------|-------|
| Add guardian | `voteToAddGuardian(address)` | Voter supermajority required; must not already be a guardian |
| Remove guardian | `voteToRemoveGuardian(address)` | Voter supermajority required; must be an existing guardian |
| Clear all guardians | `voteToClearGuardians()` | Voter supermajority required; at least 1 guardian must exist |
| List guardians | `getGuardians()` | Returns full `address[]` array |
| Count guardians | `getGuardianCount()` | Returns `uint256` count |

Clearing emits `GuardiansCleared(count)` and resets all guardian mappings and the array in one operation.

#### Configurable Parameters (voter supermajority)

| Parameter | Default | Function | Constraints |
|-----------|---------|----------|-------------|
| `voteTallyBlockThreshold` | 1,000 blocks | `voteToUpdateVoteTallyBlockThreshold()` | 1 to 100,000 |

#### Native Coin Burns

Voters can burn any amount of the contract's native coin balance via `voteToBurnNativeCoin(amount)` → `executeCoinBurn(amount)`, sending it to `0x...dEaD`. This is the only mechanism for reducing accumulated gas fees — there is no automatic cap or auto-burn.

#### Voter Pool (Independent)

The GasManager has its own local `votersArray[]` and pluggable `otherVoterContracts[]`, completely independent from the ValidatorSmartContractAllowList voter pool. External voter contracts must implement `getVoters()` and `isVoter()`. Quorum is `(totalVoterCount * 2 + 2) / 3`.

#### Lockout Prevention

| Scenario | Guard |
|----------|-------|
| Remove last voter | `getVoters().length > 1` enforced before removal |
| Remove last external voter contract when no local voters | `votersArray.length > 0 \|\| otherVoterContracts.length > 1` |
| Voter-pool change during active tally | `activeVoteCount == 0` required; use `resetExpiredTally()` to clean up stale tallies |
| `address(0)` as voter/guardian/recipient | All entry points require `!= address(0)` |
| Clear guardians when none exist | `guardiansArray.length > 0` required |
| Re-entrancy on fund/burn execution | `ReentrancyGuard` modifier on all execute functions |
| Balance discrepancy after fund transfer | Exact balance delta check: `balanceBefore - balanceAfter == _amount` |

#### Upgradeability

GasManager inherits `Initializable` and `ReentrancyGuardUpgradeable` from OpenZeppelin v4.9.0. The constructor calls `_disableInitializers()` to prevent re-initialization of the implementation contract.

---

### TransparentUpgradeableProxy

Extended OpenZeppelin ERC1967 transparent proxy with multi-party overlord/guardian governance and 2/3 supermajority threshold voting. Every proxy instance deployed in the genesis file is an independent governance unit.

#### Access Tiers

| Tier | Source | Powers |
|------|--------|--------|
| **Root Overlord** | Read dynamically from validator contract at `0x0000...1111` via `getRootOverlords()` / `isRootOverlord()` | Add/remove non-root overlords directly (no vote needed) |
| **Overlord** (non-root) | Added by root overlord or via 2/3 overlord vote | Propose and vote on governance actions (2/3 threshold) |
| **Guardian** | Added via 2/3 overlord vote | Operational: `proxy_linkLogicAdmin()` (one-time), trigger upgrades via ProxyAdmin |
| **Admin** (ProxyAdmin contract) | Set during `proxy_linkLogicAdmin()`, changeable via 2/3 overlord vote | ERC1967 upgrade dispatch (`upgradeTo`, `upgradeToAndCall`, `changeAdmin`) |

Root overlords are **not stored** in the proxy — they are read live from the validator contract via `try/catch`. If the validator contract is unreachable, root overlord calls return `false` / empty array (safe degradation).

#### Overlord Count and Threshold

- `proxy_getOverlordCount()` = non-root overlords + root overlord count (when active)
- Threshold = `ceil(count × 2 / 3)` = `(count * 2 + 2) / 3`
- Examples: 1→1, 2→2, 3→2, 4→3, 5→4, 6→4

A single overlord can pass any proposal unilaterally (threshold = 1).

#### Governance Actions (2/3 supermajority)

| Action | Function | Constraints |
|--------|----------|-------------|
| Add overlord | `proxy_proposeOverlordChange(target, true)` | Not `address(0)`, not a root overlord, not already an overlord, not a guardian |
| Remove overlord | `proxy_proposeOverlordChange(target, false)` | Must be an overlord; cannot remove last non-root when no root overlords are active |
| Add guardian | `proxy_proposeGuardianChange(target, true)` | Not `address(0)`, not the validator contract, not an overlord, max 10 guardians |
| Remove guardian | `proxy_proposeGuardianChange(target, false)` | Must be a guardian |
| Clear all guardians | `proxy_proposeClearGuardians()` | At least 1 guardian exists |
| Change vote expiry | `proxy_proposeExpiryChange(newExpiry)` | Minimum 100 blocks (~5 min at 3s blocks) |
| Revoke root overlord | `proxy_proposeRevokeRootOverlord()` | Root not already revoked; at least 1 non-root overlord exists |
| Restore root overlord | `proxy_proposeRestoreRootOverlord()` | Root must be revoked; only non-root overlords can propose (root is excluded) |
| Change proxy admin | `proxy_proposeAdminChange(newAdmin)` | Not `address(0)`, not the current admin |

#### Root Overlord Direct Actions (no vote)

| Action | Function | Constraints |
|--------|----------|-------------|
| Add overlord | `proxy_addOverlord()` | Same as voted version |
| Remove overlord | `proxy_removeOverlord()` | Same as voted version |
| Voluntary self-revoke | `proxy_revokeRootOverlord()` | Must be root overlord; root not already revoked; `_rawOverlordCount() > 0` |

Direct root overlord changes also increment the vote epoch, invalidating all pending proposals.

#### Voting Mechanics

- **Single-session lock**: Only one proposal can be actively voted on at a time. A second proposal reverts unless the first has expired.
- **Vote expiry**: Default 60,000 blocks (~1 week at 3s blocks). Expired proposals auto-increment their round, invalidating stale votes.
- **Vote epoch**: Incremented on every executed proposal or direct overlord change. Changing the epoch invalidates all pending proposals across all proposal types.
- **Proposal rounds**: Each proposal key tracks a round counter. On expiry, the round increments, creating a fresh proposal ID while preserving the base key.

#### Storage Design

All proxy governance state is stored in **namespaced `keccak256` slots** (e.g., `keccak256("TransparentUpgradeableProxy.overlordMap")`) to avoid collisions with the implementation contract's storage. This is critical — standard Solidity storage slots 0, 1, 2... would conflict with the proxied contract.

#### Proxy Linkage (One-Time)

`proxy_linkLogicAdmin(logic, admin, data)` — guardian-gated, can only be called once (`isInit` flag). Sets the implementation address, initializes it with `data`, and assigns the ERC1967 admin (typically a ProxyAdmin contract).

#### Lockout Prevention

| Scenario | Guard |
|----------|-------|
| Remove last non-root overlord when root is inactive | `_rawOverlordCount() > 1 \|\| (rootCount > 0 && !revoked)` |
| Voluntary root revoke with no non-root overlords | `_rawOverlordCount() > 0` |
| Force-revoke root with no non-root overlords | Same check in `proxy_proposeRevokeRootOverlord()` |
| Set admin to `address(0)` | `_setAdmin` in ERC1967Upgrade requires `newAdmin != address(0)` |
| Link logic with `address(0)` admin/logic | Both checked `!= address(0)` in `proxy_linkLogicAdmin()` |
| Overlord/guardian dual-role | Both `proxy_addOverlord` and `proxy_proposeGuardianChange` cross-check to prevent any address holding both roles |
| Mid-vote membership manipulation | Every direct add/remove calls `_incrementVoteEpoch()`, invalidating all pending proposals |
| Single overlord stuck (threshold too high) | Threshold formula: `(1*2+2)/3 = 1` — a single overlord passes anything |
| Guardian overflow | Hard cap: `MAX_GUARDIANS = 10` |

#### Constants

| Constant | Value | Notes |
|----------|-------|-------|
| `_proxy_validatorContract` | `0x0000...1111` | Genesis validator contract address |
| `DEFAULT_VOTE_EXPIRY` | 60,000 blocks | ~1 week at 3s blocks |
| `MAX_GUARDIANS` | 10 | Hard cap on guardian count per proxy |

---

### ProxyAdmin

Auxiliary contract assigned as the ERC1967 admin of `TransparentUpgradeableProxy` instances. Replaces OpenZeppelin's single-owner pattern with per-proxy guardian/overlord governance — each proxy is independently governed by its own controller set.

#### Access Control

| Action | Who | How |
|--------|-----|-----|
| Upgrade implementation | Guardian of the target proxy | `upgrade(proxy, impl)` or `upgradeAndCall(proxy, impl, data)` |
| Change admin | Overlords of the target proxy | `proxy_proposeAdminChange()` on the proxy itself (2/3 vote) |

The `onlyGuardianOf(proxy)` modifier queries the proxy's `proxy_isGuardian(msg.sender)` — which returns `true` for mapped guardians and for active root overlords (root overlords are implicit guardians).

#### Introspection

| Function | Returns |
|----------|---------|
| `getProxyAdmin(proxy)` | Current ERC1967 admin address |
| `getProxyImplementation(proxy)` | Current implementation address |
| `getProxyGuardians(proxy)` | Array of all guardian addresses |
| `getProxyGovernanceStatus(proxy)` | Full state snapshot: admin, implementation, root revoked, overlord count, guardian count, threshold, active proposal, vote epoch, expiry |

---

### Cross-Contract Interaction Model

```
ValidatorSmartContractAllowList (0x1111)
  │
  ├── getRootOverlords() ──────────► TransparentUpgradeableProxy
  ├── isRootOverlord(addr) ────────►   (reads root overlords dynamically)
  │
  └── Voter supermajority governs:
        - Validators (QBFT consensus)
        - Voters (self-governance)
        - Root overlords (proxy governance tier)
        - External contract delegation

TransparentUpgradeableProxy
  │
  ├── Root overlords ──► direct add/remove overlords
  ├── Overlords (2/3) ──► governance votes
  ├── Guardians ──► proxy_linkLogicAdmin(), trigger upgrades via ProxyAdmin
  │
  └── ERC1967 admin (ProxyAdmin) ──► upgradeTo(), upgradeToAndCall()

GasManager (independent)
  │
  └── Own voter pool ──► vote → approve → guardian executes

CodeManager (independent)
  │
  └── Own voter pool ──► supermajority governance (whitelist, fees, voter mgmt)
```

---

### Application Contracts (deployed post-genesis)

| Contract | Purpose |
|----------|---------|
| **CodeManager** | **Patent-covered.** Permissionless unique ID registry. Own independent voter pool with pluggable `otherVoterContracts[]`, 2/3 supermajority quorum, voter-pool freeze while tallies are active. Charges a configurable registration fee forwarded to a fee vault. Deterministic ID generation via `keccak256(address(this), giftContract, chainId) + counter`. |
| **ComboStorage** | **Patent-covered.** Redemption verification service. Validates codes against CodeManager, records verified redemptions. Access-controlled via CodeManager's whitelist. |
| **CryftGreetingCards** | ERC-721 NFT (service client — not patent-covered). Mint-on-purchase with atomic CodeManager registration. Per-batch `PurchaseSegment` storage for gas-efficient buyer/URI lookups (binary search). Explicit freeze for lost/stolen codes. Interfacing with the redeemable-code service is permitted with proper fees or license. |

---

## Tools

### `Tools/keywizard/dakota_keywizard.py`

Interactive wizard for generating and distributing three types of cryptographic keys across your node network. No external Python packages required (stdlib only).

**Key types:**
- **EOA accounts** — private key + address, optional keystore V3 JSON
- **Besu node keys** — `key` + `key.pub` for P2P identity / validator signing

**SCP distribution:** After generation, the wizard can distribute each key set to remote nodes via SCP with per-key review, retry on failure, and optional deletion of local originals.

**Interactive mode (default):**
```bash
python3 Tools/keywizard/dakota_keywizard.py
```

**CLI flags for scripted/batch use:**
```bash
# Generate 4 Besu node keys, no EOA, with SCP step
python3 Tools/keywizard/dakota_keywizard.py \
  --besu-count 4 \
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
  --besu-count 4
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
| `--name-prefix-eoa` | `eoa-` | Folder prefix for EOA keys |
| `--name-prefix-besu` | `besu-node-` | Folder prefix for Besu node keys |
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
- `--solc-version 0.8.34` — override compiler version
- `--evm berlin` — override EVM target

---

## Repository Structure

```
dakota-network/
├── LICENSE                            # Apache 2.0 + patent notice
├── Contracts/
│   ├── Code Management/
│   │   ├── CodeManager.sol           # Permissionless unique ID registry (fee-based)
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
│   │   └── dakota_keywizard.py       # EOA and Besu node key generator
│   ├── tx_simulator/
│   │   └── tx_simulator.py            # Block-paced ETH transfer loop (QBFT/PoA)
│   └── solc_compiler/
│       ├── compile.py                # Local Solidity compiler (py-solc-x)
│       └── compiled_output/          # ABI and artifact output
├── Node/                             # Sample node directory structure
│   ├── genesisPalceholder.json       # Placeholder genesis (production file too large for repo)
│   └── Node/
│       └── data/
│           ├── key                   # Besu node private key (P2P / validator signing)
│           └── key.pub               # Besu node public key
└── README.md
```

---

## License

All project-owned smart contracts and tools are licensed under the **Apache License, Version 2.0**.

This software is part of a patented system. See the [LICENSE](LICENSE) file for the full license text and patent notice, and <https://cryftlabs.org/licenses> for additional details.

OpenZeppelin-derived contracts under `Contracts/Genesis/proxy/`, `Contracts/Genesis/utils/`, and `Contracts/Genesis/interfaces/` retain their original **MIT** license.

### Patent Enforcement

The `CodeManager` and `ComboStorage` contracts implement methods claimed in [U.S. Patent Application Serial No. 18/930,857](https://patents.google.com/patent/US20250139608A1/en). **Any unauthorized use, reproduction, or deployment of these contracts or substantially similar implementations will be pursued through legal action. All costs, damages, and attorney fees will be sought against the infringing party.** Contact <https://cryftlabs.org/licenses> for licensing.
