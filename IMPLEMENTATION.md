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
5. [Creating a Normal Pente Privacy Group](#5-creating-a-normal-pente-privacy-group)
6. [Creating an External-Calls-Enabled Privacy Group](#6-creating-an-external-calls-enabled-privacy-group)
7. [Funding Strategy](#7-funding-strategy)
8. [Deploying the Private Contract](#8-deploying-the-private-contract)
9. [Verifying the Private Contract](#9-verifying-the-private-contract)
10. [Authorization & Whitelisting Strategy](#10-authorization--whitelisting-strategy)
11. [Store Flow — storeDataBatch](#11-store-flow--storedatabatch)
12. [Redeem Flow — redeemCodeBatch + External Call](#12-redeem-flow--redeemcodebatch--external-call)
13. [Troubleshooting Matrix](#13-troubleshooting-matrix)
14. [Operational Best Practices & Key Lessons](#14-operational-best-practices--key-lessons)

---

## 1. Architecture Overview

The patented system uses a three-layer architecture. No single layer holds all the data needed to compromise a redeemable code. Private contract state transitions atomically trigger public-chain actions via `PenteExternalCall` events routed through CodeManager.

```
┌─────────────────────────────────────────────────────────────────────┐
│                      PUBLIC CHAIN (Besu)                            │
│                                                                     │
│  ┌──────────────────┐              ┌────────────────────────────┐   │
│  │   CodeManager    │─── resolve ─▶│      Gift Contract         │   │
│  │   (Registry +    │   UID→gift   │      (IRedeemable)         │   │
│  │    Router)       │              │      SOLE STATE AUTHORITY   │   │
│  │                  │◀── forward ──│                             │   │
│  │  • UID registry  │   calls via  │  • frozen / unfrozen state │   │
│  │  • Governance    │  IRedeemable │  • redeemed tracking       │   │
│  │  • Fee vault     │              │  • redemption behavior     │   │
│  │  • Privacy group │              │    (NFT transfer, mint,    │   │
│  │    authorization │              │     counter, etc.)         │   │
│  └────────┬─────────┘              └────────────────────────────┘   │
│           │ ▲                                                       │
│           │ │ PenteExternalCall (atomic routing)                    │
│           │ │                                                       │
│  ┌────────▼─┴───────────────────────────────────────────────────┐   │
│  │                  PENTE PRIVACY GROUP                          │   │
│  │  ┌──────────────────────┐                                    │   │
│  │  │ PrivateComboStorage  │  • Hash-only code storage (private) │   │
│  │  │                      │  • Contract-assigned PIN routing    │   │
│  │  │                      │  • Batch code storage + redemption  │   │
│  │  │                      │  • Hash verification (no cleartext) │   │
│  │  └──────────────────────┘                                    │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer | Contract | Responsibility |
|-------|----------|----------------|
| **Public Registry** | CodeManager | UID registration, deterministic ID generation, governance (2/3 supermajority), Pente router — forwards calls to gift contracts. Stores **no** per-UID state. |
| **Public Authority** | Gift Contract (IRedeemable) | Sole authority on per-UID state: frozen status, redemption behavior. Decides how redemption works (single-use, multi-use, NFT transfer, etc.). If it reverts, the Pente transition rolls back. |
| **Private Storage** | PrivateComboStorage | Hash-only code storage within a Pente privacy group. PINs are contract-assigned routing keys (not part of the hash). Verifies codes via hash comparison. Emits `PenteExternalCall` events to atomically route state changes through CodeManager to the gift contract. All configuration is compile-time constants — changes require a contract upgrade via proxy. |

### Key Design Principles

- **No cleartext codes on-chain.** Codes are represented as `keccak256(code)` hashes. The PIN is a contract-assigned routing key (not part of the hash) for O(1) bucket lookup.
- **Gift contract authority.** CodeManager delegates all per-UID state management. If the gift contract reverts, the entire Pente transition rolls back atomically.
- **Default frozen state.** New UIDs default to frozen until explicitly unfrozen, preventing premature redemption.
- **Privacy-preserving verification.** The Pente privacy group verifies codes privately, then triggers public state updates via `PenteExternalCall`.
- **External calls.** The privacy group must be created with `externalCallsEnabled: "true"` (string, not boolean) so that `PenteExternalCall` events are processed by Paladin and forwarded to the base ledger.
- **EVM version.** Pente privacy groups run `shanghai` EVM. Public chain may run a later EVM version. Private contracts must compile with `--evm-version shanghai`.

---

## 2. Identity & Address Taxonomy

Understanding which address is which is critical. Paladin, Pente, and Besu each surface different addresses in different contexts. Confusing them is the #1 source of failed transactions.

### Address Types

| # | Address Type | Example | Where It Appears | Purpose |
|---|-------------|---------|-------------------|---------|
| 1 | **Root Signer** | `0x01d5...` | Besu node's coinbase; Paladin `signer` field | The Besu node's secp256k1 key. Signs all base-ledger transactions. Must be funded with native currency for gas. |
| 2 | **Paladin Verifier (Node Identity)** | (returned by `ptx_resolveVerifier`) | Paladin identity resolution | The verifier string for a Paladin identity (e.g., `node1@node1`). Used in privacy group member lists. |
| 3 | **Privacy Group Address** | `0xe89c...` | Pente group creation receipt | The on-chain address of the Pente privacy group contract. This is what gets authorized on CodeManager via `voteToAuthorizePrivacyGroup()`. |
| 4 | **Private Contract Address** | `0xb202...` | `pente_deploy` receipt | The address of `PrivateComboStorage` inside the privacy group's private state trie. Referenced as `to` in all `pente_invoke` calls. |
| 5 | **Derived Submitter** | (appears in `insufficient funds` errors) | Besu error logs during Pente transitions | A deterministic address derived by Pente from the privacy group + member identity. Must be funded because it submits the base-ledger transaction that carries the `PenteExternalCall` payload. |
| 6 | **CodeManager (Public)** | deployed proxy address | Public chain | The `TransparentUpgradeableProxy` address of CodeManager. Hardcoded into `PrivateComboStorage` as `CODE_MANAGER`. |
| 7 | **Gift Contract (Public)** | deployed proxy address | Public chain | The `TransparentUpgradeableProxy` address of the ERC-721 (or other IRedeemable) contract. Registered on CodeManager via `registerUniqueIds`. |

### Critical Rule

> **When you see `insufficient funds for gas` in Pente operations, the address in the error is the derived submitter.** Fund that exact address. Do not guess. Copy the address from the error message and send native currency to it.

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

Each Paladin node must be registered and its identity resolved before it can participate in privacy groups.

### 4.1 Start Paladin

Paladin connects to a running Besu node. Each Paladin node has one or more registered identities (e.g., `node1@node1`).

### 4.2 Resolve Node Identity

Every Paladin identity has a verifier that maps to a specific key. Resolve it before creating groups:

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "ptx_resolveVerifier",
    "params": [
      "node1@node1",
      "pente",
      "secp256k1"
    ]
  }'
```

The response contains the verifier string used in privacy group member lists. Record it.

### 4.3 Multi-Node Setup

For multi-node privacy groups, repeat identity resolution on each Paladin node. Exchange verifier strings between operators. All members must be resolved before group creation.

---

## 5. Creating a Normal Pente Privacy Group

A normal privacy group (without external calls) is useful for testing private contract logic in isolation. It cannot trigger `PenteExternalCall` events on the base ledger.

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_createPrivacyGroup",
    "params": [{
      "domain": "pente",
      "members": ["node1@node1"],
      "evmVersion": "shanghai",
      "endorsementType": "group_scoped_identities",
      "externalCallsEnabled": "false"
    }]
  }'
```

The response contains a `privacyGroupAddress`. This group is private-only — `PenteExternalCall` events emitted inside it will not be relayed to the base ledger.

**Use for:** testing `storeDataBatch` and `redeemCodeBatch` logic without affecting the public chain.

---

## 6. Creating an External-Calls-Enabled Privacy Group

This is the production configuration. The privacy group processes `PenteExternalCall` events and submits them as real base-ledger transactions.

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_createPrivacyGroup",
    "params": [{
      "domain": "pente",
      "members": ["node1@node1"],
      "evmVersion": "shanghai",
      "endorsementType": "group_scoped_identities",
      "externalCallsEnabled": "true"
    }]
  }'
```

### Critical: `externalCallsEnabled` Must Be a String

```json
"externalCallsEnabled": "true"     ← CORRECT (string)
"externalCallsEnabled": true       ← WRONG (boolean — silently ignored)
```

If you pass a boolean, the group will be created successfully but `PenteExternalCall` events will never be relayed. Calls to `storeDataBatch` (which emits `validateUniqueIdsOrRevert` via external call) and `redeemCodeBatch` (which emits `recordRedemption` via external call) will appear to succeed in private state but will never reach the public chain. This is the most common silent misconfiguration.

### EVM Version

Pente privacy groups must use `"evmVersion": "shanghai"`. The Pente EVM does not yet support later hard forks. Contracts deployed inside the group must be compiled with `--evm-version shanghai`.

### After Creation

Record the `privacyGroupAddress` from the response. You will need it for:
1. `pente_deploy` — deploying the private contract
2. `pente_invoke` — calling functions on the private contract
3. `voteToAuthorizePrivacyGroup` — authorizing this group on CodeManager

---

## 7. Funding Strategy

Pente operations that emit `PenteExternalCall` events require the **derived submitter** address to have gas funds. This is not the root signer — it is a deterministic address computed from the privacy group and member identity.

### 7.1 When Funding Is Required

Gas is needed for any Pente operation that triggers a base-ledger transaction:
- `storeDataBatch` → emits `PenteExternalCall(CODE_MANAGER, validateUniqueIdsOrRevert(...))`
- `redeemCodeBatch` → emits `PenteExternalCall(CODE_MANAGER, recordRedemption(...))` per entry

Operations that are purely private (e.g., read-only `pente_call` queries in a non-ext-calls group) do not require gas on the derived submitter.

### 7.2 How to Identify the Derived Submitter

You cannot predict the derived submitter address in advance. The workflow is:

1. Attempt the Pente operation (e.g., `storeDataBatch`)
2. It will fail with an error containing the derived address:
   ```
   insufficient funds for gas * price + value: address 0xABCD...1234
   balance wanted 100000000000000
   ```
3. Copy `0xABCD...1234` from the error
4. Send native currency to that address from a funded account
5. Retry the Pente operation — it will succeed

### 7.3 Funding Amount

Send enough to cover gas for the expected operations. The exact amount depends on the operation complexity, but 0.1 native currency is typically sufficient for initial testing. Monitor the balance and top up as needed.

### 7.4 Common Mistake

Do not confuse the derived submitter with:
- The root signer / coinbase address
- The privacy group address
- The `from` identity in `pente_invoke` calls

The derived submitter is a unique address that only appears in error messages when funding is insufficient.

---

## 8. Deploying the Private Contract

### 8.1 Prerequisites

Before deploying `PrivateComboStorage` into the privacy group:

1. **CodeManager is deployed** on the public chain and its proxy address is known
2. **Privacy group is created** with `externalCallsEnabled: "true"` and `evmVersion: "shanghai"`
3. **Derived submitter is funded** (attempt a simple operation first to discover the address)
4. **`CODE_MANAGER` constant is set** in the `PrivateComboStorage` source to the CodeManager proxy address before compilation
5. **`ADMIN` and `AUTHORIZED` constants are set** to the correct addresses before compilation

### 8.2 Compile for Shanghai EVM

PrivateComboStorage must be compiled with `--evm-version shanghai` because Pente runs shanghai EVM:

```bash
python compile.py PrivateComboStorage.sol --evm-version shanghai
```

### 8.3 Use Deployment Bytecode, Not Runtime Bytecode

When deploying via `pente_deploy`, you must provide the **deployment bytecode** (also called "creation bytecode" or "init bytecode"), not the runtime bytecode.

- **Deployment bytecode** = constructor + runtime code. Starts with the constructor logic.
- **Runtime bytecode** = what remains on-chain after deployment. Does NOT include the constructor.

The compiled output from `compile.py` includes both in the artifact JSON. Use the `bytecode` field (deployment), not the `deployedBytecode` field (runtime).

`PrivateComboStorage` has no constructor logic (no `initialize()`, no storage writes at deploy time — all configuration is compile-time constants). However, always use deployment bytecode to ensure the EVM deploys correctly.

### 8.4 Deploy

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_deploy",
    "params": [{
      "group": {
        "salt": "<PRIVACY_GROUP_SALT>",
        "members": ["node1@node1"]
      },
      "from": "node1@node1",
      "bytecode": "<DEPLOYMENT_BYTECODE>",
      "abi": <PRIVATE_COMBO_STORAGE_ABI>
    }]
  }'
```

The response contains the private contract address (e.g., `0xb202...`). Record it for all subsequent `pente_invoke` calls.

---

## 9. Verifying the Private Contract

After deployment, verify the contract is working correctly before proceeding to storage and redemption.

### 9.1 Check CODE_MANAGER()

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_call",
    "params": [{
      "group": {
        "salt": "<PRIVACY_GROUP_SALT>",
        "members": ["node1@node1"]
      },
      "from": "node1@node1",
      "to": "<PRIVATE_CONTRACT_ADDRESS>",
      "function": "CODE_MANAGER()",
      "inputs": []
    }]
  }'
```

**Expected:** Returns the CodeManager proxy address that was hardcoded into the contract before compilation.

**If it returns the placeholder `0x...c0DE`:** You compiled `PrivateComboStorage` without updating the `CODE_MANAGER` constant. Recompile and redeploy.

### 9.2 Check ADMIN() and AUTHORIZED()

Verify the access control constants match your intended addresses:

```bash
# Check ADMIN
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_call",
    "params": [{
      "group": {
        "salt": "<PRIVACY_GROUP_SALT>",
        "members": ["node1@node1"]
      },
      "from": "node1@node1",
      "to": "<PRIVATE_CONTRACT_ADDRESS>",
      "function": "ADMIN()",
      "inputs": []
    }]
  }'
```

Repeat for `AUTHORIZED()`. Both should return the addresses you set as constants before compilation.

### 9.3 Verification Checklist

- [ ] `CODE_MANAGER()` returns the correct CodeManager proxy address
- [ ] `ADMIN()` returns the intended admin address
- [ ] `AUTHORIZED()` returns the intended service account address
- [ ] Privacy group has `externalCallsEnabled: "true"` (string)
- [ ] Derived submitter is funded

---

## 10. Authorization & Whitelisting Strategy

### 10.1 Authorize the Privacy Group on CodeManager

The privacy group must be authorized on CodeManager before its `PenteExternalCall` events will be accepted. Without authorization, calls to `recordRedemption`, `setUidFrozen`, and `validateUniqueIdsOrRevert` from the privacy group will revert with `"Caller is not an authorized privacy group"`.

```javascript
// Single voter — takes effect immediately
await codeManager.voteToAuthorizePrivacyGroup(privacyGroupAddress);
```

For multi-voter governance:
```javascript
// Requires 2/3 supermajority
await codeManager.connect(voter1).voteToAuthorizePrivacyGroup(privacyGroupAddress);
await codeManager.connect(voter2).voteToAuthorizePrivacyGroup(privacyGroupAddress);
// If 2/3 reached, authorization takes effect
```

### 10.2 Access Control on PrivateComboStorage

`PrivateComboStorage` uses compile-time constant addresses for access control. Two addresses are authorized: `ADMIN` and `AUTHORIZED`. These are set in the contract source before compilation and cannot be changed at runtime — changing them requires deploying a new implementation and upgrading the proxy.

There are no `authorize()`, `deauthorize()`, or `transferAdmin()` functions. All configuration updates are performed via contract upgrade.

Only `ADMIN` and `AUTHORIZED` can call `storeDataBatch` and `redeemCodeBatch`.

### 10.3 Register UIDs on CodeManager

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

### 10.4 Authorization Order

The complete authorization sequence:

```
1. Deploy CodeManager + Gift Contract on public chain
2. Create ext-calls privacy group
3. Fund derived submitter
4. Compile PrivateComboStorage with correct CODE_MANAGER, ADMIN, AUTHORIZED constants
5. Deploy PrivateComboStorage in privacy group
6. Verify CODE_MANAGER(), ADMIN(), AUTHORIZED()
7. Authorize privacy group on CodeManager:
     voteToAuthorizePrivacyGroup(privacyGroupAddress)
8. Register UIDs on CodeManager (or let buy() do it)
9. Store codes → storeDataBatch
10. Redeem codes → redeemCodeBatch
```

---

## 11. Store Flow — storeDataBatch

### 11.1 Off-Chain Code Generation

Codes are generated off-chain. No cleartext ever touches any chain:

```
For each code:
  1. Generate random code string (e.g., "HappyBirthday2026")
  2. Compute codeHash = keccak256(abi.encodePacked(code))
     NOTE: The PIN is NOT part of the hash — PINs are assigned by the contract.
  3. Record: { uniqueId, codeHash: 0x... }
```

The contract assigns a PIN to each code during `storeDataBatch`. The PIN is returned to the caller and shared with the end user (e.g., printed on the card). The full code is the secret. Both PIN and code are needed to redeem.

### 11.2 Calling storeDataBatch

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_invoke",
    "params": [{
      "group": {
        "salt": "<PRIVACY_GROUP_SALT>",
        "members": ["node1@node1"]
      },
      "from": "node1@node1",
      "to": "<PRIVATE_CONTRACT_ADDRESS>",
      "function": "storeDataBatch(string[],bytes32[],uint256,bool,bytes32)",
      "inputs": [
        ["<UNIQUE_ID_1>", "<UNIQUE_ID_2>"],
        ["0xabc123...", "0xdef456..."],
        3,
        false,
        "0x<RANDOM_32_BYTES>"
      ]
    }]
  }'
```

The function returns `string[] assignedPins` — the contract-assigned PIN for each entry. Store these PINs alongside the codes in your off-chain database.

### 11.3 What Happens Inside

`storeDataBatch` executes three phases atomically:

1. **Phase 1 — Local preflight:** Validates arrays, checks for empty values and zero hashes.

2. **Phase 2 — Public registry validation:** Emits `PenteExternalCall` → `CodeManager.validateUniqueIdsOrRevert(uniqueIds)`. If any uniqueId is not registered on CodeManager, the entire Pente transition reverts.

3. **Phase 3 — Assign PINs and store entries:** For each entry, derives a PIN from caller-supplied entropy using the selected charset (alphanumeric or full). If a collision occurs (same codeHash at derived PIN, or slot is full at MAX_PER_PIN=32), the entropy is re-chained via `keccak256(entropy)` until an open slot is found — no revert, no information leakage. Stores `(pin, codeHash) → CodeMetadata{ uniqueId, exists: true }`. Emits `DataStoredStatus(uniqueId, assignedPin)` per entry.

### 11.4 Failure Modes

| Failure | Cause | Fix |
|---------|-------|-----|
| `"Array length mismatch"` | `uniqueIds` and `codeHashes` arrays have different lengths | Ensure both arrays are the same length |
| `"Empty uniqueId"` | One of the uniqueIds is an empty string | Check your UID generation |
| `"Zero code hash"` | A codeHash is `bytes32(0)` | Check your hash computation |
| `"PIN length must be 1-8"` | Invalid `pinLength` parameter | Use a value between 1 and 8 |
| `"Entropy cannot be zero"` | Entropy parameter is `bytes32(0)` | Supply random 32 bytes |
| `"PIN space exhausted"` | 100 retries failed to find an open PIN slot | Increase PIN length or reduce stored codes |
| `"Invalid uniqueId in batch"` | The uniqueId is not registered on CodeManager | Register UIDs first via `registerUniqueIds` |
| `"Caller is not an authorized privacy group"` | The privacy group is not authorized on CodeManager | Call `voteToAuthorizePrivacyGroup` |
| `"Caller is not authorized"` | The `from` identity is not `ADMIN` or `AUTHORIZED` | Update constants and redeploy via upgrade |
| `insufficient funds for gas` | The derived submitter has no gas | Fund the address shown in the error |

---

## 12. Redeem Flow — redeemCodeBatch + External Call

### 12.1 End-to-End Data Flow

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
  4. Deletes the hash entry (code is consumed)
  5. Decrements pinSlotCount[pin]
  6. Emits RedeemStatus(uniqueId, redeemer)
  7. Emits PenteExternalCall(CODE_MANAGER,
       abi.encodeWithSignature("recordRedemption(string,address)", uniqueId, redeemer))
         │
         ▼
Pente processes the transition, sees PenteExternalCall(s):
  → Submits base-ledger tx(es) to CODE_MANAGER from the derived submitter
         │
         ▼
CodeManager.recordRedemption(uniqueId, redeemer) [onlyAuthorizedPrivacyGroup]:
  1. Calls getUniqueIdDetails(uniqueId) → resolves to gift contract
  2. Calls IRedeemable(giftContract).recordRedemption(uniqueId, redeemer)
  3. Emits RedemptionRouted(uniqueId, giftContract, redeemer)
         │
         ▼
Gift Contract.recordRedemption(uniqueId, redeemer) [onlyCodeManager]:
  1. Parses uniqueId → tokenId
  2. Requires: valid, minted, in vault, not frozen
  3. Transfers NFT from vault (contract) to redeemer
  4. Increments totalRedeems
  5. Emits CardRedeemed(tokenId, uniqueId, redeemer)
  6. If any require fails → revert → entire Pente transition rolls back
     → the delete in PrivateComboStorage is undone
     → code remains usable
```

### 12.2 Calling redeemCodeBatch

```bash
curl -X POST http://localhost:31548/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "pente_invoke",
    "params": [{
      "group": {
        "salt": "<PRIVACY_GROUP_SALT>",
        "members": ["node1@node1"]
      },
      "from": "node1@node1",
      "to": "<PRIVATE_CONTRACT_ADDRESS>",
      "function": "redeemCodeBatch(string[],bytes32[],address[])",
      "inputs": [
        ["<PIN_1>", "<PIN_2>"],
        ["<CODE_HASH_1>", "<CODE_HASH_2>"],
        ["<REDEEMER_1>", "<REDEEMER_2>"]
      ]
    }]
  }'
```

### 12.3 Atomicity Guarantee

The key property: **if the gift contract reverts, the entire Pente transition rolls back.** This means:
- The `delete` of the hash entry in PrivateComboStorage is undone
- The `pinSlotCount` decrement is undone
- The code remains usable for a future redemption attempt
- No partial state changes on either chain

### 12.4 Redeemer Address

The redeemer address is an explicit parameter, **not** `msg.sender`. This supports:
- Meta-transactions (someone else pays gas)
- User-specified recipient wallets (redeem to a different address)
- Sponsored/delegated redemptions

### 12.5 Failure Modes

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
| `"Token is frozen"` (on gift contract) | Admin froze the token | Unfreeze via `setFrozen(tokenId, false)` if appropriate |
| `insufficient funds for gas` | Derived submitter out of gas | Fund the address in the error |

---

## 13. Troubleshooting Matrix

### Quick Reference

| Symptom | Root Cause | Diagnostic | Fix |
|---------|-----------|------------|-----|
| `insufficient funds for gas * price + value: address 0xABC...` | Derived submitter unfunded | The address in the error is the derived submitter | Send native currency to that exact address |
| `storeDataBatch` succeeds but public state unchanged | `externalCallsEnabled` passed as boolean `true` instead of string `"true"` | Recreate group and check the field is a string | Create new group with `"externalCallsEnabled": "true"` (string) |
| `ADMIN()` returns a placeholder address | Did not update the constant before compiling | Placeholder value still in contract | Update `ADMIN` in source, recompile, redeploy via upgrade |
| `AUTHORIZED()` returns a placeholder address | Did not update the constant before compiling | Placeholder value still in contract | Update `AUTHORIZED` in source, recompile, redeploy via upgrade |
| `CODE_MANAGER()` returns `0x...c0DE` | Did not update the constant before compiling | Placeholder value still in contract | Update `CODE_MANAGER` in source, recompile, redeploy via upgrade |
| `"Caller is not an authorized privacy group"` | Privacy group address not authorized on CodeManager | Check `isAuthorizedPrivacyGroup(groupAddr)` | Call `voteToAuthorizePrivacyGroup(groupAddr)` |
| `"Invalid uniqueId in batch"` during `storeDataBatch` | UIDs not registered on CodeManager | Check `validateUniqueId(uid)` on CodeManager | Call `registerUniqueIds` or `buy()` first |
| `"No matching uniqueId found."` during redemption | UID not registered on CodeManager | Call `getUniqueIdDetails(uid)` — should revert | Register UIDs first |
| `"Not in vault"` during redemption | Token already redeemed | Check `ownerOf(tokenId)` — not the contract address | Code was already used; cannot re-redeem |
| `"Token is frozen"` during redemption | Admin explicitly froze the token | Check `isUniqueIdFrozen(uid)` | Unfreeze if appropriate |
| `"Counter drift: CodeManager out of sync"` during `buy()` | External registration changed the counter | Check `getIdentifierCounter` on CodeManager | Ensure only `buy()` registers UIDs for this contract, or adjust `maxSaleSupply` |
| `"Payment must equal price + registration fee"` during `buy()` | Incorrect `msg.value` | Calculate: `(pricePerCard * qty) + (registrationFee * qty)` | Send exact amount |
| Pente invoke returns success but no event on public chain | Group not ext-calls-enabled, or gas insufficient | Check group config; check derived submitter balance | Recreate group with string `"true"` or fund submitter |
| Private contract call reverts with no useful message | Wrong ABI or function signature | Verify function signature matches contract exactly | Re-check ABI |

### Diagnostic Commands

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
const isAuth = await codeManager.isAuthorizedPrivacyGroup(privacyGroupAddress);
```

**Check card status (single call):**
```javascript
const [tokenId, holder, frozen, redeemed] = await giftContract.getCardStatus("0xabc...-1");
```

**Check identifier counter:**
```javascript
const [contractIdentifier, counter] = await codeManager.getIdentifierCounter(giftContractAddress, chainId);
```

---

## 14. Operational Best Practices & Key Lessons

### Lessons from Production Deployment

1. **`externalCallsEnabled` is a string, not a boolean.** This is the single most common silent failure. The privacy group will create successfully with a boolean, but external calls will never fire.

2. **Fund the derived submitter, not the root signer.** The address in the `insufficient funds` error is the one that needs funding. It is a deterministic address you cannot predict — you must attempt an operation and read it from the error message.

3. **All addresses and limits are compile-time constants.** `ADMIN`, `AUTHORIZED`, `CODE_MANAGER`, and `MAX_PER_PIN` cannot be changed after deployment. If any is wrong, you must recompile and redeploy via proxy upgrade.

4. **Pente runs shanghai EVM.** Private contracts must be compiled with `--evm-version shanghai`. Public contracts can use a later EVM version.

5. **Register UIDs before storing codes.** `storeDataBatch` emits a `PenteExternalCall` to `validateUniqueIdsOrRevert`. If UIDs aren't registered, the entire batch reverts atomically.

6. **Counter sync matters.** The GreetingCards `buy()` function verifies `getIdentifierCounter` matches `_totalMinted` before registering new UIDs. If any other caller has registered UIDs for the same contract+chainId pair, `buy()` will revert with `"Counter drift: CodeManager out of sync"`.

7. **Frozen state is derived.** In CryftGreetingCards, a card is frozen if: (a) the token doesn't exist yet (not purchased), OR (b) it's explicitly frozen by admin. There is no separate frozen mapping for UIDs — it's computed from on-chain state.

8. **Redeemed state is derived.** A card is redeemed if the token exists AND is not held by the vault (the contract itself). Once transferred out, the transfer guard prevents returning it.

9. **Atomicity is the safety net.** If the gift contract reverts during `recordRedemption` (frozen, already redeemed, invalid UID), the entire Pente transition rolls back. The code hash deletion in PrivateComboStorage is undone. No manual cleanup needed.

### Operational Checklist — End-to-End Verification

```
□ CodeManager deployed and initialized
□ Fee vault set
□ Gift contract deployed and initialized
□ maxSaleSupply set
□ Privacy group created with externalCallsEnabled: "true" (STRING)
□ Derived submitter funded
□ PrivateComboStorage compiled with correct ADMIN, AUTHORIZED, CODE_MANAGER constants
□ PrivateComboStorage deployed via Pente
□ ADMIN() returns intended admin address
□ AUTHORIZED() returns intended authorized address
□ CODE_MANAGER() returns correct address
□ Privacy group authorized on CodeManager
□ UIDs registered (via buy() or registerUniqueIds)
□ Codes generated off-chain: code → codeHash = keccak256(code)
□ storeDataBatch succeeds → PINs assigned → validateUniqueIdsOrRevert passes
□ redeemCodeBatch succeeds → recordRedemption routes to gift contract → NFT transferred
□ tokenURI switches from unredeemed to redeemed metadata
```

### Contract Versions

| Contract | Solidity | EVM Target | Framework |
|----------|----------|-----------|-----------|
| CodeManager | >=0.8.2 <0.9.0 | Public chain default | Genesis Upgradeable (custom) |
| CryftGreetingCards | >=0.8.2 <0.9.0 | Public chain default | OpenZeppelin v5.2.0 Upgradeable |
| PrivateComboStorage | >=0.8.2 <0.9.0 | shanghai | None (standalone) |
