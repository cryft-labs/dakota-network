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
   - [Layer Responsibilities](#layer-responsibilities)
   - [Key Design Principles](#key-design-principles)
   - [Complete Contract Flow](#complete-contract-flow)
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
17. [Private Meta-Transaction Relay — EIP-712 / ERC-2771 Architecture](#17-private-meta-transaction-relay--eip-712--erc-2771-architecture)
18. [API-Level User Intent Signatures & Result Routing](#18-api-level-user-intent-signatures--result-routing)

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
│  │   │  • TRUSTED_FORWARDER = relay addr      │                      │   │
│  │   │  • MAX_PER_PIN                         │                      │   │
│  │   │                                        │                      │   │
│  │   │  ERC-2771: _msgSender() extracts the   │                      │   │
│  │   │  original signer from calldata when    │                      │   │
│  │   │  called by TRUSTED_FORWARDER            │                      │   │
│  │   └────────────────────────────────────────┘                      │   │
│  │                                                                   │   │
│  │   ┌────────────────────────────────────────┐                      │   │
│  │   │  PrivateMetaTxRelay (EIP-712/ERC-2771) │  ← open relay       │   │
│  │   │                                        │                      │   │
│  │   │  Verifies EIP-712 signatures, appends  │                      │   │
│  │   │  original signer to calldata, forwards │                      │   │
│  │   │  to PrivateComboStorage as trusted     │                      │   │
│  │   │  forwarder. Any group member can call. │                      │   │
│  │   │                                        │                      │   │
│  │   │  STATE:                                │                      │   │
│  │   │  • _nonces[address] (per-signer)       │                      │   │
│  │   │                                        │                      │   │
│  │   │  CONSTANTS: ADMIN, PRIVATE_COMBO_STORAGE│                     │   │
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

| Layer                           | Contract                                          | State Owned                                                                                                                                                 | Responsibility                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Public Registry / Mirror**    | CodeManager                                       | UID registry, mirrored active/inactive overrides (sparse), terminal REDEEMED marking, governance votes, fee vault balance, privacy group authorization list | UID registration, deterministic ID generation, governance (2/3 supermajority), public mirrored UID state, and Pente routing. Only UIDs with mirroring enabled in PrivateComboStorage propagate state changes here — absence of a public override (USE_DEFAULT_ACTIVE_STATE) may indicate private-only management.                                                                                                                                                                                                                                                    |
| **Public Authority**            | Gift Contract (IRedeemable)                       | Token ownership, frozen/unfrozen flags, redeemed status (token holder ≠ vault), metadata URI                                                                | Authority on redemption side effects and asset transfer. Decides how redemption works (single-use, multi-use, NFT transfer, etc.). Called by CodeManager via try/catch — reverts are caught and logged as RedemptionFailed events, not propagated. The UID remains terminally REDEEMED at every layer regardless. Recovery via `syncRedemption`.                                                                                                                                                                                                                     |
| **Private Proxy**               | TransparentUpgradeableProxy (OZ 5.2)              | None (delegates all storage to implementation)                                                                                                              | Entry point for all private contract interactions. Delegates to the current PrivateComboStorage implementation via `delegatecall`. All state lives in the proxy's storage slots. Enables upgrades without redeployment.                                                                                                                                                                                                                                                                                                                                              |
| **Private Storage / Execution** | PrivateComboStorage (implementation behind proxy) | Code hashes, PIN→bucket mappings, per-UID active/inactive state, per-UID mirror flags, per-UID manager delegation, contract-identifier whitelist            | Hash-only code storage within a Pente privacy group. PINs are contract-assigned routing keys (not part of the hash). Verifies codes via hash comparison, tracks execution-time UID active state privately, and selectively mirrors valid status changes to CodeManager based on per-UID `mirrorStatuses` configuration. Supports per-UID manager delegation for fine-grained active-state control. Requires contract-identifier whitelisting before codes can be stored. All configuration is compile-time constants — changes require a contract upgrade via proxy. Implements ERC-2771 trusted forwarder pattern: when called by `TRUSTED_FORWARDER` (PrivateMetaTxRelay), `_msgSender()` extracts the original signer from the last 20 bytes of calldata, preserving authorization semantics for meta-transactions. |
| **Private Meta-Tx Relay**       | PrivateMetaTxRelay (standalone or behind proxy)   | Per-signer nonces (`_nonces[address]`)                                                                                                                      | Open EIP-712/ERC-2771 meta-transaction relay. Verifies off-chain EIP-712 `ForwardRequest` signatures, increments nonces for replay protection, and forwards calls to PrivateComboStorage with the original signer appended as the last 20 bytes of calldata (ERC-2771). The relay itself enforces no caller restrictions — authorization is entirely delegated to PrivateComboStorage's access control (`_msgSender()` recovers the signer, which must be ADMIN, AUTHORIZED, or a per-UID manager). Supports both single `execute()` (reverts on failure) and batched `executeBatch()` (skip-and-report). |
| **Private Admin**               | ProxyAdmin (auto-deployed by OZ 5.2)              | Ownership (owner = Paladin signer)                                                                                                                          | Controls upgrade authority for the proxy. Only the ProxyAdmin can call `upgradeAndCall` on the proxy. Owned by the Paladin signer — external EOAs cannot call upgrade directly.                                                                                                                                                                                                                                                                                                                                                                                      |

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

### Complete Contract Flow

This section maps every function, the state it reads/writes, the cross-contract calls it produces, and the gas efficiency decisions behind the design.

#### Registration Flow (Public — CodeManager + Gift Contract)

```
Admin                         Gift Contract                     CodeManager
     │                              │                                │
     │  setMaxSaleSupply(newSupply)  │                                │
     │  msg.value = regFee * delta   │                                │
     │─────────────────────────────▶│                                │
     │                              │  registrationFee()  [view]     │
     │                              │───────────────────────────────▶│
     │                              │◀───────────────────────────────│
     │                              │                                │
     │                              │  getIdentifierCounter(this,    │
     │                              │    chainId)  [view]            │
     │                              │───────────────────────────────▶│
     │                              │◀── (contractIdentifier, ctr)──│
     │                              │                                │
     │                              │  require(ctr == _totalMinted)  │
     │                              │  [counter drift check]         │
     │                              │                                │
     │                              │  registerUniqueIds{regFee}     │
     │                              │    (this, chainId, qty)        │
     │                              │───────────────────────────────▶│
     │                              │                                │  STATE WRITES:
     │                              │                                │  • _identifierCounter[id] += qty
     │                              │                                │  • _contractIdentifierToData[id]
     │                              │                                │    = {giftContract, chainId}
     │                              │                                │    (only on first registration)
     │                              │                                │  • feeVault.call{regFee}
     │                              │                                │  • refund excess to caller
     │                              │◀───────────────────────────────│
     │                              │                                │
     │                              │  STATE WRITES (Gift Contract):
     │                              │  • _mint(this, startId+i)  ×qty
     │                              │    [ERC721 ownership: token→vault]
     │                              │  • _purchaseSegments.push({
     │                              │      endTokenId, buyer, URI})
     │                              │    [ONE write per batch, not per token]
     │                              │  • _totalMinted = endTokenId
     │                              │
     │◀──────────────────────────────│
     │  BatchPurchased(buyer, startId, qty)
```

**Gas efficiency — Registration:**

| Technique                                    | What It Saves                          | How                                                                                                                                                                                                                                      |
| -------------------------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Counter increment, not per-UID writes        | ~20,000 gas per UID                    | `_identifierCounter += qty` is one SSTORE. No per-UID mapping write at registration time. UIDs are implicitly valid if their counter ≤ the stored maximum.                                                                               |
| Sparse active state (no default writes)      | ~20,000 gas per UID                    | Newly registered UIDs inherit `DEFAULT_ACTIVE_STATE = true` with zero storage. Only deviations (freeze/redeem) consume a slot. The `USE_DEFAULT_ACTIVE_STATE` enum value is 0, so uninitialized mappings naturally return "use default." |
| `_contractIdentifierToData` first-write only | ~20,000 gas on repeat batches          | The gift contract + chainId mapping is only written on the first batch for a contract identifier. Subsequent batches just increment the counter.                                                                                         |
| Purchase segments instead of per-token buyer | ~20,000 gas per token                  | One `_purchaseSegments.push()` per batch regardless of quantity. `cardBuyer(tokenId)` uses O(log n) binary search over the sorted segment array at read time.                                                                            |
| Computed uniqueId ↔ tokenId                  | ~20,000 gas per token, both directions | `_computeUniqueId(tokenId)` concatenates `contractIdentifier + "-" + tokenId`. `_parseTokenId(uniqueId)` extracts the counter. No storage mapping needed. Token ID IS the counter by construction.                                       |
| Derived redeemed state                       | ~20,000 gas per token                  | `isUniqueIdRedeemed` checks `ownerOf(tokenId) != address(this)`. No separate redeemed mapping. The transfer guard `_update` prevents tokens from returning to the vault, so "not in vault" is permanent.                                 |
| Derived frozen state                         | ~20,000 gas per token                  | `isUniqueIdFrozen` reads `!CodeManager.isUniqueIdActive(uid)`. No local frozen mapping on the gift contract — it delegates entirely to CodeManager's sparse overrides.                                                                   |
| Plain `uint256` counter vs Counters lib      | ~2,000 gas per mint                    | Direct `_totalMinted++` instead of OZ `Counters.increment()` saves library overhead.                                                                                                                                                     |
| `unchecked` loop increments                  | ~60 gas per iteration                  | All `for` loops use `unchecked { ++i; }` — safe because loop bounds are known.                                                                                                                                                           |

#### Code Storage Flow (Private — PrivateComboStorage → CodeManager)

```
AUTHORIZED                    PrivateComboStorage              CodeManager (public)
(meta-tx processor)                 (via proxy)
     │                                  │                            │
     │  storeDataBatch(request)         │                            │
     │─────────────────────────────────▶│                            │
     │                                  │                            │
     │               ┌─ Phase 1: _collectValidStoreIndexes ─┐       │
     │               │  For each entry:                      │       │
     │               │  ✗ Zero codeHash → StoreFailed        │       │
     │               │  ✗ Zero entropy → StoreFailed         │       │
     │               │  ✗ Counter == 0 → StoreFailed         │       │
     │               │  ✗ Counter > registeredCount          │       │
     │               │    → StoreFailed                      │       │
     │               │  ✗ Already stored → StoreFailed       │       │
     │               │  ✗ Duplicate in batch → StoreFailed   │       │
     │               │  ✓ Valid → add to validIndexes[]      │       │
     │               └───────────────────────────────────────┘       │
     │                                  │                            │
    │               ┌─ Phase 2: reconstruct uniqueIds ──────┐       │
    │               │  Build uniqueId =                     │       │
    │               │    contractIdentifier-counter         │       │
    │               │  for validIndexes only                │       │
    │               │  No store-time public validation call │       │
     │               └───────────────────────────────────────┘       │
     │                                  │                  STATE READ:
    │                                  │                  • registeredCodeCount ceiling
    │                                  │                  • _knownUniqueIds[hash]
     │                                  │                            │
     │               ┌─ Phase 3: _assignPinsForValidEntries ─┐       │
     │               │  For each valid entry:                │       │
     │               │  • _assignPin(entropy, len, special,  │       │
     │               │    codeHash)                          │       │
     │               │  • Derive PIN from entropy mod space  │       │
     │               │  • If slot full or collision →        │       │
     │               │    chain keccak256(entropy) and retry │       │
     │               │  • O(1) expected, O(retries) worst    │       │
     │               └───────────────────────────────────────┘       │
     │                                  │                            │
     │               ┌─ Phase 4: _persistStoredHashes ───────┐       │
     │               │  STATE WRITES per valid entry:        │       │
     │               │  • pinToHash[pin][codeHash] =         │       │
     │               │    CodeMetadata{contractIdHash,       │       │
     │               │    counter, exists:true}              │       │
     │               │  • pinSlotCount[pin]++                │       │
     │               │  • emit DataStoredStatus(uid, pin)    │       │
     │               └───────────────────────────────────────┘       │
     │                                  │                            │
     │               ┌─ Phase 5: _persistStoredUniqueIdConfig┐       │
     │               │  STATE WRITES per valid entry:        │       │
     │               │  • _knownUniqueIds[uidHash] = true    │       │
     │               │  • IF manager ≠ 0:                    │       │
     │               │    uniqueIdManager[uidHash] = mgr     │       │
     │               │  • IF mirrorStatuses[i] == false:     │       │
     │               │    isUniqueIdStatusMirrorDisabled      │       │
     │               │      [uidHash] = true                 │       │
     │               └───────────────────────────────────────┘       │
     │                                  │                            │
     │◀─────────────────────────────────│                            │
     │  returns assignedPins[]          │                            │
```

**Gas efficiency — Code Storage:**

| Technique                                               | What It Saves                        | How                                                                                                                                                                                                 |
| ------------------------------------------------------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Skip-and-report, not revert                             | Entire batch gas on single bad entry | Invalid entries emit `StoreFailed` events and are excluded from valid arrays. Only valid entries pay for PenteExternalCall + writes. A single bad entry doesn't waste the gas of all valid entries. |
| Compile-time constants in bytecode                      | ~2,100 gas per access (no SLOAD)     | `ADMIN`, `AUTHORIZED`, `CODE_MANAGER`, `MAX_PER_PIN`, `DEFAULT_ACTIVE_STATE` are `constant`/`immutable` — embedded in bytecode, not state trie. Every access is a `PUSH` opcode instead of `SLOAD`. |
| Sparse mirror-disable                                   | ~20,000 gas per mirrored UID         | `isUniqueIdStatusMirrorDisabled` only writes `true` for disabled UIDs. Mirrored UIDs (the common case) have no write — the mapping's default `false` means "mirror is enabled."                     |
| Sparse manager assignment                               | ~20,000 gas per unmanaged UID        | `uniqueIdManager` only writes when `manager ≠ address(0)`. Most UIDs have no dedicated manager — the mapping's default `address(0)` means "ADMIN/AUTHORIZED control."                               |
| Caller-supplied entropy                                 | No on-chain randomness cost          | PIN derivation uses off-chain entropy. No `blockhash`, no oracle call. Collision resolution chains `keccak256(entropy)` — pure computation, no external state.                                      |
| Two-mapping hash storage                                | O(1) lookup                          | `pinToHash[pin][codeHash]` gives direct access. PIN is the bucket key, codeHash is the entry key. No iteration over arrays.                                                                         |
| `unchecked` loop increments                             | ~60 gas per iteration                | All loops use `unchecked { ++i; }`.                                                                                                                                                                 |
| Local validation only (no store-time PenteExternalCall) | Zero base-chain gas at store time    | Store-time validation uses locally synced `registeredCodeCount` ceiling. No PenteExternalCall is emitted during `storeDataBatch` — validation is purely local.                                      |

#### Redemption Flow (Private → Public → Gift Contract)

```
AUTHORIZED                    PrivateComboStorage              CodeManager              Gift Contract
(meta-tx processor)                 (via proxy)                  (public)                 (public)
     │                                  │                            │                        │
     │  redeemCodeBatch(pins,           │                            │                        │
     │    codeHashes, redeemers)        │                            │                        │
     │─────────────────────────────────▶│                            │                        │
     │                                  │                            │                        │
     │        For each entry:           │                            │                        │
     │        ┌─ Validation ────────────┤                            │                        │
     │        │ ✗ Empty PIN → skip      │                            │                        │
     │        │ ✗ Zero hash → skip      │                            │                        │
     │        │ ✗ Zero redeemer → skip  │                            │                        │
     │        │ ✗ Duplicate hash → skip │                            │                        │
     │        │ ✗ No match in           │                            │                        │
     │        │   pinToHash → skip      │                            │                        │
     │        │ ✗ Already REDEEMED      │                            │                        │
     │        │   locally → skip        │                            │                        │
     │        │ ✗ Locally INACTIVE      │                            │                        │
     │        │   → skip                │                            │                        │
     │        │ (skipped entries emit   │                            │                        │
     │        │  RedeemFailed event)    │                            │                        │
     │        └─────────────────────────┤                            │                        │
     │                                  │                            │                        │
     │        ┌─ Commit (per valid) ────┤                            │                        │
     │        │ STATE WRITES:           │                            │                        │
     │        │ • delete pinToHash      │                            │                        │
     │        │   [pin][codeHash]       │                            │                        │
     │        │ • pinSlotCount[pin]--   │                            │                        │
     │        │ • _uniqueIdLocalStatuses│                            │                        │
     │        │   [hash] = REDEEMED     │                            │                        │
     │        │ • emit RedeemStatus     │                            │                        │
     │        └─────────────────────────┤                            │                        │
     │                                  │                            │                        │
     │                                  │  emit PenteExternalCall    │                        │
     │                                  │  (CODE_MANAGER,            │                        │
     │                                  │   recordRedemption(uid,    │                        │
     │                                  │   redeemer))               │                        │
     │                                  │───────────────────────────▶│                        │
     │                                  │                            │                        │
     │                                  │                  PRECONDITION CHECKS:               │
     │                                  │                  (graceful skip — never revert)      │
     │                                  │                  • _trySplitUniqueId(uid)             │
     │                                  │                    → extract contractIdentifier       │
     │                                  │                  • lookup giftContract                │
     │                                  │                    → skip if unregistered             │
     │                                  │                  • validateUniqueId(uid)              │
     │                                  │                    → skip if invalid/out-of-range     │
     │                                  │                  • isUniqueIdActive(uid)              │
     │                                  │                    → skip if inactive/redeemed        │
     │                                  │                  ON SKIP:                             │
     │                                  │                  • emit RedemptionRejected(uid,       │
     │                                  │                    redeemer, reason)                  │
     │                                  │                  • return (no revert)                 │
     │                                  │                            │                        │
     │                                  │                  STATE WRITE:                       │
     │                                  │                  • _uniqueIdStatuses[hash]           │
     │                                  │                    = REDEEMED                        │
     │                                  │                  • emit UniqueIdRedeemed(uid)        │
     │                                  │                            │                        │
     │                                  │                            │  try recordRedemption  │
     │                                  │                            │  (uid, redeemer) ─────▶│
     │                                  │                            │                        │
     │                                  │                            │              STATE READS:
     │                                  │                            │              • _parseTokenId
     │                                  │                            │                [computed,
     │                                  │                            │                 no SLOAD]
     │                                  │                            │              • _ownerOf(tid)
     │                                  │                            │              • ownerOf(tid)
     │                                  │                            │                == vault?
     │                                  │                            │
     │                                  │                            │              STATE WRITES:
     │                                  │                            │              • totalRedeems++
     │                                  │                            │              • _transfer(
     │                                  │                            │                vault→redeemer)
     │                                  │                            │                [ERC721 owner
     │                                  │                            │                 update]
     │                                  │                            │              • emit
     │                                  │                            │                CardRedeemed
     │                                  │                            │◀─────────────────────────│
     │                                  │                            │                        │
     │                                  │                  ON SUCCESS:                        │
     │                                  │                  • emit RedemptionRouted             │
     │                                  │                  ON REVERT:                         │
     │                                  │                  • emit RedemptionFailed             │
     │                                  │                  • UID stays REDEEMED                │
     │                                  │                  • Pente transition preserved        │
     │                                  │                            │                        │
     │◀─────────────────────────────────│                            │                        │
```

**Gas efficiency — Redemption:**

| Technique                               | What It Saves                     | How                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --------------------------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Per-entry PenteExternalCall             | Targeted routing                  | Each valid redemption emits its own `PenteExternalCall` so CodeManager→gift contract routing resolves independently per UID. Failed entries are excluded before the external call is emitted — no wasted base-chain gas on invalid entries.                                                                                                                                                                            |
| Hash deletion frees storage             | ~4,800 gas refund per entry       | `delete pinToHash[pin][codeHash]` zeroes the slot, triggering an EIP-2929 storage refund. Redeemed codes release their private storage.                                                                                                                                                                                                                                                                                |
| O(1) hash-verified lookup               | Constant cost per entry           | `pinToHash[pin][codeHash].exists` is a direct mapping access — no array iteration. PIN is the bucket, hash is the key.                                                                                                                                                                                                                                                                                                 |
| Revert-free recordRedemption            | Prevents ALL Pente rollback       | `recordRedemption` never reverts on precondition failures (invalid UID, unregistered identifier, inactive/redeemed). It emits `RedemptionRejected` and returns gracefully. Gift contract failures are caught via try/catch with `RedemptionFailed`. This guarantees every `PenteExternalCall` succeeds from Pente's perspective — private state changes (hash deletion, local REDEEMED marking) are never rolled back. |
| Sparse REDEEMED write on CodeManager    | One SSTORE per redemption         | `_uniqueIdStatuses[hash] = REDEEMED` writes exactly one slot. No array operations, no counter updates.                                                                                                                                                                                                                                                                                                                 |
| No per-token redeemed mapping (Gift)    | Zero writes for redeemed tracking | Redeemed is derived from `ownerOf(tokenId) != address(this)`. The `_transfer` call already writes the new owner — no separate `isRedeemed[tokenId] = true` needed.                                                                                                                                                                                                                                                     |
| Transfer guard instead of redeemed flag | Zero additional storage           | `_update` override prevents tokens from returning to the vault. This makes "not in vault" a permanent, unforgeable redeemed signal — no separate mapping needed.                                                                                                                                                                                                                                                       |

#### Active State Management Flow (Private → Selective Public Mirror)

```
ADMIN / AUTHORIZED /          PrivateComboStorage              CodeManager (public)
Per-UID Manager                     (via proxy)
     │                                  │                            │
     │  setUniqueIdActiveBatch(         │                            │
     │    uniqueIds, activeStates)      │                            │
     │─────────────────────────────────▶│                            │
     │                                  │                            │
     │        For each entry:           │                            │
     │        ┌─ Validation ────────────┤                            │
     │        │ ✗ Empty uid → skip      │                            │
     │        │ ✗ Invalid format → skip │                            │
     │        │ ✗ Not whitelisted → skip│                            │
     │        │ ✗ Unknown uid → skip    │                            │
     │        │ ✗ Not authorized → skip │                            │
     │        │   (must be ADMIN,       │                            │
     │        │    AUTHORIZED, or       │                            │
     │        │    the UID's manager)   │                            │
     │        │ ✗ Already REDEEMED      │                            │
     │        │   → skip                │                            │
     │        │ ✗ Duplicate in batch    │                            │
     │        │   → skip                │                            │
     │        └─────────────────────────┤                            │
     │                                  │                            │
     │        ┌─ Commit (per valid) ────┤                            │
     │        │ IF active == DEFAULT:   │                            │
     │        │   delete local status   │                            │
     │        │   (gas refund)          │                            │
     │        │ ELSE:                   │                            │
     │        │   set INACTIVE          │                            │
     │        │                         │                            │
     │        │ IF mirror enabled:      │                            │
     │        │   add to mirrored[]     │                            │
     │        │ (mirror-disabled UIDs   │                            │
     │        │  remain privately       │                            │
     │        │  managed only)          │                            │
     │        └─────────────────────────┤                            │
     │                                  │                            │
     │                                  │  IF mirrored count > 0:    │
     │                                  │  emit PenteExternalCall    │
     │                                  │  (CODE_MANAGER,            │
     │                                  │   setUniqueIdActiveBatch   │
     │                                  │   (mirroredUids, states))  │
     │                                  │───────────────────────────▶│
     │                                  │                            │
     │                                  │                  STATE PER UID:
     │                                  │                  • IF active == DEFAULT:
     │                                  │                    delete override
     │                                  │                    (gas refund)
     │                                  │                  • ELSE:
     │                                  │                    set INACTIVE
     │                                  │                            │
     │◀─────────────────────────────────│                            │
```

**Gas efficiency — Active State:**

| Technique                                   | What It Saves                       | How                                                                                                                                                                                                                                                                                      |
| ------------------------------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sparse defaults (delete on re-activate)     | ~4,800 gas refund per re-activation | When `activeState == DEFAULT_ACTIVE_STATE`, both PrivateComboStorage and CodeManager `delete` the status mapping entry instead of writing `true`. The uninitialized slot naturally returns `USE_DEFAULT_ACTIVE_STATE` (enum value 0). Re-activating a frozen UID earns a storage refund. |
| Single PenteExternalCall for mirrored batch | One event vs N events               | Only mirror-enabled UIDs are collected into `mirroredUniqueIds[]`. One `PenteExternalCall` carries all of them. Mirror-disabled UIDs incur zero base-chain gas.                                                                                                                          |
| Assembly array truncation                   | Avoids memory copy                  | `assembly { mstore(arr, newLen) }` truncates the mirrored arrays in-place without allocating new memory or copying elements.                                                                                                                                                             |
| Skip mirror-disabled UIDs                   | Zero gas on base chain              | UIDs with `isUniqueIdStatusMirrorDisabled == true` update private state only. No PenteExternalCall, no CodeManager SSTORE, no event on the base chain.                                                                                                                                   |
| Per-UID manager delegation                  | No governance overhead              | Managers call `setUniqueIdActiveBatch` directly — no vote tally, no supermajority. The `onlyAuthorized` modifier is bypassed for per-UID managers, who are checked inline.                                                                                                               |

#### State Summary by Contract

| Contract                | Storage Slot                                                                 | Written When                                                                   | Read When                                                                      | Gas Notes                                                                                                                   |
| ----------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| **CodeManager**         | `_identifierCounter[id]`                                                     | `registerUniqueIds` (+= qty)                                                   | `validateUniqueId`, `getIdentifierCounter`                                     | One SSTORE per batch, not per UID                                                                                           |
|                         | `_contractIdentifierToData[id]`                                              | `registerUniqueIds` (first batch only)                                         | `getUniqueIdDetails`, `getContractData`                                        | Skipped on repeat batches                                                                                                   |
|                         | `_uniqueIdStatuses[hash]`                                                    | `recordRedemption` (→REDEEMED), `setUniqueIdActiveBatch` (→INACTIVE or delete) | `isUniqueIdActive`, `isUniqueIdRedeemed`, `validateUniqueIdsOrRevert`          | Sparse: never written at registration. Only deviations from default consume storage. Deletes on re-activate for gas refund. |
|                         | `isAuthorizedPrivacyGroup[addr]`                                             | `voteToAuthorizePrivacyGroup` / `voteToDeauthorize...`                         | `onlyAuthorizedPrivacyGroup` modifier                                          | One-time setup                                                                                                              |
|                         | `votersArray`, `_voteTallies`, `hasVoted`                                    | Governance vote functions                                                      | `isVoter`, `getSupermajorityThreshold`                                         | Vote tallies are auto-cleaned on passage/expiry                                                                             |
|                         | `feeVault`, `registrationFee`                                                | Governance                                                                     | `registerUniqueIds`                                                            | Rarely changed                                                                                                              |
| **GreetingCards**       | `_totalMinted`                                                               | `buy` (= endTokenId)                                                           | `buy`, `totalSupply`, `availableSupply`                                        | Plain uint256 — no library overhead                                                                                         |
|                         | `_purchaseSegments[]`                                                        | `buy` (one push per batch)                                                     | `cardBuyer`, `tokenURI`, `_redeemedBaseURIOf`                                  | O(log n) binary search at read time. One write per batch, not per token.                                                    |
|                         | `totalRedeems`                                                               | `recordRedemption`, `syncRedemption` (++)                                      | View only                                                                      | unchecked increment                                                                                                         |
|                         | ERC721 ownership slots                                                       | `_mint` (per token), `_transfer` (redemption)                                  | `ownerOf`, `_ownerOf`                                                          | Standard OZ ERC721 storage                                                                                                  |
|                         | `baseTokenURI`, `_contractURI`                                               | Admin setters                                                                  | `tokenURI`, `contractURI`                                                      | Rarely changed                                                                                                              |
|                         | `pricePerCard`, `maxSaleSupply`, `paused`                                    | Admin setters                                                                  | `buy`                                                                          | Rarely changed                                                                                                              |
|                         | `codeManagerAddress`, `chainId`, `_contractIdentifier`                       | `initialize` (once)                                                            | Multiple                                                                       | Immutable after init                                                                                                        |
| **PrivateComboStorage** | `pinToHash[pin][hash]`                                                       | `storeDataBatch` (write), `redeemCodeBatch` (delete)                           | `redeemCodeBatch` (lookup), `_assignPin` (collision check)                     | Delete on redeem earns gas refund                                                                                           |
|                         | `pinSlotCount[pin]`                                                          | `storeDataBatch` (++), `redeemCodeBatch` (--)                                  | `_assignPin` (capacity check)                                                  |                                                                                                                             |
|                         | `_knownUniqueIds[hash]`                                                      | `storeDataBatch` (= true)                                                      | `storeDataBatch` (dedup), `setUniqueIdActiveBatch`, `setUniqueIdManagersBatch` | Never deleted — UIDs are permanent                                                                                          |
|                         | `_uniqueIdLocalStatuses[hash]`                                               | `redeemCodeBatch` (→REDEEMED), `setUniqueIdActiveBatch` (→INACTIVE or delete)  | `redeemCodeBatch`, `_isUniqueIdActive`, `setUniqueIdActiveBatch`               | Sparse: default 0 = USE_DEFAULT. Delete on re-activate for gas refund.                                                      |
|                         | `isUniqueIdStatusMirrorDisabled[hash]`                                       | `storeDataBatch` (= true, only when disabled)                                  | `setUniqueIdActiveBatch` (skip mirror check)                                   | Sparse: default false = mirror enabled, no write needed                                                                     |
|                         | `uniqueIdManager[hash]`                                                      | `storeDataBatch`, `setUniqueIdManagersBatch`                                   | `setUniqueIdActiveBatch`, `setUniqueIdManagersBatch`                           | Sparse: default 0 = no manager                                                                                              |
|                         | `isWhitelistedContractIdentifier[hash]`                                      | `setContractIdentifierWhitelist`                                               | `storeDataBatch`, `setUniqueIdActiveBatch`                                     | Admin config — rarely changed                                                                                               |
|                         | `registeredCodeCount[hash]`                                                  | `syncRegisteredCodeCountBatch` (monotonic update)                              | `storeDataBatch` (counter ceiling check)                                       | Synced from public CodeManager counter                                                                                      |
|                         | `storedCodeCount[hash]`                                                      | `storeDataBatch` (+= validCount)                                               | Telemetry only                                                                 | Operational tracking — not used for validation                                                                              |
|                         | `_contractIdentifierStrings[hash]`                                           | `setContractIdentifierWhitelist`, `syncRegisteredCodeCountBatch`               | `redeemCodeBatch` (UID reconstruction)                                         | Maps hash → string for UID rebuild at redemption                                                                            |
|                         | `ADMIN`, `AUTHORIZED`, `CODE_MANAGER`, `TRUSTED_FORWARDER`, `MAX_PER_PIN`, `DEFAULT_ACTIVE_STATE` | Never (compile-time constants)                                                 | Every access is `PUSH` opcode                                                  | Zero SLOAD cost — embedded in bytecode. `TRUSTED_FORWARDER` = PrivateMetaTxRelay address for ERC-2771.                      |
| **PrivateMetaTxRelay**  | `_nonces[address]`                                                           | `execute` / `executeBatch` (++ on verified signature)                          | `getNonce` (read), `verify` (read)                                             | One SSTORE per verified meta-transaction request                                                                             |
|                         | `ADMIN`, `PRIVATE_COMBO_STORAGE`                                             | Never (compile-time constants)                                                 | Every access is `PUSH` opcode                                                  | Zero SLOAD cost — embedded in bytecode                                                                                      |

#### Cross-Contract Call Matrix

| Caller              | Target        | Function                     | Trigger                                          | Direction                     |
| ------------------- | ------------- | ---------------------------- | ------------------------------------------------ | ----------------------------- |
| Gift Contract       | CodeManager   | `registrationFee()`          | `setMaxSaleSupply()`                             | Public → Public (view)        |
| Gift Contract       | CodeManager   | `getIdentifierCounter()`     | `setMaxSaleSupply()`                             | Public → Public (view)        |
| Gift Contract       | CodeManager   | `registerUniqueIds{value}()` | `setMaxSaleSupply()`                             | Public → Public (payable)     |
| Gift Contract       | CodeManager   | `isUniqueIdActive()`         | `getCardStatus()`, `isUniqueIdFrozen()`          | Public → Public (view)        |
| Gift Contract       | CodeManager   | `isUniqueIdRedeemed()`       | `syncRedemption()`                               | Public → Public (view)        |
| Gift Contract       | CodeManager   | `validateUniqueId()`         | `isValidUniqueId()`                              | Public → Public (view)        |
| Gift Contract       | CodeManager   | `getUniqueIdDetails()`       | `getDetailsFromCodeManager()`                    | Public → Public (view)        |
| PrivateComboStorage | CodeManager   | `recordRedemption()`         | `redeemCodeBatch()` via PenteExternalCall        | Private → Public              |
| PrivateComboStorage | CodeManager   | `setUniqueIdActiveBatch()`   | `setUniqueIdActiveBatch()` via PenteExternalCall | Private → Public              |
| PrivateMetaTxRelay  | PrivateComboStorage | `*` (any function)     | `execute()` / `executeBatch()` via `.call()` with ERC-2771 appended sender | Private → Private (forwarding) |
| CodeManager         | Gift Contract | `recordRedemption()`         | `recordRedemption()` via try/catch               | Public → Public (IRedeemable) |

---

## 2. Identity & Address Taxonomy

Understanding which address is which is critical. Paladin, Pente, and Besu each surface different addresses in different contexts. Confusing them is the #1 source of failed transactions and authorization errors.

### Address Types

| # | Address Type                       | Example                                            | Where It Appears                                                          | Purpose                                                                                                                                                                                                                                                                                                                                                                            |
| - | ---------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | **Paladin Signer**                 | `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`       | `ptx_resolveVerifier` response; Paladin signer configuration              | The resolved address for a configured Paladin signer identity (e.g., `signer-auto-wallet@paladin-core`). Paladin uses this key to sign all transactions it submits. This is the `msg.sender` inside private contract calls. Must be used as `ADMIN` and `initialOwner`. Also used as `AUTHORIZED` when the meta-transaction processing service runs through the same Paladin node. |
| 2 | **Privacy Group Contract Address** | `0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`       | `pgroup_getGroupById` response; group creation receipt                    | The on-chain address of the Pente privacy group contract on the base ledger. **This is what gets authorized on CodeManager** via `voteToAuthorizePrivacyGroup()`. Not the derived submitter — the group contract address itself.                                                                                                                                                   |
| 3 | **Privacy Group ID**               | `0x10be41b4...acc4ef`                              | `pgroup_createGroup` response; used in all `pgroup_sendTransaction` calls | The unique identifier for the privacy group. Used as the `group` parameter in all Paladin privacy-group API calls. Not the same as the group contract address.                                                                                                                                                                                                                     |
| 4 | **Derived Submitter**              | `0xa907edf98de35db39cdbb42e1a6bdabe7e6c3c1b`       | Paladin logs (`ProcessInFlightTransaction`) when funding is insufficient  | A deterministic address derived by Paladin from the privacy group + signer identity + transaction path. Submits the base-ledger transaction that carries `PenteExternalCall` payloads. **Multiple derived submitters may exist** — one per transaction path (deploy, finalize, store, external-call). Fund the exact address shown in logs.                                        |
| 5 | **Private Implementation Address** | `0xd10b4b8b9afe975c76e87dfa44ef73d820584959`       | `ptx_getTransactionReceiptFull` → `domainReceipt.receipt.contractAddress` | The address of the deployed implementation contract inside the privacy group's state trie. For proxy setups, this is the `_logic` argument to the proxy constructor.                                                                                                                                                                                                               |
| 6 | **Private Proxy Address**          | (dynamically discovered from proxy deploy receipt) | `ptx_getTransactionReceiptFull` for the proxy deploy                      | The address of the `TransparentUpgradeableProxy` inside the privacy group. This is the contract address used as `to` in all subsequent `pgroup_sendTransaction` and `pgroup_call` requests.                                                                                                                                                                                        |
| 7 | **ProxyAdmin Address**             | `0x6c7ea1dc87b0c778b2675735c98acfba94d3e042`       | Discovered from proxy deploy receipt state inspection                     | The auto-deployed `ProxyAdmin` contract created by OpenZeppelin 5.2's `TransparentUpgradeableProxy` constructor. Its `owner()` must be a Paladin-signable address for upgrades to succeed.                                                                                                                                                                                         |
| 8 | **CodeManager (Public)**           | deployed proxy address                             | Public chain                                                              | The `TransparentUpgradeableProxy` address of CodeManager on the base ledger. Hardcoded into `PrivateComboStorage` as `CODE_MANAGER`.                                                                                                                                                                                                                                               |
| 9 | **Gift Contract (Public)**         | deployed proxy address                             | Public chain                                                              | The `TransparentUpgradeableProxy` address of the ERC-721 (or other IRedeemable) contract on the base ledger. Registered on CodeManager via `registerUniqueIds`.                                                                                                                                                                                                                    |

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
setMaxSaleSupply(quantity)     → Set max sale supply; if increasing, registers delta UIDs on CodeManager automatically
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
- `redeemCodeBatch` → emits `PenteExternalCall(CODE_MANAGER, recordRedemption(...))` per entry

Operations that are purely private (e.g., read-only `pgroup_call` queries) do not require gas on the derived submitter.

### 6.2 Multiple Derived Submitters

**Critical lesson from production:** different transaction paths may use different derived submitter addresses. In our deployment, we observed three distinct derived submitters:

| Transaction Path                 | Derived Submitter Address                    | When It Appears                                                                      |
| -------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------ |
| Group initialization / deploy    | `0x68b3b8a4facf8326c645170e005ea144d0246de4` | First contract deployment into the group                                             |
| Deployment finalization          | `0x937e2ac50b1f7a0e60da888a0cba52db29535508` | Transaction finalization after deploy                                                |
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

| Mistake                                                                        | Consequence                                                 |
| ------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| Funded the Paladin signer address instead of the derived submitter             | Transaction remains stuck; signer balance is irrelevant     |
| Funded the privacy group contract address                                      | Transaction remains stuck; group contract does not need gas |
| Funded one derived submitter but another path needs funding                    | Different operations stall at different derived submitters  |
| Assumed the derived submitter from a deploy path is the same as the store path | They are often different addresses                          |

---

## 7. Deploying the Private Implementation Contract

### 7.1 Prerequisites

Before deploying `PrivateComboStorage` (or any implementation contract) into the privacy group:

1. **CodeManager is deployed** on the public chain and its proxy address is known
2. **Privacy group is created** with `externalCallsEnabled: "true"` and verified via `pgroup_getGroupById`
3. **`CODE_MANAGER` constant is set** in the `PrivateComboStorage` source to the CodeManager proxy address
4. **`ADMIN` and `AUTHORIZED` constants are set** to Paladin-signable addresses (see [Section 11](#11-signer--admin-strategy))
5. **`TRUSTED_FORWARDER` constant is set** to the PrivateMetaTxRelay proxy address (if relay is already deployed), or a placeholder address to be updated later via proxy upgrade after relay deployment (see [Section 17](#17-private-meta-transaction-relay--eip-712--erc-2771-architecture))

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
- [ ] `TRUSTED_FORWARDER()` returns the PrivateMetaTxRelay proxy address
- [ ] `isTrustedForwarder(relayProxyAddr)` returns `true`
- [ ] Privacy group has `externalCallsEnabled: "true"` (string) — verified via `pgroup_getGroupById`
- [ ] If using a proxy: `ProxyAdmin.owner()` returns a Paladin-signable address
- [ ] Derived submitter(s) funded for each transaction path
- [ ] PrivateMetaTxRelay: `PRIVATE_COMBO_STORAGE()` returns the PrivateComboStorage proxy address
- [ ] PrivateMetaTxRelay: `domainSeparator()` returns expected value

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

| Model                     | `PrivateComboStorage` (constants)                                                                                                                              | Storage-based auth (alternative)                                         |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| **Flexibility**           | Cannot change after deployment. Fixed at compile time.                                                                                                         | Can be updated via `authorize()` / `transferAdmin()` functions.          |
| **Upgrade path**          | Requires new implementation + proxy upgrade to change roles.                                                                                                   | Role changes are a simple transaction.                                   |
| **Paladin compatibility** | `ADMIN` (admin) and `AUTHORIZED` (meta-tx processor) must be set to Paladin-signable addresses before compilation. If wrong, requires full redeployment cycle. | Roles can be reassigned to any address at runtime.                       |
| **Security**              | Simpler — no runtime mutation surface.                                                                                                                         | More surface area — role management functions must be access-controlled. |
| **Recommended for**       | Stable deployments where roles are known in advance.                                                                                                           | Environments with dynamic API-driven authorization needs.                |

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

The privacy group must be authorized on CodeManager before its `PenteExternalCall` events will be accepted. Without authorization, calls such as `recordRedemption` and `setUniqueIdActiveBatch` from the privacy group will revert with `"Caller is not an authorized privacy group"`.

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

The gift contract registers UIDs when admin increases `maxSaleSupply` via `setMaxSaleSupply(supply)` — the delta is automatically registered on CodeManager. Buyers then mint from the pre-registered supply via `buy()`.

### 12.6 Authorization Order

The complete authorization sequence:

```
1.  Deploy CodeManager + Gift Contract on public chain
2.  Create ext-calls privacy group (pgroup_createGroup with "externalCallsEnabled": "true")
3.  Verify group config (pgroup_getGroupById) and record group contract address
4.  Compile PrivateComboStorage with correct CODE_MANAGER, ADMIN, AUTHORIZED, TRUSTED_FORWARDER constants
      (ADMIN and AUTHORIZED must be Paladin-signable addresses)
      (TRUSTED_FORWARDER = PrivateMetaTxRelay proxy address — set after step 10b or use placeholder + upgrade)
5.  Deploy implementation in privacy group (pgroup_sendTransaction)
6.  Poll receipt for implementation address (ptx_getTransactionReceiptFull)
7.  Deploy proxy with _logic = implementation address, initialOwner = Paladin signer
8.  Poll receipt for proxy address
9.  Verify ProxyAdmin.owner() matches Paladin signer
10. Verify CODE_MANAGER(), ADMIN(), AUTHORIZED(), TRUSTED_FORWARDER() on proxy
10a. Compile PrivateMetaTxRelay with PRIVATE_COMBO_STORAGE = PrivateComboStorage proxy address
10b. Deploy PrivateMetaTxRelay implementation + proxy (same pattern as steps 5-8)
10c. Verify PRIVATE_COMBO_STORAGE(), ADMIN(), domainSeparator() on relay proxy
10d. If TRUSTED_FORWARDER was a placeholder: recompile PrivateComboStorage with real relay address,
       deploy new implementation, upgrade proxy (Section 9)
10e. Verify TRUSTED_FORWARDER() on PrivateComboStorage → relay proxy address
10f. Verify isTrustedForwarder(relayProxyAddr) → true
11. Fund derived submitter(s) as needed (check Paladin logs)
12. Authorize privacy group CONTRACT ADDRESS on CodeManager:
      voteToAuthorizePrivacyGroup(groupContractAddress)
13. Whitelist contract identifier on PrivateComboStorage:
      setContractIdentifierWhitelist([contractId], [true])
14. Register UIDs on CodeManager via setMaxSaleSupply() on the gift contract
15. Configure per-UID options (optional):
      setUniqueIdManagersBatch / setUniqueIdActiveBatch with mirrorStatuses
16. Store codes → storeDataBatch (direct or via relay)
17. Redeem codes → redeemCodeBatch (direct or via relay)
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
              {\"name\":\"contractIdentifier\",\"type\":\"string\"},
              {\"name\":\"counters\",\"type\":\"uint256[]\"},
              {\"name\":\"codeHashes\",\"type\":\"bytes32[]\"},
              {\"name\":\"pinLength\",\"type\":\"uint256\"},
              {\"name\":\"useSpecialChars\",\"type\":\"bool\"},
              {\"name\":\"entropies\",\"type\":\"bytes32[]\"},
              {\"name\":\"uidManagers\",\"type\":\"address[]\"},
              {\"name\":\"mirrorStatuses\",\"type\":\"bool[]\"}]
          }],
          \"outputs\":[{\"name\":\"\",\"type\":\"string[]\"}]
        },
        \"input\":[
          [
            \"<CONTRACT_IDENTIFIER>\",
            [1, 2],
            [\"0xabc123...\", \"0xdef456...\"],
            6,
            false,
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
- `contractIdentifier` — deterministic public identifier already registered on CodeManager
- `counters` — exact pre-registered UID counters to store privately
- `codeHashes` — keccak256(code) hashes computed off-chain
- `pinLength` — batch PIN character length (1-8). Per-batch, not per-contract — different batches for the same `contractIdentifier` can use different PIN lengths, allowing callers to choose their security level per batch (e.g., 4-char PINs for low-friction consumer codes, 8-char PINs with special characters for high-value codes)
- `useSpecialChars` — batch PIN charset choice (alphanumeric-only or alphanumeric + special characters). Per-batch like `pinLength`
- `entropies` — random 32-byte seeds for PIN derivation
- `uidManagers` — optional per-UID manager addresses (zero = no manager)
- `mirrorStatuses` — per-UID public mirror control:
  - `true` → active-state changes mirror to CodeManager publicly
  - `false` → active state stays private; CodeManager returns DEFAULT_ACTIVE_STATE

Before calling `storeDataBatch`, sync the public counter ceiling locally with `syncRegisteredCodeCountBatch`. The function returns `string[] assignedPins` — the contract-assigned PIN for each valid entry. Store these PINs alongside the codes in your off-chain database.

### 13.3 What Happens Inside

`storeDataBatch` executes three phases atomically:

1. **Phase 1 — Local preflight:** Validates arrays, zero hashes, zero entropies, duplicate counters, counters above the locally synced public registration ceiling, and UIDs already stored in private state.

2. **Phase 2 — Deterministic UID reconstruction:** Rebuilds `uniqueId = contractIdentifier-counter` for each valid entry using the submitted counters. Registration must already have occurred publicly. Invalid counters fail locally and never reach a public call.

3. **Phase 3 — Assign PINs and store entries:** For each entry, derives a PIN from that entry's supplied entropy, batch PIN length, and batch charset choice. If a collision occurs (same codeHash at derived PIN, or slot is full at MAX_PER_PIN=32), the entry seed is re-chained via `keccak256(seed)` until an open slot is found — no revert, no information leakage. Stores `(pin, codeHash) → CodeMetadata{ contractIdHash, counter, exists: true }` and emits `DataStoredStatus(uniqueId, assignedPin)` per entry.

4. **Phase 4 — Per-UID configuration:** Records per-UID managers (if provided) and mirror preferences. UIDs with `mirrorStatuses[i] == false` have their `isUniqueIdStatusMirrorDisabled` flag set — future active-state changes via `setUniqueIdActiveBatch()` will update private execution state but will not propagate to CodeManager. Emits `UniqueIdManagerUpdated` and `UniqueIdStatusMirrorUpdated` events as applicable.

### 13.4 Failure Modes

| Failure                                       | Cause                                                                                                    | Fix                                                                      |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `"Array length mismatch"`                     | `counters`, `codeHashes`, `entropies`, `uidManagers`, and `mirrorStatuses` arrays have different lengths | Ensure all per-entry arrays in the StoreBatchRequest are the same length |
| `"Contract identifier not whitelisted"`       | The contract identifier is not approved in PrivateComboStorage                                           | Whitelist the contract identifier first                                  |
| `"Registered count not synced"`               | No public registration ceiling has been synced locally for this contract identifier                      | Call `syncRegisteredCodeCountBatch` first                                |
| `"Zero code hash"`                            | A codeHash is `bytes32(0)`                                                                               | Check your hash computation                                              |
| `"PIN length must be 1-8"`                    | The batch `pinLength` is invalid                                                                         | Use a value between 1 and 8                                              |
| `"Zero entropy"`                              | An entry entropy is `bytes32(0)`                                                                         | Supply random 32 bytes per entry                                         |
| `"Counter must be greater than zero"`         | A submitted UID counter is zero                                                                          | Counters start at 1                                                      |
| `"Counter not registered on CodeManager"`     | A submitted counter exceeds the synced public registration ceiling                                       | Register UIDs publicly first, then sync the ceiling locally              |
| `"Duplicate uniqueId in batch"`               | The same UID appears more than once in a store batch                                                     | Deduplicate before calling                                               |
| `"UniqueId already stored"`                   | The UID was already initialized in private storage                                                       | Do not re-store the same UID                                             |
| `"PIN space exhausted"`                       | 100 retries failed to find an open PIN slot                                                              | Increase PIN length or reduce stored codes                               |
| `"Caller is not an authorized privacy group"` | The privacy group is not authorized on CodeManager                                                       | Call `voteToAuthorizePrivacyGroup`                                       |
| `"Caller is not authorized"`                  | The `from` identity is not `ADMIN` or `AUTHORIZED`                                                       | Update constants and redeploy via upgrade                                |
| `insufficient funds for gas`                  | The derived submitter has no gas                                                                         | Fund the address shown in the error                                      |

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

**Important:** The redeemer address has no bearing on authorization. On-chain access control is determined by `_msgSender()` (which resolves via ERC-2771 to the ForwardRequest signer), not by the redeemer parameter. The user who _requested_ the redemption may differ from both the on-chain signer and the redeemer. See [Section 18](#18-api-level-user-intent-signatures--result-routing) for how the API attributes requests to users via separate intent signatures.

### 14.6 Failure Modes

| Failure                                      | Cause                                                         | Fix                                                                                                |
| -------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `"Array length mismatch"`                    | `pins`, `codeHashes`, and `redeemers` arrays differ in length | Ensure all three arrays are the same length                                                        |
| `"PIN cannot be empty"`                      | Empty PIN string                                              | Provide the PIN                                                                                    |
| `"Hash cannot be zero"`                      | `codeHash` is `bytes32(0)`                                    | Check hash computation                                                                             |
| `"Redeemer cannot be zero address"`          | `redeemer` is `address(0)`                                    | Provide valid redeemer                                                                             |
| `"Invalid PIN or code hash"`                 | No matching entry in private state                            | Wrong PIN, wrong code, or already redeemed                                                         |
| `"Only CodeManager"` (on gift contract)      | CodeManager is not the caller                                 | Privacy group not authorized, or CODE_MANAGER constant is wrong                                    |
| `"Invalid uniqueId"` (on gift contract)      | Token was never minted / uniqueId doesn't parse               | UID registered but token not yet minted via `buy()`                                                |
| `"Not in vault"` (on gift contract)          | Token already redeemed (left the vault)                       | Code was already used                                                                              |
| `"UniqueId is inactive or already redeemed"` | UID publicly marked INACTIVE or REDEEMED                      | CodeManager emits `RedemptionRejected` (no revert). Inspect UID state; admin re-enables or accepts |
| `insufficient funds for gas`                 | Derived submitter out of gas                                  | Fund the address in the error                                                                      |

---

## 15. Troubleshooting Matrix

### Quick Reference

| Symptom                                                                 | Root Cause                                                                                     | Diagnostic                                                                                                                                                | Fix                                                                                                    |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `insufficient funds for gas * price + value: address 0xABC...`          | Derived submitter unfunded                                                                     | The address in the error is the derived submitter — it changes per operation type                                                                         | Send native currency to that exact address; see Section 6 for how to identify all derived submitters   |
| `storeDataBatch` succeeds but public state unchanged                    | `externalCallsEnabled` passed as boolean `true` instead of string `"true"`                     | Recreate group and check the field is a string                                                                                                            | Create new group with `"externalCallsEnabled": "true"` (string). Cannot be fixed after creation.       |
| `OwnableUnauthorizedAccount(0x2B73...)` on `upgradeAndCall`             | ProxyAdmin is owned by the Paladin signer, but you passed an external EOA as `initialOwner`    | Query admin via `pgroup_call` to `admin()` on the ProxyAdmin; compare to signed txn sender                                                                | Redeploy the proxy with the Paladin signer as `initialOwner` — see Section 9                           |
| Transaction deploys but `contractAddress` is ProxyAdmin, not the proxy  | OZ 5.2 `TransparentUpgradeableProxy` constructor auto-deploys ProxyAdmin first                 | Check `ptx_getTransactionReceiptFull` — `.receipt.contractAddress` is the ProxyAdmin, not your proxy. Proxy is in `PentePrivateDeployEvent` states array. | Parse the correct address from the receipt states, not from `contractAddress`                          |
| Deploy reverts immediately with no useful error                         | Used **runtime bytecode** instead of **creation bytecode**                                     | Creation bytecode starts with constructor init logic; runtime bytecode is what `eth_getCode` returns                                                      | Use the full bytecode from the compiler output (artifact JSON `bytecode` field), not the deployed code |
| `ADMIN()` returns a placeholder address                                 | Did not update the constant before compiling                                                   | Placeholder value still in contract                                                                                                                       | Update `ADMIN` in source, recompile, redeploy via proxy upgrade (Section 9)                            |
| `AUTHORIZED()` returns a placeholder address                            | Did not update the constant before compiling                                                   | Placeholder value still in contract                                                                                                                       | Update `AUTHORIZED` in source, recompile, redeploy via proxy upgrade (Section 9)                       |
| `CODE_MANAGER()` returns `0x...c0DE`                                    | Did not update the constant before compiling                                                   | Placeholder value still in contract                                                                                                                       | Update `CODE_MANAGER` in source, recompile, redeploy via proxy upgrade (Section 9)                     |
| `TRUSTED_FORWARDER()` returns placeholder or wrong address              | Did not update the constant before compiling, or relay was deployed after PrivateComboStorage   | Placeholder value or zero address in contract                                                                                                             | Update `TRUSTED_FORWARDER` in source, recompile, redeploy via proxy upgrade (Section 9)                |
| `"Caller is not an authorized privacy group"`                           | Wrong address authorized on CodeManager                                                        | You authorized the derived submitter instead of the **group contract address**                                                                            | Authorize the group contract address, not the derived submitter. See Section 12.                       |
| `"Counter not registered on CodeManager"` during `storeDataBatch`       | Counter exceeds synced `registeredCodeCount` ceiling                                           | Sync via `syncRegisteredCodeCountBatch` after increasing `maxSaleSupply`                                                                                  | Call `syncRegisteredCodeCountBatch` with current CodeManager counter                                   |
| `RedemptionRejected` event on CodeManager                               | UID precondition failed (invalid, unregistered, inactive, or already redeemed on public chain) | Read event `reason` field; no Pente rollback occurred                                                                                                     | Fix root cause; private state is preserved                                                             |
| `"No matching uniqueId found."` during `getUniqueIdDetails()` view call | UID not registered on CodeManager                                                              | Call `validateUniqueId(uid)` — returns false                                                                                                              | Register UIDs first                                                                                    |
| `"Not in vault"` during redemption                                      | Token already redeemed                                                                         | Check `ownerOf(tokenId)` — not the contract address                                                                                                       | Code was already used; cannot re-redeem                                                                |
| `RedemptionFailed` event on CodeManager                                 | Gift contract reverted during `recordRedemption`                                               | Read event `reason` field; check gift contract state                                                                                                      | Fix root cause, then call `syncRedemption(uniqueId, redeemer)` on the gift contract                    |
| `"UniqueId is inactive"` during private redemption                      | Private execution state marks the UID inactive                                                 | Check private status flow and CodeManager mirror                                                                                                          | Re-enable via `setUniqueIdActiveBatch` if appropriate                                                  |
| `"Counter drift: CodeManager out of sync"` during `setMaxSaleSupply()`  | External registration changed the counter                                                      | Check `getIdentifierCounter` on CodeManager                                                                                                               | Ensure only `setMaxSaleSupply()` registers UIDs for this contract                                      |
| `"Payment must equal price"` during `buy()`                             | Incorrect `msg.value`                                                                          | Calculate: `pricePerCard * qty`                                                                                                                           | Send exact amount                                                                                      |
| `"Must send exact registration fee"` during `setMaxSaleSupply()`        | Incorrect `msg.value`                                                                          | Calculate: `registrationFee * delta`                                                                                                                      | Send exact amount                                                                                      |
| Relay `execute()` reverts after forwarding                              | PrivateComboStorage rejected the forwarded call (unauthorized signer)                          | The recovered EIP-712 signer does not match ADMIN, AUTHORIZED, or the UID's manager in PrivateComboStorage                                               | Verify the signing address is authorized for the target function                                       |
| `"Bad signature length"` in relay `executeBatch()`                      | Signature is not exactly 65 bytes                                                              | Check signature encoding (must be r + s + v = 32 + 32 + 1 bytes)                                                                                        | Fix signature encoding                                                                                 |
| `"Expired"` in relay                                                    | `block.timestamp > request.deadline`                                                           | Check Pente block time vs. deadline — Pente timestamps may lag behind wall clock                                                                         | Use a later deadline; verify Pente block time                                                          |
| `"Invalid nonce"` in relay                                              | `request.nonce != _nonces[from]`                                                               | Query `getNonce(from)` on the relay for the current value                                                                                                | Use the current nonce; requests must be submitted in order                                              |
| `"Invalid signature"` in relay                                          | `ecrecover()` did not return `request.from`                                                    | Domain mismatch (wrong chainId, contract address), wrong type hash, or data encoding mismatch                                                            | Verify EIP-712 domain parameters match the deployed relay                                               |
| `TRUSTED_FORWARDER()` returns placeholder address                       | PrivateComboStorage compiled without setting `TRUSTED_FORWARDER` to the relay proxy             | Constant still has placeholder value                                                                                                                      | Recompile with the correct relay proxy address and upgrade via proxy                                    |
| `pgroup_sendTransaction` returns success but no event on public chain   | Group not ext-calls-enabled, or derived submitter unfunded for that specific operation         | Check group config via `pgroup_getGroupById`; check each derived submitter balance (different ops use different submitters)                               | Recreate group with string `"true"` or fund the specific derived submitter shown in logs               |
| Private contract call reverts with no useful message                    | Wrong ABI, function signature, or calling via wrong address (implementation instead of proxy)  | Verify function signature matches contract exactly; verify you're calling the proxy address, not the implementation                                       | Re-check ABI; use the proxy address for all interactions                                               |
| `ptx_resolveVerifier` returns unexpected address                        | You're resolving in the wrong context or using the wrong algorithm                             | Must use `algorithm: "domain:ecdsa"`                                                                                                                      | See Section 2 for the correct call format                                                              |

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

3. **All addresses and limits are compile-time constants.** `ADMIN`, `AUTHORIZED`, `CODE_MANAGER`, `TRUSTED_FORWARDER`, and `MAX_PER_PIN` cannot be changed after deployment. If any is wrong, you must recompile and redeploy via proxy upgrade (Section 9).

4. **Pente runs `shanghai` EVM.** Private contracts must be compiled with `--evm-version shanghai`. Public contracts can use a later EVM version.

5. **Paladin signs as its own internal signer, not as your external EOA.** The resolved Paladin signer address (`0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`) is deterministic per node but not an address you control externally. Any `msg.sender` check inside Pente will see this address. If your contract does `require(msg.sender == ADMIN)`, then `ADMIN` must be set to this Paladin signer address.

6. **Authorize the group contract address on CodeManager.** The address that calls CodeManager during `PenteExternalCall` is the **group contract address** (`0xf3cdb5de53edc04e1aea1a211ac586bb84faf8e4`), not the derived submitter and not the privacy group ID. This is the address you pass to `voteToAuthorizePrivacyGroup`. Getting this wrong produces `"Caller is not an authorized privacy group"`.

7. **OZ 5.2 TransparentUpgradeableProxy auto-deploys ProxyAdmin.** You do NOT deploy ProxyAdmin separately. The proxy constructor does it. The `contractAddress` field in the receipt is actually the ProxyAdmin, not your proxy. Parse the proxy address from `PentePrivateDeployEvent` states instead.

8. **ProxyAdmin is owned by the Paladin signer, not your external EOA.** If you pass an external EOA as `initialOwner` during proxy deployment, that EOA has no signing capability inside Pente. Upgrades will fail with `OwnableUnauthorizedAccount`. Always use the resolved Paladin signer address as `initialOwner`.

9. **Use creation bytecode, not runtime bytecode.** When deploying via `pgroup_sendTransaction`, send the full creation bytecode from the compiler artifact's `bytecode` field. Do NOT use the deployed runtime code that `eth_getCode` returns — it lacks the constructor.

10. **Register UIDs before storing codes.** `storeDataBatch` assumes UIDs were already registered publicly and validates submitted counters against a locally synced `registeredCodeCount` ceiling. Sync that ceiling before storing so invalid counters fail locally.

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
□ PrivateComboStorage compiled with correct ADMIN, AUTHORIZED, CODE_MANAGER, TRUSTED_FORWARDER constants
□ Compiled with --evm-version shanghai
□ Implementation deployed via pgroup_sendTransaction (creation bytecode)
□ Receipt polled, implementation address recorded from PentePrivateDeployEvent
□ TransparentUpgradeableProxy deployed with (implAddr, paladinSigner, initData)
□ Receipt polled, ProxyAdmin and proxy addresses parsed correctly
□ PrivateMetaTxRelay compiled with correct ADMIN, PRIVATE_COMBO_STORAGE constants
□ PrivateMetaTxRelay compiled with --evm-version shanghai
□ PrivateMetaTxRelay implementation deployed via pgroup_sendTransaction
□ PrivateMetaTxRelay proxy deployed with (implAddr, paladinSigner, 0x)
□ PrivateMetaTxRelay: PRIVATE_COMBO_STORAGE() verified → PrivateComboStorage proxy
□ PrivateMetaTxRelay: ADMIN() verified → Paladin signer
□ PrivateMetaTxRelay: domainSeparator() verified
□ TRUSTED_FORWARDER() on PrivateComboStorage verified → PrivateMetaTxRelay proxy
□ isTrustedForwarder(relayProxy) → true
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
□ registeredCodeCount synced on PrivateComboStorage (private)
□ storeDataBatch succeeds → PINs assigned for counters already registered publicly
□ redeemCodeBatch succeeds → recordRedemption routes to gift contract → NFT transferred
□ If using relay: execute() / executeBatch() forwards correctly, _msgSender() returns signer
□ If RedemptionFailed emitted → syncRedemption(uniqueId, redeemer) recovers the NFT transfer
□ tokenURI switches from unredeemed to redeemed metadata
```

### Contract Versions

| Contract                    | Solidity       | EVM Target           | Framework                                    |
| --------------------------- | -------------- | -------------------- | -------------------------------------------- |
| CodeManager                 | >=0.8.2 <0.9.0 | Public chain default | Genesis Upgradeable (custom)                 |
| GreetingCards               | >=0.8.2 <0.9.0 | Public chain default | OpenZeppelin v5.2.0 Upgradeable              |
| PrivateComboStorage         | >=0.8.2 <0.9.0 | shanghai             | None (standalone, ERC-2771 recipient)        |
| PrivateMetaTxRelay          | >=0.8.2 <0.9.0 | shanghai             | None (standalone, EIP-712 / ERC-2771 relay)  |
| TransparentUpgradeableProxy | ^0.8.20        | shanghai             | OpenZeppelin v5.2.0                          |
| ProxyAdmin                  | ^0.8.20        | shanghai             | OpenZeppelin v5.2.0 (auto-deployed by proxy) |

---

## 17. Private Meta-Transaction Relay — EIP-712 / ERC-2771 Architecture

### Implementation Overview

The system implements a full EIP-712 / ERC-2771 meta-transaction relay (`PrivateMetaTxRelay`) deployed inside the Pente privacy group alongside `PrivateComboStorage`. This enables external EOAs (hardware wallets, multisigs, end-user wallets) to sign structured data off-chain while the Paladin signer pays gas and submits the transaction.

**Two-contract pattern:**

| Component | Contract | Role |
|---|---|---|
| **Relay** | `PrivateMetaTxRelay` | Verifies EIP-712 signatures, increments per-signer nonces, appends the recovered signer to calldata (ERC-2771), forwards to `PrivateComboStorage`. Open — any privacy group member can call. |
| **Target** | `PrivateComboStorage` | ERC-2771 trusted forwarder recipient. When `msg.sender == TRUSTED_FORWARDER`, `_msgSender()` extracts the original signer from the last 20 bytes of calldata. All access control (ADMIN, AUTHORIZED, per-UID manager) is enforced against the recovered signer. |

### The Problem with `msg.sender` in Pente

Inside a Paladin Pente privacy group, **every** transaction is signed and submitted by the Paladin-managed internal signer (`signer-auto-wallet@paladin-core`). This means:

- `msg.sender` inside the private contract is always the Paladin signer address (e.g., `0x01d5e8f6aa4650e571acaa8733f46c3d16fa13cb`).
- You cannot distinguish between different external users via `msg.sender`.
- If you hard-code `require(msg.sender == ADMIN)`, only the Paladin signer can pass — not an external EOA.

The meta-transaction relay solves this by verifying **signatures** embedded in the transaction data, recovering the real signer's address, and forwarding it via the ERC-2771 trusted forwarder pattern.

### Architecture Flow

```
External EOA                    Paladin Node                    Pente Privacy Group
     │                               │                               │
     │  1. Sign ForwardRequest       │                               │
     │     (EIP-712 typed data)      │                               │
     │                               │                               │
     │  2. Submit signed payload ──► │                               │
     │                               │  3. pgroup_sendTransaction    │
     │                               │     → relay.execute(          │
     │                               │       request, signature) ──► │
     │                               │                               │
     │                               │                    4. Relay verifies     │
     │                               │                       EIP-712 signature  │
     │                               │                       via ecrecover()    │
     │                               │                               │
     │                               │                    5. Relay calls        │
     │                               │                       PrivateComboStorage│
     │                               │                       with appended     │
     │                               │                       sender (ERC-2771) │
     │                               │                               │
     │                               │                    6. PrivateComboStorage│
     │                               │                       _msgSender()      │
     │                               │                       extracts signer   │
     │                               │                       → enforces        │
     │                               │                       access control    │
```

### Security Model

The security split between the relay and the target contract is intentional and critical:

| Aspect | PrivateMetaTxRelay | PrivateComboStorage |
|---|---|---|
| **Caller restriction** | None — open to any privacy group member | `_msgSender()` must be ADMIN, AUTHORIZED, or per-UID manager |
| **Signature verification** | EIP-712 `ecrecover()` with nonce + deadline | N/A — trusts the relay's ERC-2771 appended sender |
| **Replay protection** | Per-signer monotonic nonces (`_nonces[from]`) | N/A — handled by relay |
| **Deadline enforcement** | `require(block.timestamp <= request.deadline)` | N/A — handled by relay |
| **Malleability protection** | EIP-2 low-s check on signature | N/A — handled by relay |

**Why the relay is open:** The relay's job is to verify that a valid EIP-712 signature exists and forward the recovered signer. It doesn't need to know *who* is submitting — only that the *signature* is valid. PrivateComboStorage decides whether the recovered signer has authority for the requested operation. This separation means any privacy group member can act as a gas-paying relayer for any legitimate signer.

### EIP-712 Domain & ForwardRequest

**EIP-712 Domain:**

```solidity
EIP712Domain(string name, string version, uint256 chainId, address verifyingContract)
```

| Parameter | Value |
|---|---|
| `name` | `"PrivateMetaTxRelay"` |
| `version` | `"1"` |
| `chainId` | Privacy group chain ID (shanghai EVM) |
| `verifyingContract` | PrivateMetaTxRelay proxy address |

**ForwardRequest struct:**

```solidity
struct ForwardRequest {
    address from;       // The original signer's address
    bytes   data;       // ABI-encoded function call for PrivateComboStorage
    uint256 nonce;      // Must match _nonces[from] — consumed on success
    uint256 deadline;   // block.timestamp cutoff — prevents stale execution
}
```

**TypeHash:**

```
ForwardRequest(address from,bytes data,uint256 nonce,uint256 deadline)
```

### PrivateMetaTxRelay Constants

| Constant | Value | Purpose |
|---|---|---|
| `ADMIN` | `0x01d5E8F6aa4650e571acAa8733F46c3d16fa13cB` | Paladin signer. Retained for potential future admin-only relay functions. |
| `PRIVATE_COMBO_STORAGE` | `0x000000000000000000000000000000000000c0b0` | Target contract. All forwarded calls route here. Update via contract upgrade. |

### PrivateMetaTxRelay Functions

**Write functions (open — no caller restriction):**

| Function | Parameters | Behavior |
|---|---|---|
| `execute(request, signature)` | `ForwardRequest calldata`, `bytes calldata` | Verifies signature, increments nonce, forwards call with ERC-2771 appended sender. **Reverts on failure** — atomic single-request execution. Emits `MetaTxExecuted`. |
| `executeBatch(requests[], signatures[])` | `ForwardRequest[] calldata`, `bytes[] calldata` | Batch execution with **skip-and-report** semantics. Each request is independently validated; failures emit `MetaTxFailed` but do not revert the batch. Returns `bool[] successes` and `bytes[] results`. |

**View functions:**

| Function | Returns | Purpose |
|---|---|---|
| `getNonce(address from)` | `uint256` | Current nonce for a signer. Used by off-chain code to construct valid `ForwardRequest`s. |
| `verify(ForwardRequest, bytes)` | `bool` | Dry-run signature verification without consuming nonce. For off-chain pre-validation. |
| `domainSeparator()` | `bytes32` | Computed EIP-712 domain separator. For off-chain signing libraries. |

### PrivateComboStorage ERC-2771 Integration

PrivateComboStorage recognizes the relay as its trusted forwarder via a compile-time constant:

| Constant | Value | Purpose |
|---|---|---|
| `TRUSTED_FORWARDER` | PrivateMetaTxRelay proxy address | When `msg.sender == TRUSTED_FORWARDER`, `_msgSender()` extracts the original signer from the last 20 bytes of calldata instead of using `msg.sender` directly. |

**`_msgSender()` implementation:**

```solidity
function _msgSender() internal view returns (address) {
    if (msg.sender == TRUSTED_FORWARDER && msg.data.length >= 20) {
        return address(bytes20(msg.data[msg.data.length - 20:]));
    }
    return msg.sender;
}
```

All state-modifying functions in PrivateComboStorage call `_msgSender()` (cached as a local `sender` variable for gas efficiency) instead of using `msg.sender` directly. This means the same access control logic works for both:
- **Direct calls** (Paladin signer calls PrivateComboStorage directly → `msg.sender` is the Paladin signer)
- **Relayed calls** (Paladin signer calls relay → relay calls PrivateComboStorage → `_msgSender()` returns the original EIP-712 signer)

### Deployment & Verification

**Prerequisites:**
1. PrivateComboStorage is deployed (implementation + proxy) with `TRUSTED_FORWARDER` set to the PrivateMetaTxRelay proxy address
2. Privacy group is created with `externalCallsEnabled: "true"`

**Deployment steps:**

```
1.  Compile PrivateMetaTxRelay with correct ADMIN and PRIVATE_COMBO_STORAGE constants
      → PRIVATE_COMBO_STORAGE = PrivateComboStorage proxy address inside Pente
      → ADMIN = Paladin signer address
2.  Compile with --evm-version shanghai
3.  Deploy implementation via pgroup_sendTransaction (creation bytecode)
4.  Poll receipt for implementation address
5.  Deploy TransparentUpgradeableProxy with (implAddr, paladinSigner, 0x)
6.  Poll receipt for proxy address
7.  Verify:
      → ADMIN() returns Paladin signer
      → PRIVATE_COMBO_STORAGE() returns PrivateComboStorage proxy address
      → domainSeparator() returns expected value
8.  Verify PrivateComboStorage recognizes the relay:
      → TRUSTED_FORWARDER() returns PrivateMetaTxRelay proxy address
      → isTrustedForwarder(relayProxyAddr) returns true
```

**Verification commands:**

```bash
# Check PRIVATE_COMBO_STORAGE on the relay
# Use same pgroup_call pattern as Section 10, targeting the relay proxy address
# Function: "PRIVATE_COMBO_STORAGE", outputs: [{ type: "address" }]

# Check TRUSTED_FORWARDER on PrivateComboStorage
# Target: PrivateComboStorage proxy address
# Function: "TRUSTED_FORWARDER", outputs: [{ type: "address" }]

# Check isTrustedForwarder
# Target: PrivateComboStorage proxy address
# Function: "isTrustedForwarder", inputs: [{ name: "forwarder", type: "address" }]
# Input: relay proxy address
# Expected: true
```

### Off-Chain Signing Workflow (Client/Backend)

```typescript
// 1. Build the ForwardRequest
const nonce = await relay.getNonce(signerAddress);
const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour

const forwardRequest = {
    from: signerAddress,
    data: comboStorage.interface.encodeFunctionData('storeDataBatch', [request]),
    nonce: nonce,
    deadline: deadline,
};

// 2. Build the EIP-712 typed data
const domain = {
    name: 'PrivateMetaTxRelay',
    version: '1',
    chainId: penteChainId,
    verifyingContract: relayProxyAddress,
};

const types = {
    ForwardRequest: [
        { name: 'from', type: 'address' },
        { name: 'data', type: 'bytes' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
    ],
};

// 3. Sign with the external EOA (hardware wallet, browser wallet, etc.)
const signature = await signer.signTypedData(domain, types, forwardRequest);

// 4. Submit to Paladin — any privacy group member can relay
await paladinClient.invokePrivate({
    group: PENTE_GROUP_ADDRESS,
    to: RELAY_PROXY_ADDRESS,
    function: 'execute',
    args: [forwardRequest, signature],
});
```

### Benefits vs. Direct `msg.sender`

| Aspect            | Direct `msg.sender`          | EIP-712 / ERC-2771 Relay                  |
| ----------------- | ---------------------------- | ----------------------------------------- |
| Admin identity    | Paladin node signer only     | Any external EOA (hardware wallet, etc.)  |
| Multi-user auth   | Not possible — single signer | Each user signs with own key              |
| Key security      | Paladin manages key          | Admin key can be cold storage             |
| Non-repudiation   | All actions look same        | Signatures tied to specific EOAs          |
| Upgrade authority | Must match Paladin signer    | Can be any verified address               |
| Gas payment       | Caller pays                  | Relayer pays — signer needs no gas        |
| Backward compat   | N/A                          | Direct calls still work alongside relayed |

### Failure Modes (Relay-Specific)

| Failure | Cause | Fix |
|---|---|---|
| `"Bad signature length"` | Signature is not exactly 65 bytes (r + s + v) | Check signature encoding |
| `"Expired"` | `block.timestamp > request.deadline` | Use a later deadline; check Pente block time |
| `"Invalid nonce"` | `request.nonce != _nonces[from]` | Query `getNonce(from)` for current value |
| `"Invalid signature"` | `ecrecover` did not return `request.from` | Wrong signer, wrong domain, or data mismatch |
| `"Call failed"` (in `executeBatch`) | PrivateComboStorage reverted (e.g., unauthorized signer) | Check that the recovered signer has appropriate role in PrivateComboStorage |
| Relay `execute()` reverts | PrivateComboStorage rejected the forwarded call | Check `_msgSender()` matches ADMIN, AUTHORIZED, or UID manager for the target function |
| `"Array length mismatch"` | `requests[]` and `signatures[]` have different lengths | Ensure arrays match |
| `"Empty batch"` | Zero-length arrays passed to `executeBatch()` | Provide at least one request |

---

## 18. API-Level User Intent Signatures & Result Routing

### Problem Statement

When multiple end users submit redemption (or store) requests through a shared API, the API batches them into a single on-chain `executeBatch()` call signed by an AUTHORIZED key. The on-chain layer does not know or care which end user requested each entry — `_msgSender()` resolves to the AUTHORIZED batch handler, and the `redeemer` parameter is just an NFT destination address.

This creates a routing problem: **how does the API know which result belongs to which user?** Without attribution, the API cannot deliver per-user responses, events, or error messages.

### Solution: Two-Tier Signature Model

The architecture uses **two separate EIP-712 signature layers** with distinct concerns:

| Concern | Handled by | Where |
|---|---|---|
| Who authorized the batch | AUTHORIZED's EIP-712 ForwardRequest signature | On-chain (PrivateMetaTxRelay verifies) |
| Who requested each entry | End user's EIP-712 intent signature | API-side verification only |
| Result routing | Batch index → user signature mapping | API-side |
| Replay protection (on-chain) | Relay nonces per signer | On-chain |
| Replay protection (API) | Per-user API nonces | API-side |
| Non-repudiation | Both signatures stored | API database |
| Redeemer ≠ signer | `redeemer` is just a parameter | By design |

**Key insight:** The user's intent signature is **never sent on-chain.** It exists purely for API-level attribution, auditability, and result routing. The on-chain contracts are unchanged.

### EIP-712 User Intent Types

The API defines its own EIP-712 domain and typed data structures for user intent signatures. These are independent of the on-chain ForwardRequest types used by PrivateMetaTxRelay.

```typescript
// ── API-Level EIP-712 Domain ──
// NOTE: No verifyingContract — this is verified API-side, not on-chain
const USER_INTENT_DOMAIN = {
    name: 'CryftGreetingCards',
    version: '1',
    chainId: dakotaChainId,  // Use the public chain ID for domain binding
};

// ── Redemption Intent ──
const REDEMPTION_INTENT_TYPES = {
    RedemptionIntent: [
        { name: 'pin', type: 'string' },
        { name: 'codeHash', type: 'bytes32' },
        { name: 'redeemer', type: 'address' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
    ],
};

// ── Store Intent (for code storage operations) ──
const STORE_INTENT_TYPES = {
    StoreIntent: [
        { name: 'uniqueId', type: 'string' },
        { name: 'codeHashes', type: 'bytes32[]' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
    ],
};
```

### Client-Side: Signing an Intent

End users sign their intent in the browser before submitting to the API. This signature proves the request originated from a specific wallet and binds the intent to the user for result routing.

```typescript
// Browser-side: user signs a RedemptionIntent
async function signRedemptionIntent(
    signer: ethers.Signer,
    pin: string,
    codeHash: string,
    redeemer: string,
    nonce: number,
    deadline: number,
    chainId: number,
): Promise<{ intent: RedemptionIntent; signature: string }> {
    const intent = { pin, codeHash, redeemer, nonce, deadline };

    const domain = {
        name: 'CryftGreetingCards',
        version: '1',
        chainId,
    };

    const types = {
        RedemptionIntent: [
            { name: 'pin', type: 'string' },
            { name: 'codeHash', type: 'bytes32' },
            { name: 'redeemer', type: 'address' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
        ],
    };

    const signature = await signer.signTypedData(domain, types, intent);

    return { intent, signature };
}

// Usage:
const nonce = await fetch('/api/intent/nonce?address=' + userAddress).then(r => r.json());
const deadline = Math.floor(Date.now() / 1000) + 600; // 10-minute window

const { intent, signature } = await signRedemptionIntent(
    browserSigner,
    pin,
    codeHash,
    redeemerAddress,
    nonce.value,
    deadline,
    DAKOTA_CHAIN_ID,
);

// Submit to API with the signed intent
await fetch('/api/cards/redeem', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...intent, signature }),
});
```

### API-Side: Verifying Intent Signatures & Building Batches

The API server verifies each user's intent signature via `ecrecover`, tracks the mapping from batch index to user address, then has the AUTHORIZED key sign a single ForwardRequest for the entire batch.

```typescript
import { ethers } from 'ethers';

interface VerifiedIntent {
    userAddress: string;  // Recovered from user's EIP-712 signature
    pin: string;
    codeHash: string;
    redeemer: string;
}

// ── Step 1: Verify user intent signature ──
function verifyRedemptionIntent(
    intent: RedemptionIntent,
    signature: string,
    chainId: number,
): string {
    const domain = {
        name: 'CryftGreetingCards',
        version: '1',
        chainId,
    };

    const types = {
        RedemptionIntent: [
            { name: 'pin', type: 'string' },
            { name: 'codeHash', type: 'bytes32' },
            { name: 'redeemer', type: 'address' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
        ],
    };

    // Recover the signer address from the EIP-712 signature
    const recoveredAddress = ethers.verifyTypedData(domain, types, intent, signature);
    return recoveredAddress;
}

// ── Step 2: Process batch with result routing ──
async function processBatchRedemptions(
    pendingIntents: Array<{ intent: RedemptionIntent; signature: string }>,
    authorizedSigner: ethers.Wallet,  // AUTHORIZED key for on-chain ForwardRequest
    paladinClient: PaladinClient,
    config: { chainId: number; relayAddress: string; penteGroup: string },
): Promise<void> {
    // 2a. Verify each user's intent signature
    const verified: VerifiedIntent[] = [];
    const batchIndexToUser: Map<number, string> = new Map();

    for (const { intent, signature } of pendingIntents) {
        // Check deadline
        if (intent.deadline < Math.floor(Date.now() / 1000)) {
            // Notify user of expired intent via WebSocket
            continue;
        }

        // Check and consume API-level nonce
        const currentNonce = await getNonce(intent);  // from DB
        if (intent.nonce !== currentNonce) {
            continue;  // Stale or replayed intent
        }
        await incrementNonce(intent);  // Consume the nonce

        // Verify EIP-712 signature
        const userAddress = verifyRedemptionIntent(intent, signature, config.chainId);

        const idx = verified.length;
        verified.push({ userAddress, pin: intent.pin, codeHash: intent.codeHash, redeemer: intent.redeemer });
        batchIndexToUser.set(idx, userAddress);
    }

    if (verified.length === 0) return;

    // 2b. Encode the PrivateComboStorage.redeemCodeBatch() call
    const pins = verified.map(v => v.pin);
    const codeHashes = verified.map(v => v.codeHash);
    const redeemers = verified.map(v => v.redeemer);

    const comboStorageInterface = new ethers.Interface(COMBO_STORAGE_ABI);
    const callData = comboStorageInterface.encodeFunctionData(
        'redeemCodeBatch',
        [pins, codeHashes, redeemers],
    );

    // 2c. AUTHORIZED signs a single ForwardRequest for the whole batch
    const nonce = await relay.getNonce(authorizedSigner.address);
    const deadline = Math.floor(Date.now() / 1000) + 3600;

    const forwardRequest = {
        from: authorizedSigner.address,
        data: callData,
        nonce,
        deadline,
    };

    const relayDomain = {
        name: 'PrivateMetaTxRelay',
        version: '1',
        chainId: config.chainId,
        verifyingContract: config.relayAddress,
    };

    const forwardTypes = {
        ForwardRequest: [
            { name: 'from', type: 'address' },
            { name: 'data', type: 'bytes' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
        ],
    };

    const relaySignature = await authorizedSigner.signTypedData(
        relayDomain, forwardTypes, forwardRequest,
    );

    // 2d. Submit to Paladin via the relay
    const txResult = await paladinClient.invokePrivate({
        group: config.penteGroup,
        to: config.relayAddress,
        function: 'execute',
        args: [forwardRequest, relaySignature],
    });

    // 2e. Route results back to each user using the batch index mapping
    for (const [batchIdx, userAddress] of batchIndexToUser) {
        const entryResult = {
            success: txResult.success,
            txHash: txResult.hash,
            batchIndex: batchIdx,
            pin: verified[batchIdx].pin,
            redeemer: verified[batchIdx].redeemer,
        };

        // Deliver result to the specific user who signed the intent
        websocket.to(userAddress).emit('redemptionResult', entryResult);
    }
}
```

### Result Delivery Patterns

The API routes results to users using the batch index → user address mapping established during signature verification.

#### WebSocket (Recommended)

```typescript
// Server-side: user connects with their address
io.on('connection', (socket) => {
    const address = socket.handshake.auth.address;
    socket.join(address);  // Join a room keyed by address
});

// After batch completes, emit to each user's room
websocket.to(userAddress).emit('redemptionResult', {
    success: true,
    txHash: '0x...',
    tokenId: 42,
    card: { name: 'Cryft Birthday Card #42', image: 'ipfs://...', /* ... */ },
    bagCount: 3,
});
```

#### Server-Sent Events (Alternative)

```typescript
// GET /api/events/:address — SSE stream
app.get('/api/events/:address', (req, res) => {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    const listener = (result: RedemptionResult) => {
        res.write(`data: ${JSON.stringify(result)}\n\n`);
    };

    resultEmitter.on(req.params.address, listener);
    req.on('close', () => resultEmitter.off(req.params.address, listener));
});
```

#### Polling (Simplest)

```typescript
// POST /api/cards/redeem returns a requestId
// GET /api/cards/redeem/status/:requestId — poll for result

// Client-side:
const { requestId } = await fetch('/api/cards/redeem', { method: 'POST', body: ... }).then(r => r.json());

const poll = setInterval(async () => {
    const status = await fetch(`/api/cards/redeem/status/${requestId}`).then(r => r.json());
    if (status.completed) {
        clearInterval(poll);
        showRedemptionResult(status.result);
    }
}, 2000);
```

### API Nonce Management

Per-user API nonces prevent replay of intent signatures. These are separate from on-chain relay nonces.

```typescript
// Database table for API-level nonces
// CREATE TABLE user_nonces (address TEXT PRIMARY KEY, nonce INTEGER DEFAULT 0);

async function getNonce(intent: { pin: string; codeHash: string }): Promise<number> {
    // Recover address from intent for nonce lookup
    // OR use a separate address-based nonce endpoint
    const row = await db.query('SELECT nonce FROM user_nonces WHERE address = ?', [address]);
    return row?.nonce ?? 0;
}

async function incrementNonce(intent: { pin: string; codeHash: string }): Promise<void> {
    await db.query(
        'INSERT INTO user_nonces (address, nonce) VALUES (?, 1) ON CONFLICT(address) DO UPDATE SET nonce = nonce + 1',
        [address],
    );
}

// GET /api/intent/nonce?address=0x...
// Returns: { value: 42 }
```

### Complete Flow Sequence

```
┌─────────────────┐      ┌──────────────────┐      ┌───────────────────────┐
│   End User       │      │   API Server      │      │   Blockchain          │
│   (Browser)      │      │   (Batch Handler) │      │   (Pente + Relay)     │
└────────┬────────┘      └────────┬─────────┘      └───────────┬───────────┘
         │                        │                             │
         │  1. signTypedData()    │                             │
         │  (RedemptionIntent)    │                             │
         │───────────────────────▶│                             │
         │  POST /api/cards/redeem│                             │
         │  { intent, signature } │                             │
         │                        │                             │
         │                        │  2. ecrecover → userAddr    │
         │                        │     verify nonce & deadline │
         │                        │     store batchIdx→user map │
         │                        │                             │
         │                        │  3. Collect N intents       │
         │                        │     into batch arrays       │
         │                        │                             │
         │                        │  4. AUTHORIZED signs        │
         │                        │     ForwardRequest          │
         │                        │     (single sig for batch)  │
         │                        │                             │
         │                        │  5. relay.execute()────────▶│
         │                        │     via Paladin             │  6. Relay verifies
         │                        │                             │     AUTHORIZED sig
         │                        │                             │     → forwards to
         │                        │                             │     ComboStorage
         │                        │                             │
         │                        │                             │  7. _msgSender()
         │                        │                             │     = AUTHORIZED
         │                        │                             │     → authorized ✓
         │                        │                             │
         │                        │                             │  8. redeemCodeBatch
         │                        │                             │     executes
         │                        │                             │     → PenteExternalCall
         │                        │                             │     → CodeManager
         │                        │                             │     → NFT transfer
         │                        │                             │
         │                        │◀─ 9. tx result ────────────│
         │                        │                             │
         │                        │  10. Look up batchIdx→user  │
         │                        │      Route result per user  │
         │                        │                             │
         │◀─ 11. WebSocket ──────│                             │
         │   redemptionResult     │                             │
         │   { txHash, tokenId,   │                             │
         │     card: {...} }      │                             │
         │                        │                             │
```

### What Does NOT Change

- **No contract modifications.** The on-chain contracts (PrivateMetaTxRelay, PrivateComboStorage, CodeManager, GreetingCards) are unchanged.
- **On-chain authorization model unchanged.** `_msgSender()` via ERC-2771 must still resolve to ADMIN, AUTHORIZED, or a UID manager. The user's intent signature is never verified on-chain.
- **`redeemer` is still just a parameter.** It specifies the NFT destination address, not the authorization source. The user who signed the intent may or may not be the redeemer.
- **Direct calls still work.** An ADMIN or AUTHORIZED address can still call PrivateComboStorage directly via Paladin without using the relay or the API-level intent signatures.
