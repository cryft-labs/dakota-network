# EIP-7702 Implementation Guide — Dakota Network (Chain 112311)

> **Purpose:** This document is a self-contained reference for building web applications on the Dakota Network using thirdweb, EIP-7702 delegation, ERC-6551 Token Bound Accounts, and ERC-1155 trait tokens. It includes every contract address, ABI detail, function signature, and integration pattern needed to prompt-generate a full-stack app.

> **PATENT & LICENSING NOTICE**
>
> The redeemable-code management system described in this repository (CodeManager, PrivateComboStorage, and the three-layer Pente privacy architecture) is covered by [U.S. Patent Application Serial No. 18/930,857](https://patents.google.com/patent/US20250139608A1/en). **Implementing, deploying, or operating any substantially similar system requires a license from Cryft Labs.** This documentation is provided for licensed parties. See <https://cryftlabs.org/licenses> for licensing inquiries.

---

## Table of Contents

1. [Chain & Infrastructure](#1-chain--infrastructure)
2. [How EIP-7702 Works](#2-how-eip-7702-works)
3. [On-Chain Contracts](#3-on-chain-contracts)
4. [thirdweb Integration](#4-thirdweb-integration)
5. [ERC-6551 Token Bound Accounts + ERC-1155 Traits](#5-erc-6551-token-bound-accounts--erc-1155-traits)
6. [Gas Sponsorship](#6-gas-sponsorship)
7. [DakotaDelegation Contract Reference](#7-dakotadelegation-contract-reference)
8. [GasSponsor Contract Reference](#8-gassponsor-contract-reference)
9. [Full Web App Architecture](#9-full-web-app-architecture)
10. [Step-by-Step: Sponsored TBA Trait Redemption](#10-step-by-step-sponsored-tba-trait-redemption)
11. [Blockscout Explorer](#11-blockscout-explorer)
12. [Checklist](#12-checklist)
13. [Key Differences from ERC-4337](#13-key-differences-from-erc-4337)

---

## 1. Chain & Infrastructure

### 1.1 Chain Details

| Parameter | Value |
|---|---|
| **Chain ID** | `112311` |
| **Consensus** | QBFT (Proof of Authority) |
| **Block time** | 1 second |
| **Gas limit** | 32,000,000 |
| **Native token** | Cryft (`CRYFT`, 18 decimals) |
| **Client** | Hyperledger Besu |
| **Besu version** | **26.1.0** (recommended) |
| **Activated forks** | All through Prague/Pectra (`pragueTime: 0`) |
| **Privacy** | Paladin (Kubernetes operator, Helm charts) |
| **EIP-7702** | Active from genesis (Prague fork) |
| **Transaction types** | Legacy, EIP-1559, EIP-2930, EIP-4844, **EIP-7702 (0x04)** |

### 1.2 Reserved System Addresses

| Address | Contract | Purpose |
|---|---|---|
| `0x0000000000000000000000000000000000001111` | ValidatorSmartContractAllowList | QBFT validator/voter/overlord governance |
| `0x000000000000000000000000000000000000cafE` | GasManager | Block reward beneficiary, voter-governed gas funding/burns |
| `0x000000000000000000000000000000000000c0DE` | CodeManager | Official Dakota code management service (patent-covered) |
| `0x000000000000000000000000000000000000Face` | ERC-8004 Agent Registry | Official ERC-8004 agent identity contract |
| `0x0000000000000000000000000000000000FacAdE` | ProxyAdmin | Guardian-gated ERC1967 upgrade dispatch |
| `0x00000000000000000000000000000000de1E6A7E` | DakotaDelegation | EIP-7702 delegation target (upgradeable — TransparentUpgradeableProxy) |
| `0x000000000000000000000000000000000000FEeD` | GasSponsor | Gas sponsorship treasury (upgradeable — TransparentUpgradeableProxy) |

### 1.3 Genesis Configuration

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
    "muirGlacierBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "pragueTime": 0,
    "qbft": { ... }
  }
}
```

### 1.4 RPC Configuration

Besu nodes expose:
- **HTTP JSON-RPC:** port `8545`
- **WebSocket:** port `8546`
- **Enabled APIs:** `ETH`, `NET`, `WEB3`, `TXPOOL`, `QBFT`, `ADMIN`

---

## 2. How EIP-7702 Works

### 2.1 New Transaction Type (0x04)

EIP-7702 introduces transaction type `0x04` with an **authorization list**:

```
rlp([
  chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas,
  gas_limit, destination, value, data, access_list,
  authorization_list,   // <-- NEW
  signature_y_parity, signature_r, signature_s
])
```

Each authorization tuple: `[chain_id, address, nonce, y_parity, r, s]`

### 2.2 Delegation Indicator

When an EOA signs an authorization, the protocol sets the EOA's code to:

```
0xef0100 || <delegation_contract_address>
```

This makes the EOA *behave* like a smart contract, delegating execution to the specified contract's code while using the EOA's own storage and balance.

### 2.3 What's Needed vs Not Needed

**NOT required** (unlike ERC-4337):
- ❌ EntryPoint contract
- ❌ Bundler node
- ❌ Paymaster contract (for thirdweb path)
- ❌ Account factory contract
- ❌ Smart contract wallet per user

**Required:**
- ✅ Prague/Pectra fork activated (`pragueTime: 0` — done)
- ✅ Besu **26.1.0**
- ✅ `DakotaDelegation` contract deployed (delegation target)
- ✅ *(Optional)* `GasSponsor` contract for self-hosted gas sponsorship

---

## 3. On-Chain Contracts

### 3.1 Deployed Contract Addresses

> **Fill in proxy addresses after deployment.**

| Contract | Source File | Upgradeable | Proxy Address |
|---|---|---|---|
| **DakotaDelegation** | `Contracts/Genesis/7702/DakotaDelegation.sol` | Yes (TransparentUpgradeableProxy) | `0x...de1E6A7E` (genesis) |
| **GasSponsor** | `Contracts/Genesis/7702/GasSponsor.sol` | Yes (TransparentUpgradeableProxy) | `0x...FEeD` (genesis) |
| **CodeManager** | `Contracts/CodeManagement/CodeManager.sol` | Yes | `<proxy_address>` |
| **CryftGreetingCards** | `Contracts/Tokens/GreetingCards.sol` | Yes | `<proxy_address>` |
| **GasManager** | `Contracts/Genesis/GasManager/GasManager.sol` | Yes | `0x...cafE` (genesis) |
| **ValidatorSmartContractAllowList** | `Contracts/Genesis/ValidatorContracts/` | No | `0x...1111` (genesis) |
| **ProxyAdmin** | `Contracts/Genesis/Upgradeable/Proxy/Transparent/ProxyAdmin.sol` | No | `0x...FacAdE` (genesis) |

### 3.2 ERC-6551 / ERC-1155 Contracts (to deploy)

These are standard contracts you deploy for the TBA + traits pattern:

| Contract | Standard | Purpose |
|---|---|---|
| **NFT Collection** | ERC-721 | The main NFT collection (e.g. characters, avatars, items) |
| **ERC-6551 Registry** | ERC-6551 | Creates Token Bound Accounts for each ERC-721 token |
| **ERC-6551 Account Implementation** | ERC-6551 | The smart account logic each TBA uses |
| **Trait Tokens** | ERC-1155 | Multi-token traits (hats, weapons, skins, attributes) |

#### ERC-6551 Registry Address

The canonical ERC-6551 registry is deployed at the same address on every EVM chain via CREATE2:

```
0x000000006551c19487814612e58FE06813775758
```

If not yet deployed on chain 112311, deploy it using the standard bytecode. thirdweb also offers an ERC-6551 deployment helper.

---

## 4. thirdweb Integration

### 4.1 Prerequisites

1. **thirdweb Account** — Sign up at [thirdweb.com](https://thirdweb.com)
2. **Project** — Create a project in the thirdweb dashboard
3. **API Keys:**
   - `x-client-id` — public, for frontend SDKs
   - `x-secret-key` — private, for backend API calls
4. **RPC Endpoint** — Your Dakota chain RPC must be reachable from thirdweb's infrastructure

### 4.2 Define Custom Chain

```typescript
import { defineChain } from "thirdweb";

const dakotaChain = defineChain({
  id: 112311,
  rpc: "https://your-dakota-rpc-endpoint.com:8545",
  nativeCurrency: {
    name: "Cryft",
    symbol: "CRYFT",
    decimals: 18,
  },
  blockExplorers: [
    {
      name: "Blockscout",
      url: "https://your-blockscout-instance.com",
    },
  ],
});
```

### 4.3 In-App Wallets (Embedded Wallets)

thirdweb creates EOA wallets embedded in your app. Users authenticate via:

| Method | Description |
|---|---|
| Email / Phone | OTP verification |
| Social OAuth | Google, Apple, Discord, X, etc. |
| Passkeys | WebAuthn (biometric / hardware key) |
| SIWE | Sign-In with Ethereum (existing wallet) |
| Guest | Ephemeral wallet, upgradeable later |
| Custom JWT | Your own auth backend |

#### HTTP API Flow

```
POST https://api.thirdweb.com/v1/auth/initiate
Headers: { x-client-id: <client-id> }
Body:    { "method": "email", "email": "user@example.com" }

POST https://api.thirdweb.com/v1/auth/complete
Headers: { x-client-id: <client-id> }
Body:    { "method": "email", "email": "user@example.com", "code": "123456" }

→ Response: { walletAddress: "0x...", jwt: "..." }
```

#### React Integration

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

### 4.4 Server Wallets

For backend operations (deploying contracts, admin transactions):

```
POST https://api.thirdweb.com/v1/wallets/server
Headers: { x-secret-key: <secret-key> }
Body:    { "identifier": "dakota-admin-wallet" }
```

### 4.5 Contract Interaction (Write)

All writes go through the same endpoint. EIP-7702 is the **default execution mode**:

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
        contractAddress: "<contract-address>",
        method: "function methodName(uint256 param1, address param2)",
        params: [42, "0x..."],
      },
    ],
    chainId: 112311,
    from: "<wallet-address>",
  }),
});

// Response: { result: { transactionIds: ["tx_abc123..."] } }
```

### 4.6 Batch Transactions

EIP-7702 natively supports batching multiple calls in one transaction:

```javascript
body: JSON.stringify({
  calls: [
    {
      contractAddress: "<ERC721_address>",
      method: "function approve(address to, uint256 tokenId)",
      params: ["<marketplace>", 1],
    },
    {
      contractAddress: "<marketplace_address>",
      method: "function list(uint256 tokenId, uint256 price)",
      params: [1, "1000000000000000000"],
    },
  ],
  chainId: 112311,
  from: userWalletAddress,
})
```

---

## 5. ERC-6551 Token Bound Accounts + ERC-1155 Traits

### 5.1 Concept

Each ERC-721 NFT gets its own **Token Bound Account** (TBA) via ERC-6551. The TBA is a smart contract wallet owned by whoever holds the parent NFT. ERC-1155 trait tokens (hats, weapons, skins, attributes) are minted or transferred **into** the TBA. When the NFT is sold/transferred, the TBA and all its contents travel with it.

```
┌──────────────────────────────────────────────┐
│  ERC-721 NFT #42 (Character)                 │
│  Owner: 0xAlice                              │
│                                              │
│  ┌──────────────────────────────────────┐    │
│  │  TBA (Token Bound Account)           │    │
│  │  Address: 0xTBA42                    │    │
│  │  Owner: whoever holds NFT #42       │    │
│  │                                      │    │
│  │  Contains:                           │    │
│  │    • ERC-1155 #1 (Fire Sword) ×1     │    │
│  │    • ERC-1155 #7 (Gold Helmet) ×1    │    │
│  │    • ERC-1155 #12 (Speed Boost) ×3   │    │
│  │    • 0.5 CRYFT native balance        │    │
│  └──────────────────────────────────────┘    │
│                                              │
│  If Alice transfers NFT #42 to Bob,          │
│  Bob now controls the TBA and all its        │
│  contents automatically.                     │
└──────────────────────────────────────────────┘
```

### 5.1.1 ERC-8004: Agent Identity (Optional)

For use cases involving **autonomous agents, AI identities, or digital representatives**, ERC-721 tokens can follow the **ERC-8004 (Agent Identity)** standard. ERC-8004 extends ERC-721 with on-chain metadata that binds a token to an agent's identity — capabilities, service endpoints, authentication keys, and delegation policies.

This is relevant when the ERC-721 token doesn't represent a collectible or avatar, but instead represents an **agent** (AI agent, bot, service account, IoT device) that needs a portable, verifiable on-chain identity. The agent's ERC-6551 TBA then becomes the agent's wallet — holding tokens, credentials, and ERC-1155 capability badges.

| Pattern | ERC-721 Represents | TBA Contains |
|---|---|---|
| **Collectible / Avatar** | Character, artwork, PFP | ERC-1155 traits (hats, skins, attributes) |
| **Agent Identity (ERC-8004)** | Autonomous agent, AI, service | ERC-1155 capability tokens, credentials, funds |

> **When to use ERC-8004:** If your ERC-721 tokens represent agents that need discoverable on-chain identity metadata (service endpoints, auth keys, delegation policies), implement ERC-8004 on top of your 721 collection. If your tokens are standard collectibles or game items, standard ERC-721 + ERC-6551 is sufficient.

### 5.2 Contract Deployment Order

1. **Deploy ERC-721 Collection** (your NFT collection)
2. **Deploy ERC-6551 Registry** (if not already on chain — canonical address: `0x000000006551c19487814612e58FE06813775758`)
3. **Deploy ERC-6551 Account Implementation** (the smart account logic TBAs use)
4. **Deploy ERC-1155 Trait Collection** (multi-token traits)
5. **Deploy DakotaDelegation** (EIP-7702 delegation target — already in repo)
6. **Deploy GasSponsor** via proxy (self-hosted gas sponsorship — already in repo)

### 5.3 Creating a TBA for an NFT

```typescript
// Using thirdweb SDK
import { getContract, prepareContractCall, sendTransaction } from "thirdweb";

const ERC6551_REGISTRY = "0x000000006551c19487814612e58FE06813775758";
const ACCOUNT_IMPLEMENTATION = "<your-6551-account-impl-address>";

const registry = getContract({
  client,
  chain: dakotaChain,
  address: ERC6551_REGISTRY,
});

// Create a TBA for NFT tokenId=42 from your ERC-721 collection
const tx = prepareContractCall({
  contract: registry,
  method: "function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId) returns (address)",
  params: [
    ACCOUNT_IMPLEMENTATION,
    "0x0000000000000000000000000000000000000000000000000000000000000000",
    112311n,
    "<ERC721_collection_address>",
    42n
  ],
});

const result = await sendTransaction({ account, transaction: tx });
// The TBA address is deterministic — compute it with:
// registry.account(implementation, salt, chainId, tokenContract, tokenId)
```

#### Compute TBA Address (Read-Only)

```typescript
const tbaAddress = await readContract({
  contract: registry,
  method: "function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId) view returns (address)",
  params: [
    ACCOUNT_IMPLEMENTATION,
    "0x0000000000000000000000000000000000000000000000000000000000000000",
    112311n,
    "<ERC721_collection_address>",
    42n
  ],
});
// tbaAddress = "0x..." — deterministic, same every time
```

### 5.4 Minting Traits into a TBA

```javascript
// Backend: mint ERC-1155 trait tokens directly into the TBA
await fetch("https://api.thirdweb.com/v1/contracts/write", {
  method: "POST",
  headers: {
    "x-secret-key": process.env.THIRDWEB_SECRET_KEY,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    calls: [
      {
        contractAddress: "<ERC1155_traits_address>",
        method: "function mint(address to, uint256 id, uint256 amount, bytes data)",
        params: [tbaAddress, 1, 1, "0x"],  // mint trait #1 into the TBA
      },
    ],
    chainId: 112311,
    from: serverWalletAddress,
  }),
});
```

### 5.5 Redeeming Traits via EIP-7702 Delegation

A user redeems a code that awards ERC-1155 traits to their NFT's TBA. The full flow uses EIP-7702 delegation + gas sponsorship so the user pays nothing:

```javascript
// Sponsored batch: redeem code + mint traits into user's TBA
await fetch("https://api.thirdweb.com/v1/contracts/write", {
  method: "POST",
  headers: {
    "x-secret-key": process.env.THIRDWEB_SECRET_KEY,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    calls: [
      // Step 1: Redeem the code via CodeManager
      {
        contractAddress: "<CodeManager_proxy_address>",
        method: "function redeemCode(string code, uint256 pin)",
        params: ["FIRE-SWORD-2026", 9999],
      },
      // Step 2: Mint the trait into the user's NFT's TBA
      {
        contractAddress: "<ERC1155_traits_address>",
        method: "function mint(address to, uint256 id, uint256 amount, bytes data)",
        params: [tbaAddress, 1, 1, "0x"],
      },
    ],
    chainId: 112311,
    from: userWalletAddress,  // user's in-app wallet — gas is sponsored
  }),
});
```

### 5.6 Reading TBA Contents

```typescript
// Read all ERC-1155 trait balances for a TBA
const traitIds = [1, 2, 3, 4, 5, 7, 12]; // known trait IDs

const balances = await readContract({
  contract: traitsContract,
  method: "function balanceOfBatch(address[] accounts, uint256[] ids) view returns (uint256[])",
  params: [
    traitIds.map(() => tbaAddress),
    traitIds,
  ],
});

// balances = [1n, 0n, 0n, 0n, 0n, 1n, 3n]
// → TBA has: trait #1 ×1, trait #7 ×1, trait #12 ×3
```

### 5.7 Marketplace / Explorer Support

| Platform | ERC-721 | ERC-1155 | ERC-6551 TBA | Custom Chain 112311 |
|---|---|---|---|---|
| **OpenSea** | ✅ | ✅ | ✅ (nested NFT display) | ❌ Not indexed (public chains only) |
| **Blockscout** | ✅ | ✅ | ✅ (shows TBA holdings) | ✅ Self-hosted — full support |
| **thirdweb Dashboard** | ✅ | ✅ | ✅ | ✅ Custom chain supported |

> **Recommendation:** Run a self-hosted **Blockscout** instance for chain 112311. It will correctly display ERC-721 tokens, their TBA addresses, and ERC-1155 trait tokens held within each TBA.

---

## 6. Gas Sponsorship

### 6.1 Two Sponsorship Modes

| Mode | How It Works | When to Use |
|---|---|---|
| **thirdweb hosted** | All gas paid by your thirdweb project via API. No on-chain contract needed. | Production apps with thirdweb integration |
| **Self-hosted (GasSponsor)** | On-chain treasury at `Contracts/Genesis/7702/GasSponsor.sol`. Sponsors deposit CRYFT, relayers claim reimbursement. | Independent sponsorship without thirdweb dependency |

### 6.2 thirdweb Gas Sponsorship

EIP-7702 is the **default execution mode**. Every `POST /v1/contracts/write` call is automatically gas-sponsored by your project.

#### Sponsorship Policies (Dashboard)

Configure in **Project → Wallets → Sponsorship Policies**:

| Policy | Description |
|---|---|
| Global spend limits | Cap total gas spend per day/month |
| Chain restrictions | Only sponsor on chain 112311 |
| Contract restrictions | Only sponsor calls to your deployed contracts |
| Wallet allowlists/blocklists | Control which wallets get sponsorship |
| Custom server verifier | Your backend decides per-transaction |

#### Server Verifier

Configure your backend URL in the dashboard. thirdweb calls:

```
POST https://your-backend/verify-transaction
Body: {
  "clientId": "string",
  "chainId": 112311,
  "userOp": {
    "sender": "0x...",
    "targets": ["0x..."],
    "gasLimit": "string",
    "gasPrice": "string",
    "data": {
      "targets": ["0x..."],
      "callDatas": ["0x..."],
      "values": ["0x..."]
    }
  }
}

Response: { "isAllowed": true, "reason": "approved" }
```

### 6.3 Self-Hosted Gas Sponsorship (GasSponsor Contract)

For independent gas sponsorship without thirdweb:

```solidity
// GasSponsor key functions:
function deposit() external payable;                         // Deposit CRYFT
function withdraw(uint256 amount) external;                  // Withdraw
function authorizeRelayer(address relayer) external;          // Authorize a relayer
function setMaxClaimPerTx(uint256 amount) external;          // Per-claim cap
function setDailyLimit(uint256 amount) external;             // Daily spend cap
function addAllowedTarget(address target) external;          // Restrict to specific contracts
function claim(address sponsor, uint256 amount) external;    // Relayer claims reimbursement
function sponsoredCall(address sponsor, address target,      // Forward call + auto-reimburse
    uint256 value, bytes calldata data) external;
function topOff(address sponsor, uint256 amount) external;   // Guardian pulls GasManager funds
```

**GasSponsor is upgradeable** via TransparentUpgradeableProxy, enabling emergency patches for fund security.

The `topOff` function connects GasSponsor to GasManager: GasManager voters approve a fund, then a GasManager guardian calls `topOff(sponsor, amount)` to pull the approved funds into a sponsor's balance. The GasManager address is hardcoded: `0x000000000000000000000000000000000000cafE`.

---

## 7. DakotaDelegation Contract Reference

**Source:** `Contracts/Genesis/7702/DakotaDelegation.sol`
**Upgradeable:** Yes (Initializable + TransparentUpgradeableProxy)
**Storage:** ERC-7201 namespaced at `keccak256("dakota.delegation.v1")`

### Functions

| Function | Access | Description |
|---|---|---|
| `execute(address, uint256, bytes)` | Owner / Session Key | Execute a single call |
| `executeBatch(Call[])` | Owner / Session Key | Execute multiple calls atomically |
| `executeSponsored(Call[], uint256 nonce, uint256 deadline, bytes sig)` | Anyone (EIP-712 sig required) | Relayer-submitted sponsored execution |
| `addSessionKey(address, uint256 expiry)` | Owner only | Grant limited-time execution rights |
| `removeSessionKey(address)` | Owner only | Revoke a session key |
| `isValidSignature(bytes32, bytes)` | View | EIP-1271 signature validation |
| `getNonce()` | View | Current sponsored-execution nonce |
| `isValidSessionKey(address)` | View | Check if session key is valid and not expired |
| `domainSeparator()` | View | EIP-712 domain separator for this account |

### EIP-712 Domain

```
name:              "DakotaDelegation"
version:           "1"
chainId:           112311
verifyingContract: <the delegating EOA address>
```

### EIP-712 Types

```
Call(address target, uint256 value, bytes data)
ExecuteSponsored(Call[] calls, uint256 nonce, uint256 deadline)
```

### Token Receivers

The delegation target implements:
- `onERC721Received` — accepts ERC-721 `safeTransfer`
- `onERC1155Received` — accepts ERC-1155 single transfers
- `onERC1155BatchReceived` — accepts ERC-1155 batch transfers
- `receive()` — accepts native CRYFT transfers

---

## 8. GasSponsor Contract Reference

**Source:** `Contracts/Genesis/7702/GasSponsor.sol`
**Upgradeable:** Yes (Initializable + TransparentUpgradeableProxy)
**GasManager:** hardcoded at `0x000000000000000000000000000000000000cafE`

### Functions

| Function | Access | Description |
|---|---|---|
| `initialize()` | Once (proxy) | Init ReentrancyGuard |
| `deposit()` | Anyone | Deposit CRYFT as a sponsor |
| `withdraw(uint256)` | Sponsor | Withdraw own balance |
| `authorizeRelayer(address)` | Sponsor | Authorize a relayer |
| `revokeRelayer(address)` | Sponsor | Revoke a relayer |
| `setMaxClaimPerTx(uint256)` | Sponsor | Set per-claim cap (0 = unlimited) |
| `setDailyLimit(uint256)` | Sponsor | Set daily cap (0 = unlimited) |
| `addAllowedTarget(address)` | Sponsor | Restrict to specific targets |
| `removeAllowedTarget(address)` | Sponsor | Remove from target allowlist |
| `disableTargetAllowlist()` | Sponsor | Allow all targets |
| `topOff(address, uint256)` | GasManager Guardian | Pull approved GasManager funds into sponsor balance |
| `claim(address, uint256)` | Authorized Relayer | Claim gas reimbursement |
| `sponsoredCall(address, address, uint256, bytes)` | Authorized Relayer | Forward call + auto-reimburse |
| `getSponsorInfo(address)` | View | Balance, limits, daily spent, flags |
| `isAuthorizedRelayer(address, address)` | View | Check relayer authorization |
| `isAllowedTarget(address, address)` | View | Check target allowlist |

### Events

```solidity
event Deposited(address indexed sponsor, uint256 amount);
event Withdrawn(address indexed sponsor, uint256 amount);
event RelayerAuthorized(address indexed sponsor, address indexed relayer);
event RelayerRevoked(address indexed sponsor, address indexed relayer);
event ConfigUpdated(address indexed sponsor, string param, uint256 value);
event TargetAllowed(address indexed sponsor, address indexed target);
event TargetRemoved(address indexed sponsor, address indexed target);
event Claimed(address indexed sponsor, address indexed relayer, uint256 amount);
event SponsoredCallExecuted(address indexed sponsor, address indexed relayer, address indexed target, uint256 totalCost);
event ToppedOff(address indexed sponsor, uint256 amount);
```

---

## 9. Full Web App Architecture

```
┌─────────────────────┐     ┌────────────────────────┐     ┌───────────────────────┐
│   Frontend App      │────▶│   thirdweb API          │────▶│  Dakota Chain 112311   │
│   (React / Next.js) │     │   api.thirdweb.com      │     │  (Besu QBFT)          │
│                     │     │                          │     │                       │
│ • ConnectWallet     │     │ • In-App Wallets (EOA)   │     │ Contracts:            │
│ • defineChain()     │     │ • EIP-7702 Delegation    │     │ • DakotaDelegation    │
│ • NFT Gallery       │     │ • Gas Sponsorship        │     │ • GasSponsor (proxy)  │
│ • Trait Viewer      │     │ • Server Wallets         │     │ • CodeManager (proxy) │
│ • Code Redemption   │     │ • Batch Execution        │     │ • PrivateComboStorage │
│ • TBA Explorer      │     │                          │     │ • GreetingCards (proxy)│
│                     │     │                          │     │ • GasManager (genesis) │
└─────────────────────┘     └────────────────────────┘     │ • AllowList (genesis)  │
                                                            │ • ProxyAdmin (genesis) │
       ┌─────────────────────┐                              │ • ERC-721 Collection   │
       │   Your Backend      │                              │ • ERC-6551 Registry    │
       │   (Node / Python)   │─────────────────────────────▶│ • ERC-6551 Account Impl│
       │                     │  (direct RPC or thirdweb)    │ • ERC-1155 Traits      │
       │ • Server wallet     │                              └───────────────────────┘
       │ • Verify sponsor    │                                       │
       │ • Mint traits       │                              ┌────────┴──────────┐
       │ • Admin ops         │                              │   Blockscout      │
       │ • Code generation   │                              │   (self-hosted)   │
       └─────────────────────┘                              │   chain explorer  │
                                                            └───────────────────┘
```

### Tech Stack Recommendation

| Layer | Technology |
|---|---|
| Frontend | React / Next.js + thirdweb React SDK |
| Auth | thirdweb In-App Wallets (email / social / passkey) |
| Contract interaction | thirdweb SDK + `POST /v1/contracts/write` |
| Gas sponsorship | thirdweb hosted (primary), GasSponsor contract (fallback) |
| Backend | Node.js / Python + thirdweb server wallet |
| Blockchain | Besu 26.1.0, QBFT, chain 112311 |
| Explorer | Self-hosted Blockscout |
| NFT metadata | IPFS (Pinata / web3.storage) |
| EIP-7702 delegation | DakotaDelegation contract |

---

## 10. Step-by-Step: Sponsored TBA Trait Redemption

This is the full user flow for redeeming a code that awards ERC-1155 traits to an NFT's Token Bound Account, with all gas sponsored.

### 10.1 Prerequisites

- User has an in-app wallet (thirdweb) on chain 112311
- User owns an ERC-721 NFT (`tokenId = 42`)
- A TBA has been created for NFT #42 (address: `0xTBA42`)
- A redemption code exists in CodeManager (e.g. `"FIRE-SWORD-2026"`)
- Your backend has a thirdweb server wallet with `x-secret-key`

### 10.2 Frontend Flow

```typescript
// 1. User enters redemption code in the UI
const code = "FIRE-SWORD-2026";
const pin = 9999;

// 2. Frontend computes the TBA address for the user's selected NFT
const tbaAddress = await readContract({
  contract: registryContract,
  method: "function account(address, bytes32, uint256, address, uint256) view returns (address)",
  params: [ACCOUNT_IMPL, ZERO_SALT, 112311n, COLLECTION_ADDRESS, 42n],
});

// 3. Frontend calls your backend to execute the sponsored redemption
const response = await fetch("/api/redeem", {
  method: "POST",
  body: JSON.stringify({
    code,
    pin,
    userWallet: userAddress,
    tbaAddress,
    tokenId: 42,
  }),
});
```

### 10.3 Backend Flow

```javascript
// /api/redeem handler
export async function POST(req) {
  const { code, pin, userWallet, tbaAddress, tokenId } = await req.json();

  // Validate: user actually owns the NFT
  const owner = await readContract({
    contract: nftCollection,
    method: "function ownerOf(uint256) view returns (address)",
    params: [tokenId],
  });
  if (owner.toLowerCase() !== userWallet.toLowerCase()) {
    return Response.json({ error: "Not the NFT owner" }, { status: 403 });
  }

  // Look up which trait IDs this code awards (from your database)
  const traitRewards = await getCodeRewards(code); // e.g. [{ id: 1, amount: 1 }]

  // Build the batch: redeem code + mint each trait into TBA
  const calls = [
    {
      contractAddress: CODEMANAGER_ADDRESS,
      method: "function redeemCode(string code, uint256 pin)",
      params: [code, pin],
    },
    ...traitRewards.map(({ id, amount }) => ({
      contractAddress: ERC1155_TRAITS_ADDRESS,
      method: "function mint(address to, uint256 id, uint256 amount, bytes data)",
      params: [tbaAddress, id, amount, "0x"],
    })),
  ];

  // Execute via thirdweb — gas is sponsored, user pays nothing
  const result = await fetch("https://api.thirdweb.com/v1/contracts/write", {
    method: "POST",
    headers: {
      "x-secret-key": process.env.THIRDWEB_SECRET_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      calls,
      chainId: 112311,
      from: userWallet,
    }),
  });

  return Response.json(await result.json());
}
```

### 10.4 What Happens On-Chain

1. thirdweb constructs an EIP-7702 type `0x04` transaction
2. The user's EOA temporarily delegates to thirdweb's smart account implementation
3. The batch executes atomically:
   - `CodeManager.redeemCode("FIRE-SWORD-2026", 9999)` — marks the code as redeemed
   - `ERC1155Traits.mint(0xTBA42, 1, 1, 0x)` — mints Fire Sword trait into the TBA
4. Gas is paid by the thirdweb project balance
5. The user's EOA returns to normal (delegation is temporary)

### 10.5 Verifying the Result

```typescript
// Check that the TBA now holds the trait
const balance = await readContract({
  contract: traitsContract,
  method: "function balanceOf(address account, uint256 id) view returns (uint256)",
  params: [tbaAddress, 1],
});
// balance = 1n ✅
```

---

## 11. Blockscout Explorer

### 11.1 Why Blockscout

- **Self-hosted** — runs against any EVM chain, including private chain 112311
- **Full token support** — ERC-20, ERC-721, ERC-1155, ERC-6551 TBAs
- **TBA display** — shows TBA addresses as contract accounts with token holdings
- **Open source** — Docker / Kubernetes deployment

### 11.2 Deployment

```bash
# Docker Compose (quickstart)
git clone https://github.com/blockscout/blockscout.git
cd blockscout/docker-compose

# Configure for Dakota chain
export ETHEREUM_JSONRPC_HTTP_URL=http://your-besu-node:8545
export ETHEREUM_JSONRPC_WS_URL=ws://your-besu-node:8546
export CHAIN_ID=112311
export COIN=CRYFT

docker-compose up -d
```

### 11.3 What You'll See

- **ERC-721 tokens** — each NFT listed with metadata, owner, transfer history
- **ERC-6551 TBAs** — TBA addresses shown as contract accounts
- **TBA holdings** — ERC-1155 trait tokens listed under the TBA's address page
- **ERC-1155 tokens** — each trait type with total supply, holder list, transfer history
- **EIP-7702 transactions** — type 0x04 transactions with delegation details

---

## 12. Checklist

### Infrastructure
- [ ] **Besu 26.1.0** installed on all validator/RPC nodes
- [ ] **`pragueTime: 0`** in genesis config (done ✅)
- [ ] **Network restarted** with updated genesis
- [ ] **Blockscout** self-hosted and indexing chain 112311
- [ ] **RPC endpoint** publicly accessible for thirdweb

### thirdweb Setup
- [ ] **thirdweb account** created with project + API keys
- [ ] **Custom chain** defined (`defineChain({ id: 112311, ... })`)
- [ ] **Sponsorship policies** configured in dashboard
- [ ] **Server wallet** created for backend operations
- [ ] **(Optional)** Dedicated Relayer provisioned

### Contract Deployment
- [ ] **DakotaDelegation** deployed (note address)
- [ ] **GasSponsor** deployed via TransparentUpgradeableProxy (note proxy address)
- [ ] **CodeManager** deployed via proxy (note address)
- [ ] **CryftGreetingCards** deployed via proxy (note address)
- [ ] **ERC-721 Collection** deployed (your NFT collection)
- [ ] **ERC-6551 Registry** deployed or verified at canonical address
- [ ] **ERC-6551 Account Implementation** deployed
- [ ] **ERC-1155 Traits** deployed (multi-token trait collection)
- [ ] All contract addresses recorded in this document (§3.1)

### Integration
- [ ] Frontend connects to chain 112311 via thirdweb SDK
- [ ] Users can authenticate and get in-app wallets
- [ ] NFT minting works with gas sponsorship
- [ ] TBA creation works for each NFT
- [ ] ERC-1155 trait minting into TBAs works
- [ ] Code redemption + trait minting batch flow works
- [ ] Blockscout displays NFTs, TBAs, and trait holdings correctly

---

## 13. Key Differences from ERC-4337

| Feature | ERC-4337 | EIP-7702 |
|---|---|---|
| On-chain contracts needed | EntryPoint, Account Factory, Paymaster | DakotaDelegation only (protocol-level) |
| Bundler required | Yes (separate service) | No |
| User wallet type | Smart contract wallet | EOA with delegation |
| Gas overhead | Higher (UserOp validation) | Lower (native tx type) |
| Backward compatibility | Separate from EOAs | EOAs gain smart features |
| Besu fork required | Cancun sufficient | Prague/Pectra required |
| thirdweb support | Legacy mode | Default mode (recommended) |
| ERC-6551 TBA compatibility | Works (TBA calls through EntryPoint) | Works (TBA calls through delegation) |
| Batch support | Via UserOp calldata | Native in authorization list |
