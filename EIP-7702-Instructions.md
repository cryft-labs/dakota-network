# EIP-7702 Implementation Guide — Dakota Network (Chain 112311)

## Overview

EIP-7702 is an Ethereum protocol-level feature (part of the **Prague / Pectra** upgrade) that allows Externally Owned Accounts (EOAs) to temporarily delegate their execution to a smart contract. This eliminates the need for separate smart-contract wallets, bundlers, or EntryPoint contracts that ERC-4337 required.

**Key advantages over ERC-4337:**
- No on-chain EntryPoint contract or bundler infrastructure to deploy/run
- No separate smart-contract wallet per user
- EOAs remain first-class — they simply point to a delegation contract when needed
- Fully backward-compatible — EOAs still work normally for regular transactions
- thirdweb treats EIP-7702 as the **default execution mode**

---

## 1. Chain Prerequisites

### 1.1 Besu Version

EIP-7702 requires Pectra (Prague + Electra) fork support in Besu.

| Requirement | Version |
|---|---|
| Minimum Besu version | **≥ 25.3.x** (Pectra support landed in 25.x line) |
| Recommended | **≥ 25.9.0** (Fusaka-ready, which includes Pectra) |
| Current Latest | **26.1.0** |

### 1.2 Genesis Configuration

The genesis file (`Contracts/Genesis/besuGenesis.7z`) has been updated with:

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

> **`"pragueTime": 0`** activates the Prague/Pectra fork (including EIP-7702) from genesis block 0.

### 1.3 Restarting the Network

After updating the genesis file, **all validator nodes** must be restarted with the new genesis. For a fresh network, simply distribute the updated `besuGenesis.json` before the first start. For an existing network, this requires a coordinated hard fork — all nodes must update simultaneously.

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

This makes the EOA *behave* like a smart contract for the duration of calls to it, delegating execution to the specified contract's code while using the EOA's own storage and balance.

### 2.3 No Contracts or Bundlers Needed on Your Chain

Unlike ERC-4337, EIP-7702 does **not** require:
- ❌ EntryPoint contract
- ❌ Bundler node
- ❌ Paymaster contract
- ❌ Account factory contract
- ❌ Smart contract wallet per user

It **does** require:
- ✅ Prague/Pectra fork activated on your chain (done — `pragueTime: 0`)
- ✅ A Besu version that supports Pectra (≥ 25.x)
- ✅ A delegation target contract (only if you want smart-account features like batching, session keys, etc. — thirdweb provides this automatically)

---

## 3. thirdweb Integration

thirdweb handles all EIP-7702 infrastructure. You interact with their API to create wallets, sponsor gas, and execute transactions on chain 112311.

### 3.1 Prerequisites

