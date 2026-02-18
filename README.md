# Dakota Network

Smart contracts, tools, and node configuration for the **Dakota Network** — an enterprise QBFT blockchain built on Hyperledger Besu with Tessera privacy, designed for permissioned environments where a fully public and decentralized network is not required.

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

| Contract | Address | Runtime Size | Purpose |
|----------|---------|-------------|---------|
| **ValidatorSmartContractAllowList** | `0x0000...1111` | 19,850 B | QBFT validator, voter, and root overlord governance |
| **GasManager** | Genesis beneficiary | 13,444 B | Voter-governed gas funding, token burns, and native coin burns |
| **TransparentUpgradeableProxy** | Per-contract | 17,175 B | Multi-party overlord/guardian transparent proxy |
| **ProxyAdmin** | Per-proxy | 3,296 B | Guardian-gated ERC1967 upgrade dispatch |

---

### ValidatorSmartContractAllowList (`0x0000...1111`)

The core governance contract for the QBFT consensus layer. Deployed at genesis address `0x0000000000000000000000000000000000001111`. The initializer (`initialize()`) becomes the first voter — there is no guardian role in this contract, all operations are voter-driven.

#### Access Control

| Role | How Assigned | Powers |
|------|-------------|--------|
| **Voter** | Majority vote of existing voters | All governance actions below |

All state changes require **majority quorum**: `(totalVoterCount / 2) + 1`. The voter pool is the union of local `votersArray[]` and all addresses returned by contracts in `otherVotersArray[]`.

#### Governance Actions (all require voter majority)

| Action | Function | Constraints |
|--------|----------|-------------|
| Add validator | `voteToAddValidator()` | Must not exceed `MAX_VALIDATORS` cap; not already in list |
| Remove validator | `voteToRemoveValidator()` | Must exist in local list |
| Add voter | `voteToAddVoter()` | Must not already be a voter (aggregated) |
| Remove voter | `voteToRemoveVoter()` | `getAllVoters().length > 1` — cannot remove the last voter |
| Add external validator contract | `voteToAddOtherValidatorContract()` | Must be a contract implementing `getValidators()` and `isValidator()` |
| Remove external validator contract | `voteToRemoveOtherValidatorContract()` | Must exist in list |
| Add external voter contract | `voteToAddOtherVoterContract()` | Must implement `getAllVoters()` and `isVoter()` |
| Remove external voter contract | `voteToRemoveOtherVoterContract()` | `votersArray.length > 0 \|\| otherVotersArray.length > 1` — prevents empty voter pool |
| Add root overlord | `voteToAddRootOverlord()` | Not `address(0)`, not already an overlord |
| Remove root overlord | `voteToRemoveRootOverlord()` | Must exist in local list |
| Add external overlord contract | `voteToAddOtherOverlordContract()` | Must implement `getRootOverlords()` and `isRootOverlord()` |
| Remove external overlord contract | `voteToRemoveOtherOverlordContract()` | Must exist in list |
| Change max validators | `voteToChangeMaxValidators()` | 1 to `uint32.max` |
| Change vote tally block threshold | `voteToUpdateVoteTallyBlockThreshold()` | 1 to 100,000 blocks |

#### Vote Tally Mechanics

- Each vote type + target pair has an independent tally with a start block.
- Votes expire after `voteTallyBlockThreshold` blocks (default: 1,000, ~50 min at 3s blocks).
- Expired tallies auto-reset on the next vote attempt for that target.
- The quorum threshold is computed dynamically — adding/removing voters during an active tally shifts the required majority for in-flight votes.

#### Federated Expansion (Pluggable External Contracts)

Three categories of external contracts can be plugged in:

| Array | Interface Required | Aggregation Function |
|-------|-------------------|---------------------|
| `otherValidatorContracts[]` | `getValidators()`, `isValidator()` | `getValidators()` — union of local + all external validators |
| `otherVotersArray[]` | `getAllVoters()`, `isVoter()` | `getAllVoters()` — union of local + all external voters |
| `otherOverlordContracts[]` | `getRootOverlords()`, `isRootOverlord()` | `getRootOverlords()` — union of local + all external overlords |

All external calls use `try/catch` — a failing external contract is silently skipped (returns 0 entries), preventing a single broken contract from bricking governance.

#### Permanent Management Revocation

Three independent management domains can be **permanently and irreversibly** revoked via voter majority, delegating all future governance to external contracts:

**1. Overlord Management Revocation** (`voteToRevokeOverlordManagement()`)
- Pre-conditions: `rootOverlords[]` must be empty; `otherOverlordContracts[]` must have ≥1 entry
- Effect: Blocks `ADD_ROOT_OVERLORD`, `REMOVE_ROOT_OVERLORD`, `ADD_OTHER_OVERLORD_CONTRACT`, `REMOVE_OTHER_OVERLORD_CONTRACT`

