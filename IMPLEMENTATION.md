# Operational Runbook — Patented Redeemable Code Architecture

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
2. [Identity & Address Taxonomy](#2-identity--address-taxonomy)
3. [Public Bootstrap Procedure](#3-public-bootstrap-procedure)
4. [Node Registration Procedure](#4-node-registration-procedure)
5. [Creating a Privacy Group](#5-creating-a-privacy-group)
6. [Funding Strategy](#6-funding-strategy)
7. [Deploying the Private Implementation Contract](#7-deploying-the-private-implementation-contract)
8. [Deploying an Upgradeable Proxy inside Pente](#8-deploying-an-upgradeable-proxy-inside-pente)
9. [Proxy Admin Verification & Upgrades](#9-proxy-admin-verification--upgrades)
10. [Verifying the Private Contract](#10-verifying-the-private-contract)
11. [Signer & Admin Strategy](#11-signer--admin-strategy)
12. [Authorization & Whitelisting Strategy](#12-authorization--whitelisting-strategy)
13. [Store Flow — storeDataBatch](#13-store-flow--storedatabatch)
14. [Redeem Flow — redeemCodeBatch + External Call](#14-redeem-flow--redeemcodebatch--external-call)
15. [Troubleshooting Matrix](#15-troubleshooting-matrix)
16. [Operational Best Practices & Key Lessons](#16-operational-best-practices--key-lessons)
17. [Recommended Future Architecture — Forwarder / Meta-Transaction Pattern](#17-recommended-future-architecture--forwarder--meta-transaction-pattern)

---

## 1. Architecture Overview

The patented system uses a three-layer architecture. No single layer holds all the data needed to compromise a redeemable code. Private contract state transitions atomically trigger public-chain actions via `PenteExternalCall` events routed through CodeManager.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        PUBLIC CHAIN (Besu)                                │
│                                                                          │
│  ┌───────────────────────┐              ┌─────────────────────────────┐  │
│  │     CodeManager       │── resolve ──▶│       Gift Contract         │  │
│  │     (Registry +       │   UID→gift   │       (IRedeemable)         │  │
│  │      Router)          │              │                             │  │
│  │                       │◀── forward ──│  STATE: Redemption outcome  │  │
│  │  STATE:               │  calls via   │  • frozen / unfrozen        │  │
│  │  • UID registry       │  IRedeemable │  • redeemed (token moved)   │  │
│  │  • Mirrored active/   │              │  • ownership (NFT holder)   │  │
│  │    inactive (sparse)  │              │  • metadata URI             │  │
│  │  • Terminal REDEEMED  │              │  • syncRedemption recovery  │  │
│  │  • Governance votes   │              └─────────────────────────────┘  │
│  │  • Fee vault balance  │                                               │
│  │  • Privacy group      │                                               │
│  │    authorization list │                                               │
│  └───────────┬───────────┘                                               │
│              │ ▲                                                          │
│              │ │  PenteExternalCall events (atomic routing)               │
│              │ │  msg.sender = group contract address                     │
│              │ │                                                          │
│  ┌───────────▼─┴─────────────────────────────────────────────────────┐   │
│  │         PENTE PRIVACY GROUP  (shanghai EVM)                       │   │
│  │         Group contract addr: 0xf3cd...f8e4                        │   │
│  │                                                                   │   │
│  │   ┌────────────────────────────────────────┐                      │   │
│  │   │  TransparentUpgradeableProxy (OZ 5.2)  │  ← all calls here   │   │
│  │   │  Delegates to current implementation   │                      │   │
│  │   └────────────────┬───────────────────────┘                      │   │
│  │                    │ delegatecall                                  │   │
│  │   ┌────────────────▼───────────────────────┐                      │   │
│  │   │  PrivateComboStorage (implementation)  │                      │   │
│  │   │                                        │                      │   │
│  │   │  STATE: Private execution data         │                      │   │
│  │   │  • Code hashes (keccak256, private)    │                      │   │
│  │   │  • PIN→code bucket mapping             │                      │   │
│  │   │  • Per-UID active/inactive state       │                      │   │
│  │   │  • Per-UID mirror flags                │                      │   │
│  │   │  • Per-UID manager delegation          │                      │   │
│  │   │  • Contract-identifier whitelist       │                      │   │
│  │   │                                        │                      │   │
│  │   │  CONSTANTS (compile-time):             │                      │   │
│  │   │  • ADMIN     = Paladin signer addr     │                      │   │
│  │   │  • AUTHORIZED = meta-tx processor addr │                      │   │
│  │   │  • CODE_MANAGER = public CM address    │                      │   │
│  │   │  • MAX_PER_PIN                         │                      │   │
│  │   └────────────────────────────────────────┘                      │   │
│  │                                                                   │   │
│  │   ┌────────────────────────────────────────┐                      │   │
│  │   │  ProxyAdmin (auto-deployed by OZ 5.2)  │                      │   │
│  │   │  owner = Paladin signer address        │                      │   │
│  │   │  Only entity that can call upgrade()   │                      │   │
│  │   └────────────────────────────────────────┘                      │   │
│  │                                                                   │   │
│  │   msg.sender inside Pente = Paladin signer (0x01d5...13cb)        │   │
│  │   Derived submitters on base chain fund gas for external calls    │   │
│  └───────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer | Contract | State Owned | Responsibility |
|-------|----------|-------------|----------------|
| **Public Registry / Mirror** | CodeManager | UID registry, mirrored active/inactive overrides (sparse), terminal REDEEMED marking, governance votes, fee vault balance, privacy group authorization list | UID registration, deterministic ID generation, governance (2/3 supermajority), public mirrored UID state, and Pente routing. Only UIDs with mirroring enabled in PrivateComboStorage propagate state changes here — absence of a public override (USE_DEFAULT_ACTIVE_STATE) may indicate private-only management. |
| **Public Authority** | Gift Contract (IRedeemable) | Token ownership, frozen/unfrozen flags, redeemed status (token holder ≠ vault), metadata URI | Authority on redemption side effects and asset transfer. Decides how redemption works (single-use, multi-use, NFT transfer, etc.). Called by CodeManager via try/catch — reverts are caught and logged as RedemptionFailed events, not propagated. The UID remains terminally REDEEMED at every layer regardless. Recovery via `syncRedemption`. |
| **Private Proxy** | TransparentUpgradeableProxy (OZ 5.2) | None (delegates all storage to implementation) | Entry point for all private contract interactions. Delegates to the current PrivateComboStorage implementation via `delegatecall`. All state lives in the proxy's storage slots. Enables upgrades without redeployment. |
| **Private Storage / Execution** | PrivateComboStorage (implementation behind proxy) | Code hashes, PIN→bucket mappings, per-UID active/inactive state, per-UID mirror flags, per-UID manager delegation, contract-identifier whitelist | Hash-only code storage within a Pente privacy group. PINs are contract-assigned routing keys (not part of the hash). Verifies codes via hash comparison, tracks execution-time UID active state privately, and selectively mirrors valid status changes to CodeManager based on per-UID `mirrorStatuses` configuration. Supports per-UID manager delegation for fine-grained active-state control. Requires contract-identifier whitelisting before codes can be stored. All configuration is compile-time constants — changes require a contract upgrade via proxy. |
| **Private Admin** | ProxyAdmin (auto-deployed by OZ 5.2) | Ownership (owner = Paladin signer) | Controls upgrade authority for the proxy. Only the ProxyAdmin can call `upgradeAndCall` on the proxy. Owned by the Paladin signer — external EOAs cannot call upgrade directly. |

### Key Design Principles

- **No cleartext codes on-chain.** Codes are represented as `keccak256(code)` hashes. The PIN is a contract-assigned routing key (not part of the hash) for O(1) bucket lookup.
- **Private execution authority.** PrivateComboStorage decides whether a UID is active for redemption routing. Inactive or redeemed UIDs are skipped before any external redemption call is emitted.
- **Selective public mirroring.** Each UID's `mirrorStatuses` flag (set at store time) controls whether active-state changes propagate to CodeManager. When mirroring is disabled, the UID's active/frozen state remains private — CodeManager's public view returns `DEFAULT_ACTIVE_STATE` (active), but the private execution layer may independently freeze or block the UID.
- **Per-UID manager delegation.** Each UID can optionally have a dedicated manager address authorized to update its active state in ComboStorage. If no manager is set, only ADMIN or AUTHORIZED can act.
- **Public mirroring.** CodeManager mirrors private active-state changes publicly (for mirrored UIDs) and records redeemed UIDs as terminal state.
- **Gift contract isolation.** CodeManager marks the UID as REDEEMED before calling the gift contract, and wraps the call in try/catch. If the gift contract reverts (bug, misconfiguration), CodeManager emits a RedemptionFailed event instead of propagating the revert. The Pente transition succeeds and all private state changes are preserved. Admin monitoring should watch for RedemptionFailed events and resolve the gift-contract side effect manually.
- **Privacy-preserving verification.** The Pente privacy group verifies codes privately, then triggers public state updates via `PenteExternalCall`.
- **External calls.** The privacy group must be created with `externalCallsEnabled: "true"` (string, not boolean) so that `PenteExternalCall` events are processed by Paladin and forwarded to the base ledger.
- **EVM version.** Pente privacy groups run `shanghai` EVM. Public chain may run a later EVM version. Private contracts must compile with `--evm-version shanghai`.

---

## 2. Identity & Address Taxonomy

Understanding which address is which is critical. Paladin, Pente, and Besu each surface different addresses in different contexts. Confusing them is the #1 source of failed transactions and authorization errors.

### Address Types

| # | Address Type | Example | Where It Appears | Purpose |
|---|-------------|---------|-------------------|---------|
| 1 | **Paladin Signer** | `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb` | `ptx_resolveVerifier` response; Paladin signer configuration | The resolved address for a configured Paladin signer identity (e.g., `signer-auto-wallet@paladin-core`). Paladin uses this key to sign all transactions it submits. This is the `msg.sender` inside private contract calls. Must be used as `ADMIN` and `initialOwner`. Also used as `AUTHORIZED` when the meta-transaction processing service runs through the same Paladin node. |
| 2 | **Privacy Group Contract Address** | `0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4` | `pgroup_getGroupById` response; group creation receipt | The on-chain address of the Pente privacy group contract on the base ledger. **This is what gets authorized on CodeManager** via `voteToAuthorizePrivacyGroup()`. Not the derived submitter — the group contract address itself. |
| 3 | **Privacy Group ID** | `0x10be41b4...acc4ef` | `pgroup_createGroup` response; used in all `pgroup_sendTransaction` calls | The unique identifier for the privacy group. Used as the `group` parameter in all Paladin privacy-group API calls. Not the same as the group contract address. |
| 4 | **Derived Submitter** | `0xa907edf98de35db39cdbb42e1a6bdabe7e6c3c1b` | Paladin logs (`ProcessInFlightTransaction`) when funding is insufficient | A deterministic address derived by Paladin from the privacy group + signer identity + transaction path. Submits the base-ledger transaction that carries `PenteExternalCall` payloads. **Multiple derived submitters may exist** — one per transaction path (deploy, finalize, store, external-call). Fund the exact address shown in logs. |
| 5 | **Private Implementation Address** | `0xd10b4b8b9afe975c76e87dfa44ef73d820584959` | `ptx_getTransactionReceiptFull` → `domainReceipt.receipt.contractAddress` | The address of the deployed implementation contract inside the privacy group's state trie. For proxy setups, this is the `_logic` argument to the proxy constructor. |
| 6 | **Private Proxy Address** | (dynamically discovered from proxy deploy receipt) | `ptx_getTransactionReceiptFull` for the proxy deploy | The address of the `TransparentUpgradeableProxy` inside the privacy group. This is the contract address used as `to` in all subsequent `pgroup_sendTransaction` and `pgroup_call` requests. |
| 7 | **ProxyAdmin Address** | `0x6c7ea1dc87b0c778b2675735c98acfba94d3e042` | Discovered from proxy deploy receipt state inspection | The auto-deployed `ProxyAdmin` contract created by OpenZeppelin 5.2's `TransparentUpgradeableProxy` constructor. Its `owner()` must be a Paladin-signable address for upgrades to succeed. |
| 8 | **CodeManager (Public)** | deployed proxy address | Public chain | The `TransparentUpgradeableProxy` address of CodeManager on the base ledger. Hardcoded into `PrivateComboStorage` as `CODE_MANAGER`. |
| 9 | **Gift Contract (Public)** | deployed proxy address | Public chain | The `TransparentUpgradeableProxy` address of the ERC-721 (or other IRedeemable) contract on the base ledger. Registered on CodeManager via `registerUniqueIds`. |

### Critical Rules

> **When you see `insufficient funds for gas` in Paladin logs, the address before `:0` is the derived submitter.** Fund that exact address. Do not guess. Different transaction paths (deploy, finalize, store, external-call) may use different derived submitters.

> **The address to authorize on CodeManager is the privacy group contract address** (e.g., `0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`), **not** the derived submitter and **not** the Paladin signer. Earlier attempts that authorized only the derived submitter were insufficient. The privacy group contract address is the `msg.sender` that CodeManager sees when processing `PenteExternalCall` events.

> **Paladin does not sign as arbitrary external EOAs.** Paladin resolves configured signer identities (e.g., `signer-auto-wallet`) into Paladin-managed addresses. If your contract checks `msg.sender == ADMIN`, then `ADMIN` must be set to a Paladin-signable address — not an unrelated external EOA whose private key is not in Paladin's keystore.

---

## 3. Public Bootstrap Procedure

Before any privacy group or private contract work, the public chain contracts must be deployed and configured.

### 3.1 Deploy CodeManager (Upgradeable Proxy)

```
1. Deploy ProxyAdmin
2. Deploy CodeManager implementation
3. Deploy TransparentUpgradeableProxy pointing to CodeManager implementation
4. Call initialize() on the proxy
   → Sets deployer as first voter
   → Sets registrationFee = 10^15 (0.001 native)
   → Sets voteTallyBlockThreshold = 1000
```

### 3.2 Configure CodeManager

After initialization, the deployer (sole voter) can configure in one vote:

```
voteToUpdateFeeVault(feeVaultAddress)     → Where registration fees go
voteToUpdateRegistrationFee(newFee)       → Fee per UID registration (default 10^15)
```

### 3.3 Deploy Gift Contract (Upgradeable Proxy)

```
1. Deploy gift contract implementation (e.g., CryftGreetingCards)
2. Deploy TransparentUpgradeableProxy
3. Call initialize(name, symbol, baseURI, codeManagerProxyAddress, chainId)
   → Sets owner to msg.sender
   → Computes _contractIdentifier = toHexString(keccak256(codeManagerAddress, this, chainId))
```

### 3.4 Configure Gift Contract

```
setMaxSaleSupply(quantity)     → Maximum cards available for purchase
setPricePerCard(priceInWei)    → Price per card in native currency (0 = free)
setBaseTokenURI(ipfsURI)       → IPFS base URI for unredeemed card metadata
setContractURI(ipfsURI)        → Collection-level metadata for marketplaces
```

### 3.5 Public Chain Readiness Checklist

Before proceeding to Pente setup:

- [ ] CodeManager proxy deployed and `initialize()` called
- [ ] `feeVault` set (non-zero)
- [ ] Gift contract proxy deployed and `initialize()` called
- [ ] `maxSaleSupply` set
- [ ] `codeManagerAddress` on gift contract matches the CodeManager proxy
- [ ] Root signer funded with native currency

---

## 4. Node Registration Procedure

Each Paladin node has configured signer identities that must be resolved before participating in privacy groups.

### 4.1 Start Paladin

Paladin connects to a running Besu node. Each Paladin instance has one or more configured signers (e.g., `signer-auto-wallet`).

### 4.2 Resolve Signer Identity

Every Paladin signer identity resolves to a specific address. Resolve it before creating groups or deploying contracts:

```bash
PALADIN_RPC="http://100.111.32.2:30848"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"ptx_resolveVerifier",
    "params":[
      "signer-auto-wallet@paladin-core",
      "pente",
      "secp256k1"
    ]
  }' | jq .
```

The response contains the verifier address. **Record this address** — it is the `msg.sender` that will appear inside private contract calls and must be used as `ADMIN`, `initialOwner`, and as `AUTHORIZED` when the meta-transaction processing service runs through the same Paladin node.

Example resolved address:
```
0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb
```

### 4.3 Multi-Node Setup

For multi-node privacy groups, repeat identity resolution on each Paladin node. Exchange verifier strings between operators. All members must be resolved before group creation.

### 4.4 Critical: Use the Resolved Address for Contract Configuration

If your private contract uses `msg.sender`-based authorization (e.g., `require(msg.sender == ADMIN)`), the `ADMIN` constant must be set to the resolved Paladin signer address — not an unrelated external EOA. Paladin cannot impersonate arbitrary addresses.

---

## 5. Creating a Privacy Group

Privacy groups are classified by whether they can trigger base-ledger transactions via `PenteExternalCall` events. Testing groups use `externalCallsEnabled: "false"`; production groups must use `"true"`.

### 5.1 Creating a Test Group (No External Calls)

A test group is useful for validating private contract logic without affecting the public chain:

```bash
PALADIN_RPC="http://100.111.32.2:30848"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"pgroup_createGroup",
    "params":[
      {
        "domain":"pente",
        "name":"code-storage-test-group",
        "members":["signer-auto-wallet@paladin-core"],
        "properties":{},
        "configuration":{
          "externalCallsEnabled":"false"
        }
      }
    ]
  }' | jq .
```

`PenteExternalCall` events emitted inside this group will not be relayed to the base ledger.

**Use for:** testing `storeDataBatch` and `redeemCodeBatch` logic without affecting the public chain.

### 5.2 Creating a Production Group (External Calls Enabled)

This is the production configuration. The privacy group processes `PenteExternalCall` events and submits them as real base-ledger transactions.

```bash
PALADIN_RPC="http://100.111.32.2:30848"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"pgroup_createGroup",
    "params":[
      {
        "domain":"pente",
        "name":"code-storage-extcalls-production",
        "members":["signer-auto-wallet@paladin-core"],
        "properties":{},
        "configuration":{
          "externalCallsEnabled":"true"
        }
      }
    ]
  }' | jq .
```

The response returns a group ID (e.g., `0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef`). Record this — it is used as the `group` parameter in all subsequent privacy group API calls.

### 5.3 Critical: `externalCallsEnabled` Must Be a String

```json
"externalCallsEnabled": "true"     ← CORRECT (string)
"externalCallsEnabled": true       ← WRONG (boolean — causes request parsing issues)
```

Using a boolean `true` instead of the string `"true"` caused request parsing issues in production. This is the most common silent misconfiguration. If you pass a boolean, the group may be created but `PenteExternalCall` events will never be relayed to the base ledger.

### 5.4 Verify the Privacy Group

After creation, verify the group configuration with `pgroup_getGroupById`:

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_getGroupById\",
    \"params\":[\"pente\",\"$GROUP_ID\"]
  }" | jq .
```

**Verify the response includes:**

```json
"externalCallsEnabled": "true"
```

If this field is missing or shows `false`, the group will not relay external calls. Create a new group with the correct string `"true"`.

### 5.5 Record the Privacy Group Contract Address

The group response also contains the privacy group contract address (e.g., `0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`). This on-chain address is distinct from the group ID. **You will need this contract address** for public-chain authorization — it is the `msg.sender` that CodeManager sees when processing `PenteExternalCall` events from this group.

### 5.6 EVM Version

Pente privacy groups run `shanghai` EVM. The Pente EVM does not yet support later hard forks. All contracts deployed inside the group must be compiled with `--evm-version shanghai`.

---

## 6. Funding Strategy

Pente operations that emit `PenteExternalCall` events or perform state transitions require a **derived submitter** address to have gas funds on the base ledger. This is not the Paladin signer — it is a deterministic address computed by Paladin from the privacy group, signer identity, and transaction path.

### 6.1 When Funding Is Required

Gas is needed for any Pente operation that triggers a base-ledger transaction:
- Privacy group state transitions (deploy, finalize)
- `storeDataBatch` → emits `PenteExternalCall(CODE_MANAGER, validateUniqueIdsOrRevert(...))`
- `redeemCodeBatch` → emits `PenteExternalCall(CODE_MANAGER, recordRedemption(...))` per entry

Operations that are purely private (e.g., read-only `pgroup_call` queries) do not require gas on the derived submitter.

### 6.2 Multiple Derived Submitters

**Critical lesson from production:** different transaction paths may use different derived submitter addresses. In our deployment, we observed three distinct derived submitters:

| Transaction Path | Derived Submitter Address | When It Appears |
|-----------------|--------------------------|-----------------|
| Group initialization / deploy | `0x68b3b8a4facf8326c645170e005ea144d0246de4` | First contract deployment into the group |
| Deployment finalization | `0x937e2ac50b1f7a0e60da888a0cba52db29535508` | Transaction finalization after deploy |
| Store / external-call submission | `0xa907edf98de35db39cdbb42e1a6bdabe7e6c3c1b` | `storeDataBatch`, `redeemCodeBatch`, or any operation that emits `PenteExternalCall` |

All three addresses need independent funding. Funding one does not fund the others.

### 6.3 How to Identify the Derived Submitter

You cannot predict derived submitter addresses in advance. The workflow is:

1. Attempt the Pente operation (e.g., deploy, `storeDataBatch`)
2. The operation will stall. Check Paladin logs for the pattern:
   ```
   WARN  ProcessInFlightTransaction cannot submit transaction
         0xa907edf98de35db39cdbb42e1a6bdabe7e6c3c1b:0 ... insufficient funds
   ```
3. **The address before `:0` is the exact submitter that needs funding.** Copy it from the log.
4. Send native currency to that address from a funded account
5. The stuck transaction will automatically proceed and finalize

> **DO NOT GUESS which address to fund.** Read the Paladin logs and fund the exact address shown in `"cannot submit transaction … insufficient funds"`. Funding the wrong address is the most common deployment blocker.

### 6.4 Funding Amount

Send enough to cover gas for the expected operations. 0.1 native currency is typically sufficient for initial testing. Monitor the balance and top up as needed. Complex batch operations (large `storeDataBatch` calls) consume more gas.

### 6.5 Common Mistakes

| Mistake | Consequence |
|---------|-------------|
| Funded the Paladin signer address instead of the derived submitter | Transaction remains stuck; signer balance is irrelevant |
| Funded the privacy group contract address | Transaction remains stuck; group contract does not need gas |
| Funded one derived submitter but another path needs funding | Different operations stall at different derived submitters |
| Assumed the derived submitter from a deploy path is the same as the store path | They are often different addresses |

---

## 7. Deploying the Private Implementation Contract

### 7.1 Prerequisites

Before deploying `PrivateComboStorage` (or any implementation contract) into the privacy group:

1. **CodeManager is deployed** on the public chain and its proxy address is known
2. **Privacy group is created** with `externalCallsEnabled: "true"` and verified via `pgroup_getGroupById`
3. **`CODE_MANAGER` constant is set** in the `PrivateComboStorage` source to the CodeManager proxy address
4. **`ADMIN` and `AUTHORIZED` constants are set** to Paladin-signable addresses (see [Section 11](#11-signer--admin-strategy))

### 7.2 Compile for Shanghai EVM

PrivateComboStorage must be compiled with `--evm-version shanghai` because Pente runs Shanghai EVM:

```bash
python compile.py PrivateComboStorage.sol --evm-version shanghai
```

### 7.3 Use Creation Bytecode, Not Runtime Bytecode

> **WARNING:** A deployment failed in production because runtime bytecode was used instead of creation bytecode. Always use full creation/deployment bytecode.

When deploying via `pgroup_sendTransaction`, you must provide the **creation bytecode** (also called "deployment bytecode" or "init bytecode"), not the runtime bytecode.

- **Creation bytecode** = constructor + runtime code. The EVM executes the constructor and returns the runtime code.
- **Runtime bytecode** = what remains on-chain after deployment. Does NOT include the constructor.

The compiled output from `compile.py` includes both in the artifact JSON. Use the `bytecode` field (creation), not the `deployedBytecode` field (runtime).

### 7.4 Deploy the Implementation

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"
IDEMPLOY="code-storage-deploy-$(date +%s)"
BYTECODE="0xPASTE_CREATION_BYTECODE_HERE"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_sendTransaction\",
    \"params\":[
      {
        \"domain\":\"pente\",
        \"group\":\"$GROUP_ID\",
        \"from\":\"signer-auto-wallet\",
        \"bytecode\":\"$BYTECODE\",
        \"function\":{
          \"type\":\"constructor\",
          \"inputs\":[]
        },
        \"input\":[],
        \"idempotencyKey\":\"$IDEMPLOY\"
      }
    ]
  }" | tee /tmp/code-storage-deploy.json | jq .

DEPLOY_TXID="$(jq -r '.result // empty' /tmp/code-storage-deploy.json)"
echo "DEPLOY_TXID=$DEPLOY_TXID"
```

The response returns a transaction ID. The deployment is asynchronous — poll for the receipt to get the actual contract address.

### 7.5 Poll for the Implementation Address

> **WARNING:** Do not use a broad `jq` pattern like `.. | .contractAddress? // empty`. That can accidentally return the privacy group contract address instead of the deployed implementation address.

The correct source for the implementation address is `.result.domainReceipt.receipt.contractAddress`. Fall back to confirmed state entries with non-empty code if needed:

```bash
PALADIN_RPC="http://100.111.32.2:30848"
DEPLOY_TXID="$(jq -r '.result // empty' /tmp/code-storage-deploy.json)"
echo "DEPLOY_TXID=$DEPLOY_TXID"

IMPLEMENTATION_ADDR=""
for i in $(seq 1 120); do
  echo "== poll attempt $i =="

  curl -s "$PALADIN_RPC" \
    -H 'Content-Type: application/json' \
    --data "{
      \"jsonrpc\":\"2.0\",
      \"id\":1,
      \"method\":\"ptx_getTransactionReceiptFull\",
      \"params\":[\"$DEPLOY_TXID\"]
    }" | tee /tmp/code-storage-deploy-receipt.json | jq .

  IMPLEMENTATION_ADDR="$(
    jq -r '
      (
        .result.domainReceipt.receipt.contractAddress // empty
      ),
      (
        .result.states.confirmed[]
        | select(.data.code? != null and .data.code != "0x")
        | .data.address // empty
      )
    ' /tmp/code-storage-deploy-receipt.json | head -n1
  )"

  if [ -n "$IMPLEMENTATION_ADDR" ] && [ "$IMPLEMENTATION_ADDR" != "null" ]; then
    break
  fi

  FAILURE="$(jq -r '.result.failureMessage // empty' /tmp/code-storage-deploy-receipt.json)"
  if [ -n "$FAILURE" ] && [ "$FAILURE" != "null" ]; then
    echo "DEPLOY FAILED: $FAILURE"
    break
  fi

  sleep 2
done

echo "IMPLEMENTATION_ADDR=$IMPLEMENTATION_ADDR"
```

Example result: `IMPLEMENTATION_ADDR=0xd10b4b8b9afe975c76e87dfa44ef73d820584959`

### 7.6 Funding During Deployment

If the deployment stalls, check Paladin logs for `insufficient funds` errors. The derived submitter for the deploy path may differ from the one used for later operations. Fund the exact address shown in the log (see [Section 6](#6-funding-strategy)).

---

## 8. Deploying an Upgradeable Proxy inside Pente

For upgradeable private contracts, deploy an OpenZeppelin 5.2 `TransparentUpgradeableProxy` inside the privacy group pointing to the implementation contract from [Section 7](#7-deploying-the-private-implementation-contract).

### 8.1 OZ 5.2 TransparentUpgradeableProxy Constructor

The OpenZeppelin 5.2 `TransparentUpgradeableProxy` constructor signature is:

```solidity
constructor(address _logic, address initialOwner, bytes memory _data)
```

Key behavior:
- **`_logic`** — the implementation contract address (from Section 7)
- **`initialOwner`** — becomes the `owner()` of the auto-deployed `ProxyAdmin`. **Must be a Paladin-signable address** if upgrades will be performed through Paladin.
- **`_data`** — initializer calldata to delegatecall on the implementation, or `0x` if no initialization is needed

> **OZ 5.2 auto-deploys its own ProxyAdmin.** You do NOT deploy a separate ProxyAdmin contract. The proxy constructor creates one internally and sets `initialOwner` as its owner. This is different from OZ 4.x where you deployed ProxyAdmin separately.

### 8.2 Critical: Do Not Confuse the Group Contract Address with the Implementation Address

> **WARNING:** A proxy deployment failed in production because the privacy group contract address (`0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`) was mistakenly passed as `_logic`. The privacy group contract address is NOT the implementation address. The implementation address must be the actual deployed private contract address from [Section 7](#7-deploying-the-private-implementation-contract).

### 8.3 Deploy the Proxy

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"
IDDEPLOY="oz52-transparent-proxy-$(date +%s)"

PROXY_BYTECODE="0xPASTE_TRANSPARENT_PROXY_CREATION_BYTECODE"
IMPLEMENTATION_ADDR="0xd10b4b8b9afe975c76e87dfa44ef73d820584959"
INITIAL_OWNER="0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb"
INIT_DATA="0x"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_sendTransaction\",
    \"params\":[
      {
        \"domain\":\"pente\",
        \"group\":\"$GROUP_ID\",
        \"from\":\"signer-auto-wallet\",
        \"bytecode\":\"$PROXY_BYTECODE\",
        \"function\":{
          \"type\":\"constructor\",
          \"inputs\":[
            {\"name\":\"_logic\",\"type\":\"address\"},
            {\"name\":\"initialOwner\",\"type\":\"address\"},
            {\"name\":\"_data\",\"type\":\"bytes\"}
          ]
        },
        \"input\":[
          \"$IMPLEMENTATION_ADDR\",
          \"$INITIAL_OWNER\",
          \"$INIT_DATA\"
        ],
        \"idempotencyKey\":\"$IDDEPLOY\"
      }
    ]
  }" | tee /tmp/oz52-transparent-proxy-deploy.json | jq .
```

**Parameter notes:**
- `IMPLEMENTATION_ADDR` — **dynamically discovered** from the implementation deploy receipt (Section 7.5). Use the *actual deployed implementation address*, not the group contract address.
- `INITIAL_OWNER` — **must be a Paladin-signable address** (e.g., `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb` — the resolved signer from Section 4.2). If set to an external EOA not in Paladin's keystore, proxy upgrades through Paladin will fail (see [Section 9.5](#95-common-failure-wrong-proxyadmin-owner)).
- `INIT_DATA` — `0x` if no initializer is needed, or an ABI-encoded call to an `initialize()` function.

### 8.4 Poll for the Proxy Address

```bash
PALADIN_RPC="http://100.111.32.2:30848"
DEPLOY_TXID="$(jq -r '.result // empty' /tmp/oz52-transparent-proxy-deploy.json)"
echo "DEPLOY_TXID=$DEPLOY_TXID"

PROXY_ADDR=""
for i in $(seq 1 120); do
  echo "== poll attempt $i =="

  curl -s "$PALADIN_RPC" \
    -H 'Content-Type: application/json' \
    --data "{
      \"jsonrpc\":\"2.0\",
      \"id\":1,
      \"method\":\"ptx_getTransactionReceiptFull\",
      \"params\":[\"$DEPLOY_TXID\"]
    }" | tee /tmp/oz52-transparent-proxy-deploy-receipt.json | jq .

  PROXY_ADDR="$(
    jq -r '
      (
        .result.domainReceipt.receipt.contractAddress // empty
      ),
      (
        .result.states.confirmed[]
        | select(.data.code? != null and .data.code != "0x")
        | .data.address // empty
      )
    ' /tmp/oz52-transparent-proxy-deploy-receipt.json | head -n1
  )"

  if [ -n "$PROXY_ADDR" ] && [ "$PROXY_ADDR" != "null" ]; then
    break
  fi

  FAILURE="$(jq -r '.result.failureMessage // empty' /tmp/oz52-transparent-proxy-deploy-receipt.json)"
  if [ -n "$FAILURE" ] && [ "$FAILURE" != "null" ]; then
    echo "PROXY DEPLOY FAILED: $FAILURE"
    break
  fi

  sleep 2
done

echo "PROXY_ADDR=$PROXY_ADDR"
```

The `PROXY_ADDR` is the address to use as `to` in all subsequent `pgroup_sendTransaction` and `pgroup_call` requests for the private contract.

---

## 9. Proxy Admin Verification & Upgrades

### 9.1 Identifying the ProxyAdmin Address

OZ 5.2's `TransparentUpgradeableProxy` auto-deploys a `ProxyAdmin` internally. The ProxyAdmin address is not passed as a constructor argument — it is created during proxy deployment.

To find the ProxyAdmin address, inspect the proxy deployment receipt state entries. Look for confirmed state entries with non-empty code that are *not* the proxy address itself. In our deployment, the ProxyAdmin was discovered at:

```
0x6c7ea1dc87b0c778b2675735c98acfba94d3e042
```

Alternatively, the ProxyAdmin address can be extracted by reading the ERC-1967 admin slot from the proxy storage, though in the Pente environment this may require receipt/state inspection rather than standard storage reads.

### 9.2 Verify ProxyAdmin Ownership

After identifying the candidate ProxyAdmin address, call `owner()` on it to confirm the owner matches the `initialOwner` you passed during proxy deployment:

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"
PROXY_ADMIN_ADDR="0x6c7ea1dc87b0c778b2675735c98acfba94d3e042"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_call\",
    \"params\":[
      {
        \"domain\":\"pente\",
        \"group\":\"$GROUP_ID\",
        \"from\":\"signer-auto-wallet\",
        \"to\":\"$PROXY_ADMIN_ADDR\",
        \"function\":{
          \"type\":\"function\",
          \"name\":\"owner\",
          \"stateMutability\":\"view\",
          \"inputs\":[],
          \"outputs\":[
            {\"name\":\"\",\"type\":\"address\"}
          ]
        },
        \"input\":[]
      }
    ]
  }" | jq .
```

**Expected:** Returns the `initialOwner` address you passed to the proxy constructor (e.g., `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`).

### 9.3 Performing a Proxy Upgrade

To upgrade the implementation, deploy a new implementation contract (Section 7), then call `upgradeAndCall` on the ProxyAdmin:

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"
PROXY_ADDR="0x17ded097088321d457f603637b28ded0fcea5e26"
PROXY_ADMIN_ADDR="0x6c7ea1dc87b0c778b2675735c98acfba94d3e042"
NEW_IMPLEMENTATION_ADDR="0xd10b4b8b9afe975c76e87dfa44ef73d820584959"
UPGRADE_DATA="0x"
IDUPGRADE="proxy-upgrade-$(date +%s)"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_sendTransaction\",
    \"params\":[
      {
        \"domain\":\"pente\",
        \"group\":\"$GROUP_ID\",
        \"from\":\"signer-auto-wallet\",
        \"to\":\"$PROXY_ADMIN_ADDR\",
        \"function\":{
          \"type\":\"function\",
          \"name\":\"upgradeAndCall\",
          \"stateMutability\":\"payable\",
          \"inputs\":[
            {\"name\":\"proxy\",\"type\":\"address\"},
            {\"name\":\"implementation\",\"type\":\"address\"},
            {\"name\":\"data\",\"type\":\"bytes\"}
          ],
          \"outputs\":[]
        },
        \"input\":[
          \"$PROXY_ADDR\",
          \"$NEW_IMPLEMENTATION_ADDR\",
          \"$UPGRADE_DATA\"
        ],
        \"idempotencyKey\":\"$IDUPGRADE\"
      }
    ]
  }" | tee /tmp/proxy-upgrade.json | jq .
```

**Parameter notes:**
- `PROXY_ADDR` — the proxy address (from Section 8.4), **not** the ProxyAdmin address
- `PROXY_ADMIN_ADDR` — the auto-deployed ProxyAdmin (target of the `upgradeAndCall` call)
- `NEW_IMPLEMENTATION_ADDR` — **dynamically discovered** from the new implementation deploy receipt
- `UPGRADE_DATA` — `0x` for no re-initialization, or ABI-encoded initializer calldata

### 9.4 Poll for Upgrade Completion

```bash
PALADIN_RPC="http://100.111.32.2:30848"
UPGRADE_TXID="$(jq -r '.result // empty' /tmp/proxy-upgrade.json)"
echo "UPGRADE_TXID=$UPGRADE_TXID"

for i in $(seq 1 120); do
  echo "== poll attempt $i =="

  curl -s "$PALADIN_RPC" \
    -H 'Content-Type: application/json' \
    --data "{
      \"jsonrpc\":\"2.0\",
      \"id\":1,
      \"method\":\"ptx_getTransactionReceiptFull\",
      \"params\":[\"$UPGRADE_TXID\"]
    }" | tee /tmp/proxy-upgrade-receipt.json | jq .

  SUCCESS="$(jq -r '.result.success // empty' /tmp/proxy-upgrade-receipt.json)"
  FAILURE="$(jq -r '.result.failureMessage // empty' /tmp/proxy-upgrade-receipt.json)"

  if [ "$SUCCESS" = "true" ]; then
    echo "UPGRADE SUCCEEDED"
    break
  fi

  if [ -n "$FAILURE" ] && [ "$FAILURE" != "null" ]; then
    echo "UPGRADE FAILED: $FAILURE"
    break
  fi

  sleep 2
done
```

### 9.5 Common Failure: Wrong ProxyAdmin Owner

> **WARNING — Production failure observed:** A proxy upgrade using `ProxyAdmin.upgradeAndCall` failed with an `OwnableUnauthorizedAccount`-style error. The caller inside Paladin was `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`, but `ProxyAdmin.owner()` returned `0x2B7361056b31D2bf201E6764e7825fd31c0D223A` — an external address that Paladin was not signing as.

**Root cause:** The proxy had been deployed with `initialOwner` set to an external EOA whose private key was not in Paladin's keystore. Paladin could not produce that address as `msg.sender`, so the `onlyOwner` check on ProxyAdmin failed.

**Fix:** When deploying a proxy that will be upgraded through Paladin, set `initialOwner` to the resolved Paladin signer address (e.g., `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`). Verify by calling `owner()` on the ProxyAdmin immediately after proxy deployment.

**If the ProxyAdmin owner is already wrong:** The owner cannot be changed without the current owner's key. If that key is not accessible through Paladin, the proxy cannot be upgraded through Paladin. Deploy a new proxy with the correct `initialOwner`.

---

## 10. Verifying the Private Contract

After deployment (direct or proxied), verify the contract is working correctly before proceeding to storage and redemption.

### 10.1 Check CODE_MANAGER()

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"
CONTRACT_ADDR="<PRIVATE_CONTRACT_OR_PROXY_ADDRESS>"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_call\",
    \"params\":[
      {
        \"domain\":\"pente\",
        \"group\":\"$GROUP_ID\",
        \"from\":\"signer-auto-wallet\",
        \"to\":\"$CONTRACT_ADDR\",
        \"function\":{
          \"type\":\"function\",
          \"name\":\"CODE_MANAGER\",
          \"stateMutability\":\"view\",
          \"inputs\":[],
          \"outputs\":[
            {\"name\":\"\",\"type\":\"address\"}
          ]
        },
        \"input\":[]
      }
    ]
  }" | jq .
```

**Expected:** Returns the CodeManager proxy address that was hardcoded into the contract before compilation.

**If it returns the placeholder `0x...c0DE`:** You compiled `PrivateComboStorage` without updating the `CODE_MANAGER` constant. Recompile and redeploy via upgrade.

### 10.2 Check ADMIN() and AUTHORIZED()

Verify the access control constants match your intended addresses. Use the same `pgroup_call` pattern as above, substituting `ADMIN` or `AUTHORIZED` for the function name:

```bash
# Check ADMIN — same pgroup_call pattern, change function name to "ADMIN"
# Check AUTHORIZED — same pgroup_call pattern, change function name to "AUTHORIZED"
```

Both should return Paladin-signable addresses (see [Section 11](#11-signer--admin-strategy)).

### 10.3 Verification Checklist

- [ ] `CODE_MANAGER()` returns the correct CodeManager proxy address
- [ ] `ADMIN()` returns a Paladin-signable admin address
- [ ] `AUTHORIZED()` returns the meta-tx processing service address (Paladin-signable)
- [ ] Privacy group has `externalCallsEnabled: "true"` (string) — verified via `pgroup_getGroupById`
- [ ] If using a proxy: `ProxyAdmin.owner()` returns a Paladin-signable address
- [ ] Derived submitter(s) funded for each transaction path

---

## 11. Signer & Admin Strategy

### 11.1 Paladin Does Not Sign as Arbitrary External EOAs

Paladin resolves configured signer identities (e.g., `signer-auto-wallet`) into Paladin-managed addresses. It does not have access to arbitrary external private keys unless those keys are explicitly imported into its keystore.

Observed Paladin-derived signer addresses:
- `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`
- `0x937e2ac50b1f7a0e60da888a0cba52db29535508`
- `0xa907edf98de35db39cdbb42e1a6bdabe7e6c3c1b`

**Rule:** If a private contract uses `msg.sender`-based authorization (e.g., `require(msg.sender == ADMIN || msg.sender == AUTHORIZED)`), both `ADMIN` and `AUTHORIZED` must be addresses that Paladin can produce as `msg.sender` — not unrelated external EOAs.

> `ADMIN` is the administrative authority (configuration, whitelisting, manager assignment). `AUTHORIZED` is the **meta-transaction processing service** — the identity responsible for receiving forwarded store/redeem requests, recovering the original caller's intent, and executing the actual `storeDataBatch` / `redeemCodeBatch` calls within the privacy group. The Paladin signer provides the `msg.sender` authority for both roles. In a single-node deployment, `ADMIN` and `AUTHORIZED` may resolve to the same Paladin signer address, but they represent distinct operational roles.

### 11.2 Hard-Coded Constants vs. Storage-Based Auth

The current `PrivateComboStorage` uses compile-time constant addresses for access control:

| Model | `PrivateComboStorage` (constants) | Storage-based auth (alternative) |
|-------|-----------------------------------|----------------------------------|
| **Flexibility** | Cannot change after deployment. Fixed at compile time. | Can be updated via `authorize()` / `transferAdmin()` functions. |
| **Upgrade path** | Requires new implementation + proxy upgrade to change roles. | Role changes are a simple transaction. |
| **Paladin compatibility** | `ADMIN` (admin) and `AUTHORIZED` (meta-tx processor) must be set to Paladin-signable addresses before compilation. If wrong, requires full redeployment cycle. | Roles can be reassigned to any address at runtime. |
| **Security** | Simpler — no runtime mutation surface. | More surface area — role management functions must be access-controlled. |
| **Recommended for** | Stable deployments where roles are known in advance. | Environments with dynamic API-driven authorization needs. |

**Consequence:** If the `ADMIN` or `AUTHORIZED` constant is set to an external address whose private key is not in Paladin's keystore:
- That address is effectively unusable for privileged private-group actions
- It may exist as an on-chain value, but Paladin cannot act as that address
- A new implementation must be compiled with the correct addresses and upgraded via the proxy

### 11.3 External Admin Key Not in Paladin's Keystore

> **Production lesson:** An external admin address that is not signable by Paladin is effectively unusable for privileged private-group actions. It may exist as a stored owner value, but Paladin cannot submit transactions from that address unless the key is configured in Paladin or a supported external signing path is integrated.

**Rule:** For any admin flow that must operate through Paladin, the admin address must be a Paladin-signable address.

### 11.4 ProxyAdmin Owner Must Also Be Paladin-Signable

The same rule applies to the `initialOwner` passed to the `TransparentUpgradeableProxy` constructor (see [Section 9.5](#95-common-failure-wrong-proxyadmin-owner)). If the ProxyAdmin owner is not a Paladin-signable address, proxy upgrades through Paladin will fail with an `OwnableUnauthorizedAccount` error.

### 11.5 Resolving Your Paladin Signer Address

Always resolve the signer address before configuring contracts:

```bash
PALADIN_RPC="http://100.111.32.2:30848"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"ptx_resolveVerifier",
    "params":[
      "signer-auto-wallet@paladin-core",
      "pente",
      "secp256k1"
    ]
  }' | jq -r '.result'
```

Use the returned address as `ADMIN` and `initialOwner`. Use it as `AUTHORIZED` when the meta-transaction processing service operates through the same Paladin node. In multi-node deployments, `AUTHORIZED` may be a different Paladin signer managing the store/redeem forwarding service.

---

## 12. Authorization & Whitelisting Strategy

### 12.1 Authorize the Privacy Group on CodeManager

The privacy group must be authorized on CodeManager before its `PenteExternalCall` events will be accepted. Without authorization, calls to `recordRedemption` and `validateUniqueIdsOrRevert` from the privacy group will revert with `"Caller is not an authorized privacy group"`.

> **Critical lesson from production:** The address that must be authorized is the **privacy group contract address** — not the Paladin signer, not the derived submitter. In our deployment, the privacy group contract address was `0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`. This is the `msg.sender` that CodeManager sees when processing `PenteExternalCall` events. Earlier attempts that authorized only the derived submitter address were insufficient.

```javascript
// Single voter — takes effect immediately
// privacyGroupAddress = the GROUP CONTRACT ADDRESS (e.g., 0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4)
// NOT the derived submitter, NOT the Paladin signer
await codeManager.voteToAuthorizePrivacyGroup(privacyGroupAddress);
```

For multi-voter governance:
```javascript
// Requires 2/3 supermajority
await codeManager.connect(voter1).voteToAuthorizePrivacyGroup(privacyGroupAddress);
await codeManager.connect(voter2).voteToAuthorizePrivacyGroup(privacyGroupAddress);
// If 2/3 reached, authorization takes effect
```

### 12.2 How to Obtain the Privacy Group Contract Address

The privacy group contract address is returned in the `pgroup_getGroupById` response. It is distinct from the group ID:

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_getGroupById\",
    \"params\":[\"pente\",\"$GROUP_ID\"]
  }" | jq '.result.contractAddress'
```

Example: `0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`

### 12.3 Access Control on PrivateComboStorage

`PrivateComboStorage` uses compile-time constant addresses for access control:

- **`ADMIN`** — The administrative authority. Controls configuration functions (`setContractIdentifierWhitelist`, `setUniqueIdManagersBatch`, `setUniqueIdActiveBatch`). Also permitted to call `storeDataBatch` and `redeemCodeBatch`.
- **`AUTHORIZED`** — The meta-transaction processing service. This is the identity responsible for processing and recovering forwarded store/redeem requests on behalf of external callers. It calls `storeDataBatch` and `redeemCodeBatch` within the privacy group, with the Paladin signer providing the `msg.sender` authority for the actual transactions.

Both are compile-time constants set in the contract source before compilation and cannot be changed at runtime — changing them requires deploying a new implementation and upgrading the proxy.

There are no `authorize()`, `deauthorize()`, or `transferAdmin()` functions. All configuration updates are performed via contract upgrade.

Both `ADMIN` and `AUTHORIZED` must be Paladin-signable addresses (see [Section 11](#11-signer--admin-strategy)).

### 12.4 Whitelist Contract Identifiers on PrivateComboStorage

Before storing codes, the contract-identifier prefix must be whitelisted on PrivateComboStorage. The contract identifier is deterministic:
```
contractIdentifier = toHexString(keccak256(codeManagerAddress, giftContractAddress, chainId))
```

Whitelist it via `pgroup_sendTransaction`:

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"
CONTRACT_ADDR="<PRIVATE_CONTRACT_OR_PROXY_ADDRESS>"
IDWHITELIST="whitelist-identifier-$(date +%s)"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_sendTransaction\",
    \"params\":[
      {
        \"domain\":\"pente\",
        \"group\":\"$GROUP_ID\",
        \"from\":\"signer-auto-wallet\",
        \"to\":\"$CONTRACT_ADDR\",
        \"function\":{
          \"type\":\"function\",
          \"name\":\"setContractIdentifierWhitelist\",
          \"stateMutability\":\"nonpayable\",
          \"inputs\":[
            {\"name\":\"identifiers\",\"type\":\"string[]\"},
            {\"name\":\"statuses\",\"type\":\"bool[]\"}
          ],
          \"outputs\":[]
        },
        \"input\":[
          [\"<CONTRACT_IDENTIFIER>\"],
          [true]
        ],
        \"idempotencyKey\":\"$IDWHITELIST\"
      }
    ]
  }" | jq .
```

Only `ADMIN` can call this function. Codes with non-whitelisted contract identifiers will be rejected by `storeDataBatch` with a `StoreFailed` event.

### 12.5 Register UIDs on CodeManager

Before storing codes in the privacy group, the UID range must exist on CodeManager. Registration is permissionless — anyone can call it as long as they pay the registration fee.

```javascript
const quantity = 10;
const fee = await codeManager.registrationFee();
const totalFee = fee * BigInt(quantity);

await codeManager.registerUniqueIds(
    giftContractAddress,
    chainId,
    quantity,
    { value: totalFee }
);
```

This creates deterministic UIDs: `<contractIdentifier>-1`, `<contractIdentifier>-2`, ..., `<contractIdentifier>-N` where:
```
contractIdentifier = toHexString(keccak256(codeManagerAddress, giftContractAddress, chainId))
```

The gift contract can also register UIDs atomically at purchase time via its `buy()` function, which calls `registerUniqueIds` internally and verifies counter sync.

### 12.6 Authorization Order

The complete authorization sequence:

```
1.  Deploy CodeManager + Gift Contract on public chain
2.  Create ext-calls privacy group (pgroup_createGroup with "externalCallsEnabled": "true")
3.  Verify group config (pgroup_getGroupById) and record group contract address
4.  Compile PrivateComboStorage with correct CODE_MANAGER, ADMIN, AUTHORIZED constants
      (ADMIN and AUTHORIZED must be Paladin-signable addresses)
5.  Deploy implementation in privacy group (pgroup_sendTransaction)
6.  Poll receipt for implementation address (ptx_getTransactionReceiptFull)
7.  Deploy proxy with _logic = implementation address, initialOwner = Paladin signer
8.  Poll receipt for proxy address
9.  Verify ProxyAdmin.owner() matches Paladin signer
10. Verify CODE_MANAGER(), ADMIN(), AUTHORIZED() on proxy
11. Fund derived submitter(s) as needed (check Paladin logs)
12. Authorize privacy group CONTRACT ADDRESS on CodeManager:
      voteToAuthorizePrivacyGroup(groupContractAddress)
13. Whitelist contract identifier on PrivateComboStorage:
      setContractIdentifierWhitelist([contractId], [true])
14. Register UIDs on CodeManager (or let buy() do it)
15. Configure per-UID options (optional):
      setUniqueIdManagersBatch / setUniqueIdActiveBatch with mirrorStatuses
16. Store codes → storeDataBatch
17. Redeem codes → redeemCodeBatch
```

---

## 13. Store Flow — storeDataBatch

### 13.1 Off-Chain Code Generation

Codes are generated off-chain. No cleartext ever touches any chain:

```
For each code:
  1. Generate random code string (e.g., "HappyBirthday2026")
  2. Compute codeHash = keccak256(abi.encodePacked(code))
     NOTE: The PIN is NOT part of the hash — PINs are assigned by the contract.
  3. Record: { uniqueId, codeHash: 0x... }
```

The contract assigns a PIN to each code during `storeDataBatch`. The PIN is returned to the caller and shared with the end user (e.g., printed on the card). The full code is the secret. Both PIN and code are needed to redeem.

### 13.2 Calling storeDataBatch

The function now accepts a `StoreBatchRequest` struct containing all per-entry arrays. This includes `mirrorStatuses` to control whether each UID's active state is mirrored publicly on CodeManager, and `uidManagers` to optionally assign per-UID manager addresses.

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"
CONTRACT_ADDR="<PRIVATE_CONTRACT_OR_PROXY_ADDRESS>"
IDSTORE="store-batch-$(date +%s)"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_sendTransaction\",
    \"params\":[
      {
        \"domain\":\"pente\",
        \"group\":\"$GROUP_ID\",
        \"from\":\"signer-auto-wallet\",
        \"to\":\"$CONTRACT_ADDR\",
        \"function\":{
          \"type\":\"function\",
          \"name\":\"storeDataBatch\",
          \"stateMutability\":\"nonpayable\",
          \"inputs\":[{
            \"name\":\"request\",
            \"type\":\"tuple\",
            \"components\":[
              {\"name\":\"uniqueIds\",\"type\":\"string[]\"},
              {\"name\":\"codeHashes\",\"type\":\"bytes32[]\"},
              {\"name\":\"pinLengths\",\"type\":\"uint256[]\"},
              {\"name\":\"useSpecialChars\",\"type\":\"bool[]\"},
              {\"name\":\"entropies\",\"type\":\"bytes32[]\"},
              {\"name\":\"uidManagers\",\"type\":\"address[]\"},
              {\"name\":\"mirrorStatuses\",\"type\":\"bool[]\"}]
          }],
          \"outputs\":[{\"name\":\"\",\"type\":\"string[]\"}]
        },
        \"input\":[
          [
            [\"<UNIQUE_ID_1>\", \"<UNIQUE_ID_2>\"],
            [\"0xabc123...\", \"0xdef456...\"],
            [3, 4],
            [false, true],
            [\"0x<RANDOM_32_BYTES_1>\", \"0x<RANDOM_32_BYTES_2>\"],
            [\"0x<UID_MANAGER_1_OR_ZERO>\", \"0x<UID_MANAGER_2_OR_ZERO>\"],
            [true, false]
          ]
        ],
        \"idempotencyKey\":\"$IDSTORE\"
      }
    ]
  }" | jq .
```

**StoreBatchRequest fields:**
- `uniqueIds` — registered UID strings (must exist on CodeManager)
- `codeHashes` — keccak256(code) hashes computed off-chain
- `pinLengths` — PIN character length per entry (1-8)
- `useSpecialChars` — whether to include special characters in the PIN
- `entropies` — random 32-byte seeds for PIN derivation
- `uidManagers` — optional per-UID manager addresses (zero = no manager)
- `mirrorStatuses` — per-UID public mirror control:
  - `true` → active-state changes mirror to CodeManager publicly
  - `false` → active state stays private; CodeManager returns DEFAULT_ACTIVE_STATE

The function returns `string[] assignedPins` — the contract-assigned PIN for each entry. Store these PINs alongside the codes in your off-chain database.

### 13.3 What Happens Inside

`storeDataBatch` executes three phases atomically:

1. **Phase 1 — Local preflight:** Validates arrays, checks for empty values, invalid UID format, non-whitelisted contract identifiers, zero hashes, invalid per-entry PIN lengths, zero entropies, duplicate UIDs, and UIDs already stored in private state.

2. **Phase 2 — Public registry validation:** Emits `PenteExternalCall` → `CodeManager.validateUniqueIdsOrRevert(uniqueIds)`. If any uniqueId is not registered on CodeManager, the entire Pente transition reverts.

3. **Phase 3 — Assign PINs and store entries:** For each entry, derives a PIN from that entry's supplied entropy, PIN length, and charset choice. If a collision occurs (same codeHash at derived PIN, or slot is full at MAX_PER_PIN=32), the entry seed is re-chained via `keccak256(seed)` until an open slot is found — no revert, no information leakage. Stores `(pin, codeHash) → CodeMetadata{ uniqueId, exists: true }` and emits `DataStoredStatus(uniqueId, assignedPin)` per entry.

4. **Phase 4 — Per-UID configuration:** Records per-UID managers (if provided) and mirror preferences. UIDs with `mirrorStatuses[i] == false` have their `isUniqueIdStatusMirrorDisabled` flag set — future active-state changes via `setUniqueIdActiveBatch()` will update private execution state but will not propagate to CodeManager. Emits `UniqueIdManagerUpdated` and `UniqueIdStatusMirrorUpdated` events as applicable.

### 13.4 Failure Modes

| Failure | Cause | Fix |
|---------|-------|-----|
| `"Array length mismatch"` | `uniqueIds`, `codeHashes`, `pinLengths`, `useSpecialChars`, `entropies`, `uidManagers`, and `mirrorStatuses` arrays have different lengths | Ensure all per-entry arrays in the StoreBatchRequest are the same length |
| `"Contract identifier not whitelisted"` | The UID prefix is not approved in PrivateComboStorage | Whitelist the contract identifier first |
| `"Empty uniqueId"` | One of the uniqueIds is an empty string | Check your UID generation |
| `"Zero code hash"` | A codeHash is `bytes32(0)` | Check your hash computation |
| `"PIN length must be 1-8"` | An entry has an invalid `pinLengths[i]` | Use a value between 1 and 8 for each entry |
| `"Zero entropy"` | An entry entropy is `bytes32(0)` | Supply random 32 bytes per entry |
| `"Duplicate uniqueId in batch"` | The same UID appears more than once in a store batch | Deduplicate before calling |
| `"UniqueId already has manager"` | The UID was already initialized in private storage | Do not re-store the same UID |
| `"PIN space exhausted"` | 100 retries failed to find an open PIN slot | Increase PIN length or reduce stored codes |
| `"Invalid uniqueId in batch"` | The uniqueId is not registered on CodeManager | Register UIDs first via `registerUniqueIds` |
| `"Caller is not an authorized privacy group"` | The privacy group is not authorized on CodeManager | Call `voteToAuthorizePrivacyGroup` |
| `"Caller is not authorized"` | The `from` identity is not `ADMIN` or `AUTHORIZED` | Update constants and redeploy via upgrade |
| `insufficient funds for gas` | The derived submitter has no gas | Fund the address shown in the error |

---

## 14. Redeem Flow — redeemCodeBatch + External Call

### 14.1 End-to-End Data Flow

```
User enters PIN + code
         │
         ▼
Client computes codeHash = keccak256(abi.encodePacked(code))
  NOTE: The PIN is NOT part of the hash.
         │
         ▼
Client calls Paladin RPC → PrivateComboStorage.redeemCodeBatch(pins[], codeHashes[], redeemers[])
         │
         ▼
PrivateComboStorage (inside Pente privacy group), for each entry:
  1. Looks up pinToHash[pin][codeHash] → CodeMetadata
  2. Requires: exists == true
  3. Reads uniqueId from the metadata
  4. Checks private UID execution state: active and not already redeemed
     (UIDs marked inactive or redeemed in private state are skipped —
      even if CodeManager's public mirror shows active)
  5. Deletes the hash entry (code is consumed)
  6. Decrements pinSlotCount[pin]
  7. Marks the UID redeemed in private state
  8. Emits RedeemStatus(uniqueId, redeemer)
  9. Emits PenteExternalCall(CODE_MANAGER,
       abi.encodeWithSignature("recordRedemption(string,address)", uniqueId, redeemer))
         │
         ▼
Pente processes the transition, sees PenteExternalCall(s):
  → Submits base-ledger tx(es) to CODE_MANAGER from the derived submitter
         │
         ▼
CodeManager.recordRedemption(uniqueId, redeemer) [onlyAuthorizedPrivacyGroup]:
  1. Calls getUniqueIdDetails(uniqueId) → resolves to gift contract
  2. Verifies the public UID state is still active
     (if mirror was disabled, this defaults to active)
  3. Marks the UID terminally redeemed in public state (REDEEMED enum)
  4. Emits UniqueIdRedeemed(uniqueId)
  5. Calls giftContract.recordRedemption via try/catch:
     • Success → emits RedemptionRouted(uniqueId, giftContract, redeemer)
     • Failure → emits RedemptionFailed(uniqueId, giftContract, redeemer, reason)
         │
         ▼
Gift Contract.recordRedemption(uniqueId, redeemer) [onlyCodeManager]:
  1. Parses uniqueId → tokenId
  2. Requires: valid, minted, in vault
  3. Transfers NFT from vault (contract) to redeemer
  4. Increments totalRedeems
  5. Emits CardRedeemed(tokenId, uniqueId, redeemer)
  6. If any require fails → revert → caught by CodeManager
     → RedemptionFailed event emitted
     → UID remains REDEEMED at all layers
     → private state (code-hash deletion) is preserved
     → admin resolves gift-contract side effect manually
```

### 14.2 Calling redeemCodeBatch

```bash
PALADIN_RPC="http://100.111.32.2:30848"
GROUP_ID="0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef"
CONTRACT_ADDR="<PRIVATE_CONTRACT_OR_PROXY_ADDRESS>"
IDREDEEM="redeem-batch-$(date +%s)"

curl -s "$PALADIN_RPC" \
  -H 'Content-Type: application/json' \
  --data "{
    \"jsonrpc\":\"2.0\",
    \"id\":1,
    \"method\":\"pgroup_sendTransaction\",
    \"params\":[
      {
        \"domain\":\"pente\",
        \"group\":\"$GROUP_ID\",
        \"from\":\"signer-auto-wallet\",
        \"to\":\"$CONTRACT_ADDR\",
        \"function\":{
          \"type\":\"function\",
          \"name\":\"redeemCodeBatch\",
          \"stateMutability\":\"nonpayable\",
          \"inputs\":[
            {\"name\":\"pins\",\"type\":\"string[]\"},
            {\"name\":\"codeHashes\",\"type\":\"bytes32[]\"},
            {\"name\":\"redeemers\",\"type\":\"address[]\"}],
          \"outputs\":[]
        },
        \"input\":[
          [\"<PIN_1>\", \"<PIN_2>\"],
          [\"<CODE_HASH_1>\", \"<CODE_HASH_2>\"],
          [\"<REDEEMER_1>\", \"<REDEEMER_2>\"]
        ],
        \"idempotencyKey\":\"$IDREDEEM\"
      }
    ]
  }" | jq .
```

### 14.3 Atomicity Guarantee

The key property: **CodeManager marks the UID as REDEEMED before calling the gift contract, and wraps the gift contract call in try/catch.** This means:
- If the gift contract succeeds: normal flow, NFT transferred, all state consistent
- If the gift contract reverts: CodeManager emits `RedemptionFailed` but does NOT propagate the revert
- The Pente transition always succeeds for locally-validated entries
- Private state changes (code-hash deletion, REDEEMED marking) are preserved
- The UID is terminally REDEEMED at every layer (private, CodeManager, gift contract may be inconsistent)
- Admin should monitor `RedemptionFailed` events and resolve the gift-contract side effect manually (e.g., manual NFT transfer)

**Why this is safe:** PrivateComboStorage already validates active/frozen/redeemed state locally before emitting the external call. The only scenario where the gift contract can revert is a bug, misconfiguration, or race condition on the gift contract itself — not a state the private contract could have prevented. By catching the revert, CodeManager ensures that a faulty gift contract never poisons the Pente privacy group's state.

### 14.4 Redemption Recovery — syncRedemption

When CodeManager's try/catch catches a gift contract revert, the UID is terminally REDEEMED at every layer but the gift contract never processed its side effect (e.g., the NFT was never transferred from the vault). The gift contract exposes a dedicated admin recovery function for this scenario:

```solidity
function syncRedemption(string calldata uniqueId, address redeemer) external onlyOwner
```

**Safety checks:**
- Only the contract owner can call it
- Verifies `isUniqueIdRedeemed(uniqueId)` on CodeManager — prevents unauthorized transfers
- Verifies the NFT is still in the vault (not already transferred)

**Recovery flow:**
1. Admin monitors for `RedemptionFailed` events on CodeManager
2. Identifies the `uniqueId` and `redeemer` from the event data
3. Diagnoses and fixes the root cause if applicable (e.g., contract bug, state issue)
4. Calls `syncRedemption(uniqueId, redeemer)` on the gift contract
5. NFT transfers from vault to redeemer
6. `RedemptionSynced(tokenId, uniqueId, redeemer)` event is emitted

**Important:** `syncRedemption` emits `RedemptionSynced` (not `CardRedeemed`) so indexers and monitoring can distinguish normal redemptions from admin-recovered ones.

```bash
# Example: recover a failed redemption
cast send <GIFT_CONTRACT> "syncRedemption(string,address)" "0xabc...-42" "0xRedeemer..." --private-key <OWNER_KEY>
```

### 14.5 Redeemer Address

The redeemer address is an explicit parameter, **not** `msg.sender`. This supports:
- Meta-transactions (someone else pays gas)
- User-specified recipient wallets (redeem to a different address)
- Sponsored/delegated redemptions

### 14.6 Failure Modes

| Failure | Cause | Fix |
|---------|-------|-----|
| `"Array length mismatch"` | `pins`, `codeHashes`, and `redeemers` arrays differ in length | Ensure all three arrays are the same length |
| `"PIN cannot be empty"` | Empty PIN string | Provide the PIN |
| `"Hash cannot be zero"` | `codeHash` is `bytes32(0)` | Check hash computation |
| `"Redeemer cannot be zero address"` | `redeemer` is `address(0)` | Provide valid redeemer |
| `"Invalid PIN or code hash"` | No matching entry in private state | Wrong PIN, wrong code, or already redeemed |
| `"Only CodeManager"` (on gift contract) | CodeManager is not the caller | Privacy group not authorized, or CODE_MANAGER constant is wrong |
| `"Invalid uniqueId"` (on gift contract) | Token was never minted / uniqueId doesn't parse | UID registered but token not yet minted via `buy()` |
| `"Not in vault"` (on gift contract) | Token already redeemed (left the vault) | Code was already used |
| `"UniqueId is inactive"` | Private execution state blocked the UID before routing | Mirror or inspect the UID active state and re-enable it if appropriate |
| `insufficient funds for gas` | Derived submitter out of gas | Fund the address in the error |

---

## 15. Troubleshooting Matrix

### Quick Reference

| Symptom | Root Cause | Diagnostic | Fix |
|---------|-----------|------------|-----|
| `insufficient funds for gas * price + value: address 0xABC...` | Derived submitter unfunded | The address in the error is the derived submitter — it changes per operation type | Send native currency to that exact address; see Section 6 for how to identify all derived submitters |
| `storeDataBatch` succeeds but public state unchanged | `externalCallsEnabled` passed as boolean `true` instead of string `"true"` | Recreate group and check the field is a string | Create new group with `"externalCallsEnabled": "true"` (string). Cannot be fixed after creation. |
| `OwnableUnauthorizedAccount(0x2B73...)` on `upgradeAndCall` | ProxyAdmin is owned by the Paladin signer, but you passed an external EOA as `initialOwner` during proxy deployment | Query admin via `pgroup_call` to `admin()` on the ProxyAdmin; compare to signed txn sender | Redeploy the proxy with the Paladin signer as `initialOwner` — see Section 9 |
| Transaction deploys but `contractAddress` is ProxyAdmin, not the proxy | OZ 5.2 `TransparentUpgradeableProxy` constructor auto-deploys ProxyAdmin first; you parsed the wrong contract address from the receipt | Check `ptx_getTransactionReceiptFull` — the `.receipt.contractAddress` is the ProxyAdmin, not your proxy. Your proxy address is in the `PentePrivateDeployEvent` states array. | Parse the correct address from the receipt states, not from `contractAddress` |
| Deploy reverts immediately with no useful error | Used **runtime bytecode** instead of **creation bytecode** | Creation bytecode starts with constructor init logic; runtime bytecode is what `eth_getCode` returns | Use the full bytecode from the compiler output (artifact JSON `bytecode` field), not the deployed code |
| `ADMIN()` returns a placeholder address | Did not update the constant before compiling | Placeholder value still in contract | Update `ADMIN` in source, recompile, redeploy via proxy upgrade (Section 9) |
| `AUTHORIZED()` returns a placeholder address | Did not update the constant before compiling | Placeholder value still in contract | Update `AUTHORIZED` in source, recompile, redeploy via proxy upgrade (Section 9) |
| `CODE_MANAGER()` returns `0x...c0DE` | Did not update the constant before compiling | Placeholder value still in contract | Update `CODE_MANAGER` in source, recompile, redeploy via proxy upgrade (Section 9) |
| `"Caller is not an authorized privacy group"` | Wrong address authorized on CodeManager | You authorized the derived submitter instead of the **group contract address** | Authorize the group contract address (`0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`), not the derived submitter. See Section 12. |
| `"Invalid uniqueId in batch"` during `storeDataBatch` | UIDs not registered on CodeManager | Check `validateUniqueId(uid)` on CodeManager | Call `registerUniqueIds` or `buy()` first |
| `"No matching uniqueId found."` during redemption | UID not registered on CodeManager | Call `getUniqueIdDetails(uid)` — should revert | Register UIDs first |
| `"Not in vault"` during redemption | Token already redeemed | Check `ownerOf(tokenId)` — not the contract address | Code was already used; cannot re-redeem |
| `RedemptionFailed` event on CodeManager | Gift contract reverted during `recordRedemption` | Read event `reason` field; check gift contract state | Fix root cause, then call `syncRedemption(uniqueId, redeemer)` on the gift contract |
| `"UniqueId is inactive"` during redemption | Private execution state marks the UID inactive | Check private status flow and CodeManager mirror | Re-enable via `setUniqueIdActiveBatch` if appropriate |
| `"Counter drift: CodeManager out of sync"` during `buy()` | External registration changed the counter | Check `getIdentifierCounter` on CodeManager | Ensure only `buy()` registers UIDs for this contract, or adjust `maxSaleSupply` |
| `"Payment must equal price + registration fee"` during `buy()` | Incorrect `msg.value` | Calculate: `(pricePerCard * qty) + (registrationFee * qty)` | Send exact amount |
| `pgroup_sendTransaction` returns success but no event on public chain | Group not ext-calls-enabled, or derived submitter unfunded for that specific operation | Check group config via `pgroup_getGroupById`; check each derived submitter balance (different ops use different submitters) | Recreate group with string `"true"` or fund the specific derived submitter shown in logs |
| Private contract call reverts with no useful message | Wrong ABI, function signature, or calling via wrong address (implementation instead of proxy) | Verify function signature matches contract exactly; verify you're calling the proxy address, not the implementation | Re-check ABI; use the proxy address for all interactions |
| `ptx_resolveVerifier` returns unexpected address | You're resolving in the wrong context or using the wrong algorithm | Must use `algorithm: "domain:ecdsa"` | See Section 2 for the correct call format |

### Diagnostic Commands — Paladin Private Calls

**Check a constant via the proxy (e.g. `ADMIN()`):**
```bash
curl -s -X POST "$PALADIN_RPC" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pgroup_call",
    "params": [
      {
        "domain": "pente",
        "group": {
          "salt": "0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef",
          "members": ["signer-auto-wallet@paladin-core"]
        },
        "to": "0x17ded097088321d457f603637b28ded0fcea5e26",
        "function": {
          "name": "ADMIN",
          "outputs": [{ "type": "address" }]
        },
        "from": "signer-auto-wallet@paladin-core"
      }
    ]
  }' | jq -r '.result'
```

**Check ProxyAdmin owner:**
```bash
curl -s -X POST "$PALADIN_RPC" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pgroup_call",
    "params": [
      {
        "domain": "pente",
        "group": {
          "salt": "0x10be41b4f53abac86f6e98fba8cb2a57542d970c8d78a14787714be200acc4ef",
          "members": ["signer-auto-wallet@paladin-core"]
        },
        "to": "0x6c7ea1dc87b0c778b2675735c98acfba94d3e042",
        "function": {
          "name": "owner",
          "outputs": [{ "type": "address" }]
        },
        "from": "signer-auto-wallet@paladin-core"
      }
    ]
  }' | jq -r '.result'
```

**Resolve the Paladin signer's EVM address:**
```bash
curl -s -X POST "$PALADIN_RPC" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "ptx_resolveVerifier",
    "params": [
      "signer-auto-wallet@paladin-core",
      "domain:ecdsa",
      "verifier"
    ]
  }' | jq -r '.result'
```
> Returns: `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`

### Diagnostic Commands — Public Contract Reads

**Check if a UID is registered:**
```javascript
const isValid = await codeManager.validateUniqueId("0xabc...-1");
```

**Check UID details:**
```javascript
const [giftContract, chainId, counter] = await codeManager.getUniqueIdDetails("0xabc...-1");
```

**Check privacy group authorization:**
```javascript
const isAuth = await codeManager.isAuthorizedPrivacyGroup("0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4");
```
> **Critical:** Pass the **group contract address**, not the derived submitter.

**Check card status (single call):**
```javascript
const [tokenId, holder, frozen, redeemed] = await giftContract.getCardStatus("0xabc...-1");
```

**Check if a UID is redeemed on CodeManager:**
```javascript
const isRedeemed = await codeManager.isUniqueIdRedeemed("0xabc...-1");
```

**Recover a failed redemption:**
```javascript
await giftContract.syncRedemption("0xabc...-1", redeemerAddress);
```

**Check identifier counter:**
```javascript
const [contractIdentifier, counter] = await codeManager.getIdentifierCounter(giftContractAddress, chainId);
```

---

## 16. Operational Best Practices & Key Lessons

### Lessons from Production Deployment

1. **`externalCallsEnabled` is a string, not a boolean.** This is the single most common silent failure. The privacy group will create successfully with a boolean, but external calls will never fire. It cannot be corrected after group creation — you must create a new group.

2. **Fund the correct derived submitter — there are multiple.** Different operations (deploy, finalize, store, external-call) route through *different* derived submitter addresses. The address in the `insufficient funds` error is the one that needs funding. You cannot predict these addresses — deploy, read the error, fund, retry. See Section 6 for the full table.

3. **All addresses and limits are compile-time constants.** `ADMIN`, `AUTHORIZED`, `CODE_MANAGER`, and `MAX_PER_PIN` cannot be changed after deployment. If any is wrong, you must recompile and redeploy via proxy upgrade (Section 9).

4. **Pente runs `shanghai` EVM.** Private contracts must be compiled with `--evm-version shanghai`. Public contracts can use a later EVM version.

5. **Paladin signs as its own internal signer, not as your external EOA.** The resolved Paladin signer address (`0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`) is deterministic per node but not an address you control externally. Any `msg.sender` check inside Pente will see this address. If your contract does `require(msg.sender == ADMIN)`, then `ADMIN` must be set to this Paladin signer address.

6. **Authorize the group contract address on CodeManager.** The address that calls CodeManager during `PenteExternalCall` is the **group contract address** (`0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`), not the derived submitter and not the privacy group ID. This is the address you pass to `voteToAuthorizePrivacyGroup`. Getting this wrong produces `"Caller is not an authorized privacy group"`.

7. **OZ 5.2 TransparentUpgradeableProxy auto-deploys ProxyAdmin.** You do NOT deploy ProxyAdmin separately. The proxy constructor does it. The `contractAddress` field in the receipt is actually the ProxyAdmin, not your proxy. Parse the proxy address from `PentePrivateDeployEvent` states instead.

8. **ProxyAdmin is owned by the Paladin signer, not your external EOA.** If you pass an external EOA as `initialOwner` during proxy deployment, that EOA has no signing capability inside Pente. Upgrades will fail with `OwnableUnauthorizedAccount`. Always use the resolved Paladin signer address as `initialOwner`.

9. **Use creation bytecode, not runtime bytecode.** When deploying via `pgroup_sendTransaction`, send the full creation bytecode from the compiler artifact's `bytecode` field. Do NOT use the deployed runtime code that `eth_getCode` returns — it lacks the constructor.

10. **Register UIDs before storing codes.** `storeDataBatch` emits a `PenteExternalCall` to `validateUniqueIdsOrRevert`. If UIDs aren't registered, the entire batch reverts atomically.

11. **Counter sync matters.** The GreetingCards `buy()` function verifies `getIdentifierCounter` matches `_totalMinted` before registering new UIDs. If any other caller has registered UIDs for the same contract+chainId pair, `buy()` will revert with `"Counter drift: CodeManager out of sync"`.

12. **Frozen state is derived.** A card is frozen if: (a) the token doesn't exist yet (not purchased), OR (b) it's explicitly frozen by admin. There is no separate frozen mapping for UIDs.

13. **Redeemed state is derived.** A card is redeemed if the token exists AND is not held by the vault (the contract itself). Once transferred out, the transfer guard prevents returning it.

14. **Gift contract isolation is the safety net.** CodeManager wraps the gift contract call in try/catch. If the gift contract reverts during `recordRedemption` (frozen, already redeemed, bug), CodeManager emits a `RedemptionFailed` event but does NOT roll back the Pente transition. The code hash deletion in PrivateComboStorage and the REDEEMED marking in CodeManager are preserved. Admin calls `syncRedemption(uniqueId, redeemer)` on the gift contract to complete the side effect after diagnosing the issue.

15. **Whitelist contract identifiers before storing.** `storeDataBatch` rejects codes whose contract identifier is not whitelisted. Call `setContractIdentifierWhitelist` first. This is a per-PrivateComboStorage setting — each deployment needs its own whitelisting.

16. **Selective mirroring is opt-in per UID.** When calling `setUniqueIdActiveBatch`, the `mirrorStatuses` array controls whether active-state changes are forwarded to the public CodeManager. If mirroring is disabled for a UID, `getActiveStatus` on CodeManager returns `USE_DEFAULT_ACTIVE_STATE`, hiding the private state from public view.

17. **Per-UID managers don't affect freeze/redeem authority.** `setUniqueIdManagersBatch` only controls who can call `setUniqueIdActiveBatch` for specific UIDs. Freeze/unfreeze authority remains with the gift contract, and redeem authority remains with `AUTHORIZED` (the meta-transaction processing service).

### Operational Checklist — End-to-End Verification

```
□ CodeManager deployed and initialized (public)
□ Fee vault set (public)
□ Gift contract deployed and initialized (public)
□ maxSaleSupply set (public)
□ Resolve Paladin signer: ptx_resolveVerifier → 0x01d5e8f6...
□ Privacy group created with externalCallsEnabled: "true" (STRING)
□ Group ID and group contract address recorded
□ Group verified via pgroup_getGroupById
□ PrivateComboStorage compiled with correct ADMIN, AUTHORIZED, CODE_MANAGER constants
□ Compiled with --evm-version shanghai
□ Implementation deployed via pgroup_sendTransaction (creation bytecode)
□ Receipt polled, implementation address recorded from PentePrivateDeployEvent
□ TransparentUpgradeableProxy deployed with (implAddr, paladinSigner, initData)
□ Receipt polled, ProxyAdmin and proxy addresses parsed correctly
□ Derived submitters funded (deploy, finalize, and store/external-call addresses)
□ ADMIN() verified via pgroup_call → returns Paladin signer
□ AUTHORIZED() verified via pgroup_call → returns meta-tx processor (Paladin signer)
□ CODE_MANAGER() verified via pgroup_call → returns correct public address
□ ProxyAdmin owner() verified → returns Paladin signer
□ Privacy group contract address authorized on CodeManager (public)
□ Contract identifier whitelisted on PrivateComboStorage (private)
□ UIDs registered (via buy() or registerUniqueIds) (public)
□ Per-UID managers configured if needed (setUniqueIdManagersBatch) (private)
□ mirrorStatuses decided per UID (selective mirroring) (private)
□ Codes generated off-chain: code → codeHash = keccak256(code)
□ storeDataBatch succeeds → PINs assigned → validateUniqueIdsOrRevert passes
□ redeemCodeBatch succeeds → recordRedemption routes to gift contract → NFT transferred
□ If RedemptionFailed emitted → syncRedemption(uniqueId, redeemer) recovers the NFT transfer
□ tokenURI switches from unredeemed to redeemed metadata
```

### Contract Versions

| Contract | Solidity | EVM Target | Framework |
|----------|----------|-----------|-----------|
| CodeManager | >=0.8.2 <0.9.0 | Public chain default | Genesis Upgradeable (custom) |
| GreetingCards | >=0.8.2 <0.9.0 | Public chain default | OpenZeppelin v5.2.0 Upgradeable |
| PrivateComboStorage | >=0.8.2 <0.9.0 | shanghai | None (standalone) |
| TransparentUpgradeableProxy | ^0.8.20 | shanghai | OpenZeppelin v5.2.0 |
| ProxyAdmin | ^0.8.20 | shanghai | OpenZeppelin v5.2.0 (auto-deployed by proxy) |

---

## 17. Recommended Future Architecture — Forwarder / Meta-Transaction Pattern

### Current State: AUTHORIZED as Meta-Transaction Processor

The current architecture already embodies the core concept of meta-transaction forwarding. The `AUTHORIZED` constant in `PrivateComboStorage` designates a **meta-transaction processing service** — the identity that receives forwarded store/redeem requests from external callers, recovers the original caller's intent, and executes `storeDataBatch` / `redeemCodeBatch` within the privacy group. The Paladin signer provides the `msg.sender` authority for these forwarded calls.

What the current design lacks is **on-chain signature verification** — the private contract trusts `msg.sender` (the Paladin signer) rather than verifying an embedded signature from the external caller. This works when a single Paladin node operator controls all operations, but limits extensibility.

### The Problem with `msg.sender` in Pente

Inside a Paladin Pente privacy group, **every** transaction is signed and submitted by the Paladin-managed internal signer (`signer-auto-wallet@paladin-core`). This means:

- `msg.sender` inside the private contract is always the Paladin signer address (e.g., `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`).
- You cannot distinguish between different external users via `msg.sender`.
- If you hard-code `require(msg.sender == ADMIN)`, only the Paladin signer can pass — not an external EOA.

This works for single-admin systems where the Paladin node operator IS the admin. But it breaks down when:
- Multiple external users need different authorization levels.
- You want an external EOA (e.g., a hardware wallet) to retain admin privileges.
- You need non-repudiation tied to real identities rather than a shared node signer.

### The Solution: Gateway / Forwarder Pattern

Instead of relying on `msg.sender`, the private contract verifies **signatures** embedded in the transaction data.

**Architecture:**

```
External EOA                    Paladin Node                    Pente Privacy Group
     │                               │                               │
     │  1. Sign typed data           │                               │
     │     (EIP-712 approval)        │                               │
     │                               │                               │
     │  2. Submit signed payload ──► │                               │
     │                               │  3. pgroup_sendTransaction    │
     │                               │     with signed payload ────► │
     │                               │                               │
     │                               │                    4. Contract calls │
     │                               │                       ecrecover()    │
     │                               │                       to recover     │
     │                               │                       external EOA   │
     │                               │                               │
     │                               │                    5. Authorize      │
     │                               │                       based on       │
     │                               │                       recovered addr │
```

**Key components:**

1. **Off-chain:** External admin signs an EIP-712 typed data struct (e.g., `Approve(address target, bytes32 action, uint256 nonce, uint256 deadline)`). This proves intent without requiring on-chain execution by that EOA.

2. **Relay:** The signed payload is submitted to Paladin, which wraps it in a `pgroup_sendTransaction`. Paladin's internal signer is the `msg.sender`, but the *payload* carries the external signature.

3. **On-chain verification:** The private contract has a `forwarder` or `gateway` function:
   ```solidity
   function executeWithApproval(
       bytes32 action,
       bytes calldata data,
       uint256 deadline,
       uint8 v, bytes32 r, bytes32 s
   ) external {
       require(block.timestamp <= deadline, "Expired");
       bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
           APPROVE_TYPEHASH, action, keccak256(data), nonces[signer]++, deadline
       )));
       address signer = ecrecover(digest, v, r, s);
       require(signer == ADMIN, "Not admin");
       // Execute the action
       (bool success,) = address(this).delegatecall(data);
       require(success);
   }
   ```

4. **Authorization:** The contract checks the *recovered signer* against its admin/authorized addresses, not `msg.sender`.

### Benefits

| Aspect | Current (msg.sender) | Forwarder Pattern |
|--------|----------------------|-------------------|
| Admin identity | Paladin node signer | External EOA (hardware wallet, multisig) |
| Multi-user auth | Not possible — single signer | Each user signs with own key |
| Key security | Paladin manages key | Admin key can be cold storage |
| Non-repudiation | All actions look same | Signatures tied to specific EOAs |
| Upgrade authority | Must match Paladin signer | Can be any verified address |

### Implementation Considerations

- **Nonce management:** The contract must track per-signer nonces to prevent replay attacks.
- **EIP-712 domain:** Must include the chain ID and contract address to prevent cross-chain replay.
- **Deadline enforcement:** `block.timestamp` inside Pente reflects the base chain block time. Include reasonable deadlines.
- **Gas sponsorship:** Paladin's internal signer still pays gas. The external signer only signs approvals — they don't need ETH on the privacy group.
- **Backward compatibility:** Can coexist with direct `msg.sender` checks. Add forwarder functions alongside existing admin functions; phase out direct checks over time.