1. **thirdweb Account** — Sign up at [thirdweb.com](https://thirdweb.com)
2. **Project** — Create a project in the thirdweb dashboard
3. **API Keys** — Obtain:
   - `x-client-id` (public, for frontend SDKs)
   - `x-secret-key` (private, for backend API calls)
4. **RPC Endpoint** — Your Dakota chain RPC must be accessible from thirdweb's infrastructure

### 3.2 Register Custom Chain

In your app code, define chain 112311 so thirdweb knows how to reach it:

```typescript
import { defineChain } from "thirdweb";

const dakotaChain = defineChain({
  id: 112311,
  rpc: "https://your-dakota-rpc-endpoint.com:8545",
  nativeCurrency: {
    name: "Cryft",        // your native token name
    symbol: "CRYFT",      // your native token symbol
    decimals: 18,
  },
  blockExplorers: [],      // add if you have an explorer
});
```

> **Important:** thirdweb's API servers must be able to reach your RPC URL. If your chain is behind a firewall, you'll need to expose an RPC endpoint (with appropriate auth) or use the thirdweb Dedicated Relayer.

### 3.3 Embedded Wallets (In-App Wallets)

thirdweb provides in-app wallets with multiple authentication methods. Users never need to manage private keys.

#### Authentication Methods
- Email / Phone (OTP verification)
- Social OAuth (Google, Apple, Discord, etc.)
- Passkeys (WebAuthn)
- Sign-In with Ethereum (SIWE)
- Guest wallets
- Custom JWT

#### Create a User Wallet (HTTP API)

**Step 1 — Initiate authentication:**
```
POST https://api.thirdweb.com/v1/auth/initiate
Headers:
  x-client-id: <your-project-client-id>
Body:
  { "method": "email", "email": "user@example.com" }
```

**Step 2 — Complete authentication:**
```
POST https://api.thirdweb.com/v1/auth/complete
Headers:
  x-client-id: <your-project-client-id>
Body:
  { "method": "email", "email": "user@example.com", "code": "123456" }
```

**Response** returns a wallet address and JWT token for the user.

#### TypeScript / React Integration

```typescript
import { ThirdwebProvider, ConnectWallet } from "@thirdweb-dev/react";

function App() {
  return (
    <ThirdwebProvider
      clientId="<your-client-id>"
      activeChain={dakotaChain}
    >
      <ConnectWallet />
    </ThirdwebProvider>
  );
}
```

### 3.4 Server Wallets

For backend operations (deploying contracts, admin transactions), create server wallets:

```
POST https://api.thirdweb.com/v1/wallets/server
Headers:
  x-secret-key: <your-project-secret-key>
Body:
  { "identifier": "dakota-admin-wallet" }
```

### 3.5 Gas Sponsorship (Gasless Transactions)

EIP-7702 is the **default execution mode** in the thirdweb API. To sponsor gas for user transactions:

```javascript
fetch("https://api.thirdweb.com/v1/contracts/write", {
  method: "POST",
  headers: {
    "x-secret-key": "<your-project-secret-key>",
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    calls: [
      {
        contractAddress: "<your-contract-address>",
        method: "function yourMethod(uint256 param1)",
        params: [42],
      },
    ],
    chainId: 112311,
    from: "<user-wallet-address>",
  }),
});
```

**Response:**
```json
{
  "result": {
    "transactionIds": ["tx_abc123..."]
  }
}
```

All gas fees are paid by your thirdweb project. The user pays nothing.

### 3.6 Sponsorship Policies

Control which transactions get sponsored via the thirdweb dashboard:

- **Global spend limits** — Cap total gas spend per day/month
- **Chain restrictions** — Only sponsor on chain 112311
- **Contract restrictions** — Only sponsor calls to your deployed contracts
- **Wallet allowlists/blocklists** — Control which wallets can use sponsorship
- **Custom server verifier** — Your backend decides per-transaction

To set up a server verifier, configure your backend URL in the dashboard. thirdweb will call:

```
POST https://your-backend/verify-transaction
Body:
{
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
```

Your backend responds:
```json
{ "isAllowed": true, "reason": "approved" }
```

---

## 4. Integration with Dakota Contracts

### 4.1 Contract Addresses

After deploying your contracts via the proxy pattern, note the deployed addresses:

| Contract | Purpose | Proxy Address |
|---|---|---|
| CodeManager | Manages code redemption & governance | `<proxy_address>` |
| ComboStorage | Stores combo/code data | `<proxy_address>` |
| CryftGreetingCards | NFT greeting cards | `<proxy_address>` |
| GasManager | Gas fee distribution | `<genesis_address>` |
| ValidatorSmartContractAllowList | QBFT validator management | `0x0000...1111` |

### 4.2 Example: Sponsored Code Redemption

A user redeems a code via CodeManager, with gas sponsored by thirdweb:

```javascript
// Backend: sponsor a code redemption for the user
const response = await fetch("https://api.thirdweb.com/v1/contracts/write", {
  method: "POST",
  headers: {
    "x-secret-key": process.env.THIRDWEB_SECRET_KEY,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    calls: [
      {
        contractAddress: "<CodeManager_proxy_address>",
        method: "function redeemCode(string code, uint256 pin)",
        params: ["WELCOME2025", 1234],
      },
    ],
    chainId: 112311,
    from: userWalletAddress,  // user's in-app wallet address
  }),
});
```

### 4.3 Example: Sponsored Greeting Card Mint

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
        contractAddress: "<GreetingCards_proxy_address>",
        method: "function mint(address to, uint256 cardType)",
        params: [userWalletAddress, 1],
      },
    ],
    chainId: 112311,
    from: serverWalletAddress,  // server wallet for minting
  }),
});
```

### 4.4 Batch Transactions

EIP-7702 supports batching multiple calls in a single transaction:

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
        contractAddress: "<CodeManager_proxy_address>",
        method: "function redeemCode(string code, uint256 pin)",
        params: ["WELCOME2025", 1234],
      },
      {
        contractAddress: "<GreetingCards_proxy_address>",
        method: "function mint(address to, uint256 cardType)",
        params: [userWalletAddress, 1],
      },
    ],
    chainId: 112311,
    from: userWalletAddress,
  }),
});
```