**2. Validator Management Revocation** (`voteToRevokeValidatorManagement()`)
- Pre-conditions: `validators[]` must be empty; `otherValidatorContracts[]` must have ≥1 entry; `getValidators()` must return ≥4 addresses (aggregated)
- Effect: Blocks `ADD_VALIDATOR`, `REMOVE_VALIDATOR`, `ADD_OTHER_VALIDATOR_CONTRACT`, `REMOVE_OTHER_VALIDATOR_CONTRACT`

**3. Voter Management Revocation** (`voteToRevokeVoterManagement()`) — **must be last**
- Pre-conditions: Overlord management already revoked; validator management already revoked; `votersArray[]` must be empty; `otherVotersArray[]` must have ≥1 entry; `getAllVoters()` must return ≥1 address (aggregated)
- Effect: Blocks `ADD_VOTER`, `REMOVE_VOTER`, `ADD_OTHER_VOTER_CONTRACT`, `REMOVE_OTHER_VOTER_CONTRACT`

Once all three are revoked, this contract's local lists are permanently frozen. All governance is delegated to the listed external contracts. The contract continues to serve aggregation queries (`getValidators()`, `getAllVoters()`, `getRootOverlords()`) combining local (frozen) and external (live) data.

#### Lockout Prevention

| Scenario | Guard |
|----------|-------|
| Remove last voter | `getAllVoters().length > 1` enforced before removal |
| Remove last external voter contract when no local voters | `votersArray.length > 0 \|\| otherVotersArray.length > 1` |
| Revoke voter management with no external voters | Requires `otherVotersArray.length > 0` and `getAllVoters().length >= 1` |
| Revoke validator management with too few validators | Requires `getValidators().length >= 4` (QBFT minimum) |
| Revoke voter management before other domains | Requires overlord + validator management already revoked |
| `address(0)` as voter/validator/overlord | All entry points require `!= address(0)` |

---

### GasManager (Genesis Beneficiary)

Receives all block rewards as the QBFT beneficiary address. Provides voter-governed gas funding, token burns, and native coin burns with a two-phase vote → approve → execute pattern. Uses its own independent voter pool, separate from the validator contract's voters.

#### Access Control

| Role | How Assigned | Powers |
|------|-------------|--------|
| **Voter** | Majority vote of existing voters | Vote on all governance actions |
| **Guardian** | Majority vote of voters | Execute approved funds/burns; execute token and native coin burns. Can be individually added/removed or bulk-cleared via `voteToClearGuardians()`. Enumerable via `getGuardians()` / `getGuardianCount()`. |

#### Two-Phase Operations

Destructive operations (funding, burns) require two phases:

1. **Vote phase**: Voters reach majority quorum on the operation. On passing, a `bytes32` approval key is stored.
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
| Add guardian | `voteToAddGuardian(address)` | Voter majority required; must not already be a guardian |
| Remove guardian | `voteToRemoveGuardian(address)` | Voter majority required; must be an existing guardian |
| Clear all guardians | `voteToClearGuardians()` | Voter majority required; at least 1 guardian must exist |
| List guardians | `getGuardians()` | Returns full `address[]` array |
| Count guardians | `getGuardianCount()` | Returns `uint256` count |

Clearing emits `GuardiansCleared(count)` and resets all guardian mappings and the array in one operation.

#### Configurable Parameters (voter majority)

| Parameter | Default | Function | Constraints |
|-----------|---------|----------|-------------|
| `voteTallyBlockThreshold` | 1,000 blocks | `voteToUpdateVoteTallyBlockThreshold()` | 1 to 100,000 |

#### Native Coin Burns

Voters can burn any amount of the contract's native coin balance via `voteToBurnNativeCoin(amount)` → `executeCoinBurn(amount)`, sending it to `0x...dEaD`. This is the only mechanism for reducing accumulated gas fees — there is no automatic cap or auto-burn.

#### Voter Pool (Independent)

The GasManager has its own local `votersArray[]` and pluggable `otherVotersArray[]`, completely independent from the ValidatorSmartContractAllowList voter pool. External voter contracts must implement `getAllVoters()` and `isVoter()`. Quorum is `(totalVoterCount / 2) + 1`.

#### Lockout Prevention

| Scenario | Guard |
|----------|-------|
| Remove last voter | `getAllVoters().length > 1` enforced before removal |
| Remove last external voter contract when no local voters | `votersArray.length > 0 \|\| otherVotersArray.length > 1` |
| `address(0)` as voter/guardian/recipient | All entry points require `!= address(0)` |
| Clear guardians when none exist | `guardiansArray.length > 0` required |
| Re-entrancy on fund/burn execution | `ReentrancyGuard` modifier on all execute functions |
| Balance discrepancy after fund transfer | Exact balance delta check: `balanceBefore - balanceAfter == _amount` |

#### Upgradeability

GasManager inherits `Initializable` and `ReentrancyGuardUpgradeable` from OpenZeppelin v4.9.0. It includes a `uint256[50] __gap` storage gap for future upgrades. The constructor calls `_disableInitializers()` to prevent re-initialization of the implementation contract.

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
  └── Voter majority governs:
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
```

---

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
