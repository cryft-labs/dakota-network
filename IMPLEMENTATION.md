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
4. [Layer 2 — Paladin / Pente Privacy Setup](#4-layer-2--paladin--pente-privacy-setup)
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
| **Kubernetes** | Any (k3s / kind / microk8s) | Paladin operator runtime |
| **Helm v3** | Latest | Paladin deployment |
| **solc** | 0.8.34 | Solidity compiler |
| **Node.js** | 18+ | Web application / thirdweb SDK |
| **Python** | 3.10+ | Compilation tooling |

### Accounts & Services

| Service | Purpose |
|---------|---------|
| **thirdweb** | In-app wallets, gas sponsorship, contract interaction API |
| **IPFS provider** (Pinata / web3.storage) | NFT metadata hosting |
| **Blockscout** (self-hosted) | Chain explorer for ERC-721/1155/6551 display |

---

## 3. Layer 1 — Besu Network Setup

### 3.1 Install Besu

```bash
sudo apt update && sudo apt install -y curl unzip tar openjdk-21-jdk

cd /tmp
curl -fL -o besu-26.1.0.zip \
  https://github.com/hyperledger/besu/releases/download/26.1.0/besu-26.1.0.zip
sudo unzip -q -o besu-26.1.0.zip -d /opt
sudo chmod +x /opt/besu-26.1.0/bin/besu

sudo tee /usr/local/bin/besu >/dev/null <<'EOF'
#!/usr/bin/env bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
exec /opt/besu-26.1.0/bin/besu "$@"
EOF
sudo chmod +x /usr/local/bin/besu
```

### 3.2 Genesis Configuration

The genesis file must activate all forks through Prague/Pectra from block 0. Key parameters:

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

```bash
besu \
  --data-path=/home/user/dakota-node/data \
  --genesis-file=/home/user/dakota-node/genesis.json \
  --bootnodes=enode://<BOOTNODE>@<IP>:30303 \
  --p2p-port=30303 \
  --rpc-http-enabled --rpc-http-api=ETH,NET,WEB3,TXPOOL,QBFT \
  --rpc-ws-enabled --rpc-ws-api=ETH,NET,WEB3,TXPOOL,QBFT \
  --rpc-ws-port=8546 \
  --rpc-http-port=8545 \
  --host-allowlist="*" \
  --rpc-http-cors-origins="all" \
  --p2p-host=<YOUR_IP>
```

> WebSocket (`--rpc-ws-*`) is **required** for Paladin connectivity.

---

## 4. Layer 2 — Paladin / Pente Privacy Setup

Paladin provides the Pente privacy domain — private EVM smart contracts with shared state visible only to privacy group members.

### 4.1 Install Kubernetes + Helm

**Production (k3s):**
```bash
curl -sfL https://get.k3s.io | sh -
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
kubectl get nodes
```

**Development (kind):**
```bash
curl https://raw.githubusercontent.com/LFDT-Paladin/paladin/refs/heads/main/operator/paladin-kind.yaml -L -O
kind create cluster --name paladin --config paladin-kind.yaml
```

### 4.2 Install Paladin Operator

```bash
# CRDs
helm repo add paladin https://LFDT-Paladin.github.io/paladin --force-update
helm upgrade --install paladin-crds paladin/paladin-operator-crd

# cert-manager
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager --namespace cert-manager --version v1.16.1 \
  jetstack/cert-manager --create-namespace --set crds.enabled=true
```

### 4.3 Deploy Paladin Node

Create `values-dakota.yaml`:

```yaml
mode: customnet
paladinNodes:
  - name: dakota-node1
    baseLedgerEndpoint:
      type: endpoint
      endpoint:
        jsonrpc: http://host.docker.internal:8545    # or <BESU_IP>:8545
        ws: ws://host.docker.internal:8546            # or <BESU_IP>:8546
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

Deploy:
```bash
helm install paladin paladin/paladin-operator -n paladin --create-namespace \
  -f values-dakota.yaml
```

### 4.4 Verify Paladin

```bash
kubectl -n paladin get pods              # Should show Running
kubectl -n paladin get scd               # Smart contract deployments
kubectl -n paladin get reg               # Node registration
kubectl -n paladin logs deploy/dakota-node1 --tail=50
```

### 4.5 Create a Pente Privacy Group

Use the Paladin JSON-RPC API to create a privacy group for code storage:

```bash
curl -X POST http://localhost:31548/rpc \
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

### 4.6 Authorize the Privacy Group on CodeManager

After creating the privacy group, the CodeManager voters must authorize it:

```javascript
// Each voter calls voteToAuthorizePrivacyGroup
// Requires 2/3 supermajority to pass
await codeManager.voteToAuthorizePrivacyGroup(privacyGroupAddress);
```

Once the supermajority is reached, `isAuthorizedPrivacyGroup[privacyGroupAddress]` becomes `true`, allowing PrivateComboStorage's `PenteExternalCall` events to be accepted by CodeManager's router functions.

---

## 5. Layer 3 — Contract Deployment

### 5.1 Compilation

Use the included compiler tool:

```bash
python Tools/solc_compiler/compile.py
```

This auto-detects pragma versions, resolves OZ imports, and outputs ABI + bytecode to `Tools/solc_compiler/compiled_output/`.

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
| **DakotaDelegation** | EIP-7702 | `Contracts/7702/DakotaDelegation.sol` | Delegation target for EOA smart features |
| **GasSponsor** | — | `Contracts/7702/GasSponsor.sol` | Gas sponsorship treasury |

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
- [ ] Besu 26.1.0 installed with `pragueTime: 0` in genesis
- [ ] All validator/RPC nodes running and synced
- [ ] Kubernetes cluster ready (k3s / kind / microk8s)
- [ ] Paladin operator deployed with Pente domain enabled
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
| `Contracts/Code Management/CodeManager.sol` | Public registry + Pente router (v3.0, upgradeable) |
| `Contracts/Code Management/ComboStorage.sol` | Legacy public combo storage (v1.0) |
| `Contracts/Code Management/PrivateComboStorage.sol` | Pente privacy group contract (v1.0) |
| `Contracts/Code Management/interfaces/ICodeManager.sol` | Registry interface |
| `Contracts/Code Management/interfaces/IRedeemable.sol` | Gift contract interface (6 functions) |
| `Contracts/Code Management/interfaces/IComboStorage.sol` | Private storage interface (5 functions) |
| `Contracts/Tokens/GreetingCards.sol` | ERC-721 gift card implementation (implements IRedeemable) |
| `Contracts/7702/DakotaDelegation.sol` | EIP-7702 delegation target |
| `Contracts/7702/GasSponsor.sol` | Gas sponsorship treasury |
| `Contracts/Genesis/GasManager.sol` | Block reward + gas funding governance |
| `Contracts/Genesis/proxy/transparent/ProxyAdmin.sol` | Upgrade dispatch |
| `Tools/solc_compiler/compile.py` | Solidity compiler with auto-detect + OZ import resolution |