---

## 5. Dedicated Relayer (Optional)

For production, consider a thirdweb **Dedicated Relayer** to avoid shared infrastructure:

| Tier | Price | Executors | Chains |
|---|---|---|---|
| Standard | $99/month | 1 wallet | 1 chain |
| Premium | $299/month | 10 wallets | 2 chains |
| Enterprise | Custom | Unlimited | Unlimited |

Set up in dashboard: **Project → Wallets → Dedicated Relayer**

---

## 6. Checklist

- [ ] **Besu ≥ 25.9.0** installed on all validator/RPC nodes
- [ ] **`pragueTime: 0`** in genesis config (done ✅)
- [ ] **Network restarted** with updated genesis
- [ ] **thirdweb account** created with project + API keys
- [ ] **RPC endpoint** exposed and reachable from thirdweb infrastructure
- [ ] **Custom chain** defined in app code (`defineChain({ id: 112311, ... })`)
- [ ] **Sponsorship policies** configured in thirdweb dashboard
- [ ] **Contracts deployed** (CodeManager, ComboStorage, GreetingCards via proxy)
- [ ] **Contract addresses** recorded and used in API calls
- [ ] **Server wallet** created for admin/backend operations
- [ ] **(Optional)** Dedicated Relayer provisioned for production

---

## 7. Architecture Summary

```
┌──────────────────┐     ┌──────────────────────┐     ┌───────────────────┐
│   Frontend App   │────▶│   thirdweb API        │────▶│  Dakota Chain     │
│  (React/TS SDK)  │     │  api.thirdweb.com     │     │  (Besu QBFT)     │
│                  │     │                       │     │  Chain ID: 112311 │
│ • ConnectWallet  │     │ • In-App Wallets      │     │                   │
│ • defineChain()  │     │ • Gas Sponsorship     │     │ • CodeManager     │
│ • Contract calls │     │ • EIP-7702 Execution  │     │ • ComboStorage    │
│                  │     │ • Server Wallets      │     │ • GreetingCards   │
└──────────────────┘     └──────────────────────┘     │ • GasManager      │
                                                       │ • AllowList       │
       ┌──────────────────┐                            └───────────────────┘
       │   Your Backend   │                                     ▲
       │                  │─────────────────────────────────────┘
       │ • Server wallet  │  (direct RPC or via thirdweb API)
       │ • Verify sponsor │
       │ • Admin ops      │
       └──────────────────┘
```

**Flow:**
1. User authenticates via thirdweb (email/social/passkey)
2. thirdweb creates an in-app wallet (EOA) for the user
3. When user triggers a transaction, the app calls `POST /v1/contracts/write`
4. thirdweb constructs an EIP-7702 transaction (type 0x04)
5. The EOA temporarily delegates to thirdweb's smart account implementation
6. Transaction executes on Dakota chain with gas paid by your project
7. User's EOA remains a normal EOA after the transaction

---

## 8. Key Differences from ERC-4337

| Feature | ERC-4337 | EIP-7702 |
|---|---|---|
| On-chain contracts needed | EntryPoint, Account Factory, Paymaster | None (protocol-level) |
| Bundler required | Yes (separate service) | No |
| User wallet type | Smart contract wallet | EOA with delegation |
| Gas overhead | Higher (UserOp validation) | Lower (native tx type) |
| Backward compatibility | Separate from EOAs | EOAs gain smart features |
| Besu fork required | Cancun sufficient | Prague/Pectra required |
| thirdweb support | Legacy mode | Default mode (recommended) |
