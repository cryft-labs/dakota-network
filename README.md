# Dakota Network

Smart contracts, tools, and node configuration for the **Dakota Network** — an enterprise QBFT blockchain built on Hyperledger Besu with [Paladin](https://github.com/LFDT-Paladin/paladin) privacy, designed for permissioned environments where a fully public and decentralized network is not required.

All project-owned contracts are licensed under **Apache 2.0**. This software is part of a patented system — see the [LICENSE](LICENSE) file and <https://cryftlabs.org/licenses> for details.

> **PATENT NOTICE — U.S. Patent Application Serial No. 18/930,857**
>
> Portions of this software implement methods and systems described in [U.S. Patent Application Serial No. 18/930,857: *"Card System Utilizing On-Chain Managed Redeemable Gift Code"*](https://patents.google.com/patent/US20250139608A1/en), held by Cryft Labs.
>
> **The patented system covers the on-chain redeemable-code management architecture embodied primarily by the `CodeManager` and `PrivateComboStorage` contracts, including the three-layer Pente privacy integration (CodeManager router + Gift Contract authority + PrivateComboStorage in Pente privacy group).** Unauthorized reproduction, deployment, or commercial use of these contracts or any substantially similar implementation of the patented methods — on any blockchain or network — constitutes patent infringement and **will result in legal action, including injunctive relief and monetary damages, at the infringer's expense.**
>
> **IMPLEMENTATION NOTICE:** The accompanying implementation guide describes a patented architecture. **Implementing, deploying, or operating the described system — including any substantially similar three-layer architecture using a public registry/router, an authoritative gift contract, and a private verification layer — requires a license from Cryft Labs.** The implementation guide and source code are provided for **licensed parties only**. See <https://cryftlabs.org/licenses> for licensing inquiries.
>
> The `CryftGreetingCards` ERC-721 contract is a client of the redeemable-code service and is **not** itself covered by the patent. Third parties may interface with the Cryft redeemable-code service (CodeManager / PrivateComboStorage) under a valid license or when the applicable fees and permissions have been granted. See <https://cryftlabs.org/licenses> for licensing inquiries.

---

## Quick Reference

| Component                | Version | Notes                                                        |
| ------------------------ | ------- | ------------------------------------------------------------ |
| **Besu**                 | 26.1.0  | Java 21, QBFT consensus                                      |
| **solc**                 | 0.8.34  | All contracts except validator contracts                     |
| **solc**                 | 0.8.19  | Validator contracts only (pragma `<0.8.20`)                  |
| **EVM target**           | Osaka   | All contracts compiled with solc 0.8.34                      |
| **EVM target**           | London  | Validator contracts (solc 0.8.19 maximum)                    |
| **Paladin**              | latest  | Pente privacy domain (replaces Tessera)                      |
| **Native sponsorship**   | 1.0.0   | EIP-7702; no ERC-4337, bundler, EntryPoint, or paymaster     |

> **Full installation instructions** — Besu setup, Paladin deployment (Docker / build-from-source / k3s+Helm), genesis configuration, security notes, and documentation references — are in the **[Implementation Guide](IMPLEMENTATION.md#3-layer-1--besu-network-setup)**.

---

## Network Configuration

### Block Timing

| Parameter              | Value         | Notes                                                |
| ---------------------- | ------------- | ---------------------------------------------------- |
| **Block period**       | 1 second      | Time between blocks when transactions are pending    |
| **Empty block period** | 64 seconds    | Time between blocks when no transactions are pending |
| **Epoch length**       | 86,000 blocks | Validator set checkpoint interval                    |
| **Request timeout**    | 86 seconds    | QBFT round-change timeout                            |

### Genesis File Breakdown

The genesis file (`Contracts/Genesis/BesuGenesis.7z`, compressed) contains the full initial state for the network. Extract with 7-Zip before use — the uncompressed JSON is ~1.07 GB.

#### Chain Parameters

| Parameter               | Value                                                                      |
| ----------------------- | -------------------------------------------------------------------------- |
| **Chain ID**            | `112311`                                                                   |
| **Consensus**           | QBFT (Istanbul BFT)                                                        |
| **Gas limit**           | 64,000,000 (`0x3D09000`)                                                   |
| **Block reward**        | 3.2 ETH per block (sent to `miningBeneficiary`)                            |
| **Contract size limit** | 32,768 bytes (32 KiB)                                                      |
| **EVM fork**            | Osaka + BPO2 (all forks through Osaka plus BPO1/BPO2 enabled from genesis) |

#### Ethereum Fork Activation

All Ethereum hard forks through Osaka are activated from genesis (block 0 / timestamp 0), along with BPO1 and BPO2 Blob Parameter Only upgrades. Pre-Merge forks use block-number activation; post-Merge forks use timestamp-based activation per Besu convention. BPO upgrades adjust blob-related parameters (target and maximum blobs per block) without requiring a full hard fork, enabling incremental Layer 2 data throughput scaling.

| Fork               | Genesis Key                         | Activation  | Notable EIPs                                                                                                                    |
| ------------------ | ----------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **Homestead**      | `homesteadBlock: 0`                 | Block 0     | EIP-2 (tx validation), EIP-7 (DELEGATECALL)                                                                                     |
| **EIP-150**        | `eip150Block: 0`                    | Block 0     | Gas cost rebalancing (Tangerine Whistle)                                                                                        |
| **EIP-155/158**    | `eip155Block: 0` / `eip158Block: 0` | Block 0     | Replay protection, state clearing (Spurious Dragon)                                                                             |
| **Byzantium**      | `byzantiumBlock: 0`                 | Block 0     | REVERT opcode, STATICCALL, precompiles                                                                                          |
| **Constantinople** | `constantinopleBlock: 0`            | Block 0     | SHL/SHR/SAR opcodes, CREATE2, EXTCODEHASH                                                                                       |
| **Petersburg**     | `petersburgBlock: 0`                | Block 0     | Removed EIP-1283 (SSTORE re-entrancy fix)                                                                                       |
| **Istanbul**       | `istanbulBlock: 0`                  | Block 0     | ChainID opcode, SELFBALANCE, Blake2 precompile                                                                                  |
| **Muir Glacier**   | `muirglacierblock: 0`               | Block 0     | Difficulty bomb delay (no EVM changes)                                                                                          |
| **Berlin**         | `berlinBlock: 0`                    | Block 0     | Access lists (EIP-2929/2930), cold/warm storage pricing                                                                         |
| **London**         | `londonBlock: 0`                    | Block 0     | EIP-1559 base fee, EIP-3529 refund reduction                                                                                    |
| **Shanghai**       | `shanghaiTime: 0`                   | Timestamp 0 | PUSH0 (EIP-3855), warm COINBASE (EIP-3651), initcode limits (EIP-3860)                                                          |
| **Cancun**         | `cancunTime: 0`                     | Timestamp 0 | Transient storage TSTORE/TLOAD (EIP-1153), MCOPY (EIP-5656), SELFDESTRUCT neutered (EIP-6780)                                   |
| **Prague/Pectra**  | `pragueTime: 0`                     | Timestamp 0 | EIP-7702 (EOA code delegation), EIP-7251 (max effective balance), EIP-7002 (execution layer withdrawals)                        |
| **Osaka**          | `osakaTime: 0`                      | Timestamp 0 | EIP-7594 (PeerDAS), EIP-7692 (EOF v1), EIP-7823 (set max blob count), EIP-7691 (blob throughput increase)                       |
| **BPO1**           | `bpo1Time: 0`                       | Timestamp 0 | Blob Parameter Only upgrade 1 — raises blob target from 6→10, max from 9→15 (Mainnet: 2025-12-09 14:21:11 UTC, epoch 412,672)   |
| **BPO2**           | `bpo2Time: 0`                       | Timestamp 0 | Blob Parameter Only upgrade 2 — raises blob target from 10→14, max from 15→21 (Mainnet: 2026-01-07 01:01:11 UTC, epoch 419,072) |

#### Alloc Entries (32,434 total)

| Category                    | Count  | Description                                                                  |
| --------------------------- | ------ | ---------------------------------------------------------------------------- |
| Addresses ending in `323`   | 32,324 | Pre-deployed contract instances (greeting card service)                      |
| Addresses ending in `c0DE`  | 100    | Pre-deployed contract instances (code management service)                    |
| Repeating-pattern addresses | 4      | Reserved contract slots (`0x2222...`, `0x2323...`, `0x3232...`, `0x3333...`) |
| Reserved system addresses   | 7      | Governance and infrastructure contracts (see below)                          |
| EOA accounts                | 1      | Deployer account with 32 ETH initial balance                                 |

#### Reserved System Addresses

| Address             | Comment                    | Purpose                                                                       |
| ------------------- | -------------------------- | ----------------------------------------------------------------------------- |
| `0x0000...1111`     | Validator smart contract   | `ValidatorSmartContractAllowList` — QBFT validator/voter/overlord governance  |
| `0x0000...cafE`     | GasManager smart contract  | `GasManager` — block reward beneficiary, voter-governed gas funding and burns |
| `0x0000...c0DE`     | CodeManager smart contract | `CodeManager` — official Dakota code management service (patent-covered)      |
| `0x0000...Face`     | ERC-8004 Agent Registry    | Official ERC-8004 agent identity contract                                     |
| `0x0000...FacAdE`   | ProxyAdmin smart contract  | `ProxyAdmin` — guardian-gated ERC1967 upgrade dispatch                        |
| `0x0000...de1E6A7E` | EIP-7702 delegation entry  | Fixed custom genesis proxy hosting the shared registry; each delegated EOA links its own dispatcher slot |
| `0x0000...FEeD`     | GasSponsor proxy           | Fixed custom genesis proxy; first-linked once with `GasSponsor.initialize(...)` |

---

## Contracts

### Upgradeability & OpenZeppelin Compatibility

Dakota genesis slots use a **Cryft Labs-modified transparent proxy derived from OpenZeppelin 4.9.x**, embedded directly in the genesis file. It is not a stock OpenZeppelin proxy: it adds namespaced overlord/guardian governance, dynamic root-overlord recognition through `0x...1111`, a custom first-link initialization flag, and guardian-gated upgrade dispatch through the fixed ProxyAdmin. Vendored OZ 4.9.6 implementation helpers such as `Initializable`, `ReentrancyGuardUpgradeable`, and `AddressUpgradeable` are provided under `Contracts/Genesis/Upgradeable/` with Osaka-level `assembly ("memory-safe")` annotations.

> **For clients deploying implementation contracts behind a reserved genesis proxy slot:**
>
> | Scenario | Compatible? | Notes |
> |----------|:-----------:|-------|
> | Fresh implementation using **OZ 5.x** base contracts | **Yes** | The proxy boundary does not depend on the implementation's imports or inheritance. OZ 5.x implementation contracts can run behind the genesis shell when their own storage is collision-safe. |
> | Upgrade from a **4.9.6-based** impl to a **5.x-based** impl | **No** | OZ 5.x uses ERC-7201 namespaced storage (slots at `keccak256("openzeppelin.storage.<Name>") - 1`). OZ 4.9.6 uses sequential storage (slot 0, 1, 2…). Swapping base versions causes all existing state to appear zeroed — the old state becomes orphaned in unreachable slots. |
> | Upgrading between two **5.x-based** implementations | **Yes** | As long as both share the same ERC-7201 namespaced layout, upgrades work normally through the existing `ProxyAdmin`. |
> | Upgrading between two **4.9.6-based** implementations | **Yes** | Standard sequential-storage upgrade path. Use the vendored contracts under `Contracts/Genesis/Upgradeable/` for Osaka compatibility. |
> | Replacing the genesis proxy itself with a 5.x proxy | **No** | Proxy bytecode is embedded in genesis. A proxy-level swap would require a network hard fork. |
>
> **Rule of thumb:** Pick one storage model for an implementation family and preserve it for every later upgrade. The genesis proxy shell does not constrain the implementation's import version, but every implementation upgrade must preserve its predecessor's storage contract.
>
> The Dakota 4.9.6 proxy uses a **compile-time constant** admin address (`_PROXY_ADMIN`) embedded directly in the bytecode — reads cost 3 gas (`PUSH20`) instead of 2,100 gas (cold `SLOAD`). The admin **cannot be changed at runtime** — it is permanent. The `_changeAdmin` / `_setAdmin` / `_getAdmin` functions and `AdminChanged` event from stock OZ 4.9.6 have been removed as dead code.

### Genesis Contracts (deployed at network genesis)

| Contract                            | Address             | Runtime Size | Purpose                                                                    |
| ----------------------------------- | ------------------- | ------------ | -------------------------------------------------------------------------- |
| **ValidatorSmartContractAllowList** | `0x0000...1111`     | 20,565 B     | QBFT validator, voter, and root overlord governance (solc 0.8.19 / London) |
| **GasManager**                      | Genesis beneficiary | 24,026 B     | Voter-governed direct and sponsor-ledger funding, token burns, and native coin burns |
| **Dakota transparent proxy**        | Per-contract        | 15,246 B     | Modified transparent proxy with namespaced overlord/guardian governance    |
| **ProxyAdmin**                      | `0x0000...FacAdE`   | 3,200 B      | Guardian-gated ERC1967 upgrade dispatch                                    |

---

### ValidatorSmartContractAllowList (`0x0000...1111`)

The core governance contract for the QBFT consensus layer. Deployed at genesis address `0x0000000000000000000000000000000000001111`. The initializer (`initialize()`) becomes the first voter — there is no guardian role in this contract, all operations are voter-driven.

#### Access Control

| Role      | How Assigned                          | Powers                       |
| --------- | ------------------------------------- | ---------------------------- |
| **Voter** | Supermajority vote of existing voters | All governance actions below |

All state changes require **2/3 supermajority quorum**: `(totalVoterCount * 2 + 2) / 3`. The voter pool is the union of local `votersArray[]` and all addresses returned by contracts in `otherVoterContracts[]`.

#### Governance Actions (all require voter supermajority)

| Action                             | Function                                | Constraints                                                           |   |                                                             |
| ---------------------------------- | --------------------------------------- | --------------------------------------------------------------------- | - | ----------------------------------------------------------- |
| Add validator                      | `voteToAddValidator()`                  | Must not exceed `MAX_VALIDATORS` cap; not already in list             |   |                                                             |
| Remove validator                   | `voteToRemoveValidator()`               | Must exist in local list                                              |   |                                                             |
| Add voter                          | `voteToAddVoter()`                      | Must not already be a voter (aggregated)                              |   |                                                             |
| Remove voter                       | `voteToRemoveVoter()`                   | `getVoters().length > 1` — cannot remove the last voter               |   |                                                             |
| Add external validator contract    | `voteToAddOtherValidatorContract()`     | Must be a contract implementing `getValidators()` and `isValidator()` |   |                                                             |
| Remove external validator contract | `voteToRemoveOtherValidatorContract()`  | Must exist in list                                                    |   |                                                             |
| Add external voter contract        | `voteToAddOtherVoterContract()`         | Must implement `getVoters()` and `isVoter()`                          |   |                                                             |
| Remove external voter contract     | `voteToRemoveOtherVoterContract()`      | `votersArray.length > 0 \                                             | \ | otherVoterContracts.length > 1` — prevents empty voter pool |
| Add root overlord                  | `voteToAddRootOverlord()`               | Not `address(0)`, not already an overlord                             |   |                                                             |
| Remove root overlord               | `voteToRemoveRootOverlord()`            | Must exist in local list                                              |   |                                                             |
| Add external overlord contract     | `voteToAddOtherOverlordContract()`      | Must implement `getRootOverlords()` and `isRootOverlord()`            |   |                                                             |
| Remove external overlord contract  | `voteToRemoveOtherOverlordContract()`   | Must exist in list                                                    |   |                                                             |
| Change max validators              | `voteToChangeMaxValidators()`           | Must be > 0 (no upper bound)                                          |   |                                                             |
| Change vote tally block threshold  | `voteToUpdateVoteTallyBlockThreshold()` | 1 to 100,000 blocks                                                   |   |                                                             |

#### Vote Tally Mechanics

- Each vote type + target pair has an independent tally with a start block.
- Votes expire after `voteTallyBlockThreshold` blocks (default: 1,000, ~50 min at 3s blocks).
- Expired tallies auto-reset on the next vote attempt for that target, or via the voter-only `resetExpiredTally()` function (`external onlyVoters`).
- Voter-pool changes (add/remove voter, add/remove external voter contract, revoke voter management) are blocked while any tally is active (`activeVoteCount > 0`), ensuring the supermajority threshold remains stable for in-flight votes.

#### Federated Expansion (Pluggable External Contracts)

Three categories of external contracts can be plugged in:

| Array                       | Interface Required                       | Aggregation Function                                           |
| --------------------------- | ---------------------------------------- | -------------------------------------------------------------- |
| `otherValidatorContracts[]` | `getValidators()`, `isValidator()`       | `getValidators()` — union of local + all external validators   |
| `otherVoterContracts[]`     | `getVoters()`, `isVoter()`               | `getVoters()` — union of local + all external voters           |
| `otherOverlordContracts[]`  | `getRootOverlords()`, `isRootOverlord()` | `getRootOverlords()` — union of local + all external overlords |

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

#### Convenience View Functions

| Function                           | Returns                                                             | Description                                                                  |
| ---------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `isVoter(address)`                 | `bool`                                                              | Check if address is a voter (local + external contracts)                     |
| `isValidator(address)`             | `bool`                                                              | Check if address is an active validator (local + external)                   |
| `isRootOverlord(address)`          | `bool`                                                              | Check if address is a root overlord (local + external)                       |
| `getVoters()`                      | `address[]`                                                         | All voters (local `votersArray` + external contracts)                        |
| `getValidators()`                  | `address[]`                                                         | All validators (local + external contracts)                                  |
| `getRootOverlords()`               | `address[]`                                                         | All root overlords (local + external contracts)                              |
| `getVoterCount()`                  | `uint256`                                                           | Total voter count (local + external) without materializing the array         |
| `getValidatorCount()`              | `uint256`                                                           | Total validator count (local + external) without materializing the array     |
| `getRootOverlordCount()`           | `uint256`                                                           | Total root overlord count (local + external) without materializing the array |
| `getSupermajorityThreshold()`      | `uint256`                                                           | Current 2/3 supermajority threshold: `(totalVoterCount * 2 + 2) / 3`         |
| `getVoteTally(VoteType, target)`   | `(totalVotes, startVoteBlock, voteExpirationBlock, votedAddresses)` | Full tally state for a vote type + target                                    |
| `MAX_VALIDATORS`                   | `uint256`                                                           | Current validator cap                                                        |
| `voteTallyBlockThreshold`          | `uint256`                                                           | Blocks before a vote tally expires (default: 1,000)                          |
| `activeVoteCount`                  | `uint256`                                                           | Number of currently active vote tallies                                      |
| `overlordManagementRevoked`        | `bool`                                                              | Whether overlord management has been permanently revoked                     |
| `validatorManagementRevoked`       | `bool`                                                              | Whether validator management has been permanently revoked                    |
| `voterManagementRevoked`           | `bool`                                                              | Whether voter management has been permanently revoked                        |
| `hasVoted[VoteType][target][addr]` | `bool`                                                              | Whether an address has voted on a specific tally                             |

#### Lockout Prevention

| Scenario                                                 | Guard                                                                                |   |                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------ | - | ------------------------------- |
| Remove last voter                                        | `getVoters().length > 1` enforced before removal                                     |   |                                 |
| Remove last external voter contract when no local voters | `votersArray.length > 0 \                                                            | \ | otherVoterContracts.length > 1` |
| Voter-pool change during active tally                    | `activeVoteCount == 0` required; use `resetExpiredTally()` to clean up stale tallies |   |                                 |
| Revoke voter management with no external voters          | Requires `otherVoterContracts.length > 0` and `getVoters().length >= 1`              |   |                                 |
| Revoke validator management with too few validators      | Requires `getValidators().length >= 4` (QBFT minimum)                                |   |                                 |
| Revoke voter management before other domains             | Requires overlord + validator management already revoked                             |   |                                 |
| `address(0)` as voter/validator/overlord                 | All entry points require `!= address(0)`                                             |   |                                 |

---

### GasManager (Genesis Beneficiary)

Receives all block rewards as the QBFT beneficiary address. Provides voter-governed gas funding, token burns, and native coin burns with a two-phase vote → approve → execute pattern. Uses its own independent voter pool, separate from the validator contract's voters. All governance actions require **2/3 supermajority quorum**: `(totalVoterCount * 2 + 2) / 3`.

#### Access Control

| Role         | How Assigned                              | Powers                                                                                                                                                                                                     |
| ------------ | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Voter**    | 2/3 supermajority vote of existing voters | Vote on all governance actions                                                                                                                                                                             |
| **Guardian** | 2/3 supermajority vote of voters          | Execute approved funds/burns; execute token and native coin burns. Can be individually added/removed or bulk-cleared via `voteToClearGuardians()`. Enumerable via `getGuardians()` / `getGuardianCount()`. |

#### Two-Phase Operations

Destructive operations (funding, burns) require two phases:

1. **Vote phase**: Voters reach supermajority quorum on the operation. On passing, a `bytes32` approval key is stored.
2. **Execute phase**: A guardian (or the funded address for gas funds) calls the execute function, which checks the approval key, clears it, and performs the transfer.

| Operation | Propose/Vote Function | Execute Function | Who Can Execute |
| --- | --- | --- | --- |
| Legacy direct funding | `voteToFundGasV1(to, amount)` | `executeFundGasV1(to, amount)` | Guardian or `to` address |
| Nonce-bound direct funding | `proposeFundGasV2(...)`, then `voteToFundGasV2(fundKey)` | `executeFundGasV2(fundKey)` | Guardian or funded address |
| Sponsor-ledger funding | `proposeSponsorFunding(...)`, then `voteToFundGasV2(fundKey)` | `executeSponsorFunding(fundKey)` | Guardian or bound sponsor |
| Burn ERC-20 tokens | `voteToBurnTokens(token, amount)` | `executeTokenBurn(token, amount)` | Guardian only |
| Burn native coin | `voteToBurnNativeCoin(amount)` | `executeCoinBurn(amount)` | Guardian only |

All execute functions are protected by `ReentrancyGuard`. Direct funding uses
`.call{value:}`, while sponsor funding invokes the typed `depositFor` entry
point and verifies the exact balance deltas on both contracts.

#### Sponsor-Ledger Funding (`caFE` -> `FEeD`)

`0x...caFE` is the voter-governed source of platform sponsorship funds.
Sponsor funding never uses the generic native-transfer executor because
`0x...FEeD` intentionally rejects unclassified native transfers. A voter calls
`proposeSponsorFunding(fundingId, sponsor, amount, note)`, remaining voters use
`voteToFundGasV2(fundKey)`, and a guardian or the proposal-bound sponsor calls
`executeSponsorFunding(fundKey)`. Execution invokes
`GasSponsor.depositFor{value: amount}(sponsor)` at `0x...FEeD`.

The sponsor address is stored in the
`erc7201:dakota.storage.GasManagerSponsorFunding` namespace before voting
starts. It cannot be supplied or changed at execution time. The executor also
checks the exact `caFE` debit and `FEeD` retained-balance increase. Ordinary V2
execution rejects sponsor-bound proposals, so an approved sponsor payment
cannot fall through to a plain transfer.

#### Guardian Management

| Action              | Function                        | Notes                                                        |
| ------------------- | ------------------------------- | ------------------------------------------------------------ |
| Add guardian        | `voteToAddGuardian(address)`    | Voter supermajority required; must not already be a guardian |
| Remove guardian     | `voteToRemoveGuardian(address)` | Voter supermajority required; must be an existing guardian   |
| Clear all guardians | `voteToClearGuardians()`        | Voter supermajority required; at least 1 guardian must exist |
| List guardians      | `getGuardians()`                | Returns full `address[]` array                               |
| Count guardians     | `getGuardianCount()`            | Returns `uint256` count                                      |

Clearing emits `GuardiansCleared(count)` and resets all guardian mappings and the array in one operation.

#### Configurable Parameters (voter supermajority)

| Parameter                 | Default      | Function                                | Constraints  |
| ------------------------- | ------------ | --------------------------------------- | ------------ |
| `voteTallyBlockThreshold` | 1,000 blocks | `voteToUpdateVoteTallyBlockThreshold()` | 1 to 100,000 |

#### Native Coin Burns

Voters can burn any amount of the contract's native coin balance via `voteToBurnNativeCoin(amount)` → `executeCoinBurn(amount)`, sending it to `0x...dEaD`. This is the only mechanism for reducing accumulated gas fees — there is no automatic cap or auto-burn.

#### Voter Pool (Independent)

The GasManager has its own local `votersArray[]` and pluggable `otherVoterContracts[]`, completely independent from the ValidatorSmartContractAllowList voter pool. External voter contracts must implement `getVoters()` and `isVoter()`. 2/3 supermajority quorum: `(totalVoterCount * 2 + 2) / 3`.

#### Convenience View Functions

| Function                           | Returns                                                             | Description                                                          |
| ---------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `isVoter(address)`                 | `bool`                                                              | Check if address is a voter (local + external contracts)             |
| `getVoters()`                      | `address[]`                                                         | All voters (local `votersArray` + external contracts)                |
| `getVoterCount()`                  | `uint256`                                                           | Total voter count (local + external) without materializing the array |
| `getSupermajorityThreshold()`      | `uint256`                                                           | Current 2/3 supermajority threshold: `(totalVoterCount * 2 + 2) / 3` |
| `getVoteTally(VoteType, target)`   | `(totalVotes, startVoteBlock, voteExpirationBlock, votedAddresses)` | Full tally state for a vote type + target                            |
| `getContractBalance()`             | `uint256`                                                           | Native coin balance held by this contract                            |
| `getTokenBalance(token)`           | `uint256`                                                           | ERC-20 token balance held by this contract                           |
| `getGuardians()`                   | `address[]`                                                         | All guardian addresses                                               |
| `getGuardianCount()`               | `uint256`                                                           | Number of guardians                                                  |
| `isGuardian[addr]`                 | `bool`                                                              | Whether an address is a guardian                                     |
| `totalGasFunded`                   | `uint256`                                                           | Cumulative native coin funded to date                                |
| `voteTallyBlockThreshold`          | `uint256`                                                           | Blocks before a vote tally expires (default: 1,000)                  |
| `activeVoteCount`                  | `uint256`                                                           | Number of currently active vote tallies                              |
| `approvedFunds[key]`               | `bool`                                                              | Whether a fund-gas operation has been approved                       |
| `approvedBurns[key]`               | `bool`                                                              | Whether a token-burn operation has been approved                     |
| `approvedCoinBurns[key]`           | `bool`                                                              | Whether a native-coin-burn operation has been approved               |
| `hasVoted[VoteType][target][addr]` | `bool`                                                              | Whether an address has voted on a specific tally                     |

#### Lockout Prevention

| Scenario                                                 | Guard                                                                                |   |                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------ | - | ------------------------------- |
| Remove last voter                                        | `getVoters().length > 1` enforced before removal                                     |   |                                 |
| Remove last external voter contract when no local voters | `votersArray.length > 0 \                                                            | \ | otherVoterContracts.length > 1` |
| Voter-pool change during active tally                    | `activeVoteCount == 0` required; use `resetExpiredTally()` to clean up stale tallies |   |                                 |
| `address(0)` as voter/guardian/recipient                 | All entry points require `!= address(0)`                                             |   |                                 |
| Clear guardians when none exist                          | `guardiansArray.length > 0` required                                                 |   |                                 |
| Re-entrancy on fund/burn execution                       | `ReentrancyGuard` modifier on all execute functions                                  |   |                                 |
| Balance discrepancy after fund transfer                  | Exact balance delta check: `balanceBefore - balanceAfter == _amount`                 |   |                                 |

#### Upgradeability

GasManager inherits `Initializable` and `ReentrancyGuardUpgradeable` from OpenZeppelin v4.9.6. The constructor calls `_disableInitializers()` to prevent re-initialization of the implementation contract.

---

### TransparentUpgradeableProxy

Extended OpenZeppelin ERC1967 transparent proxy with multi-party overlord/guardian governance and 2/3 supermajority threshold voting. Every proxy instance deployed in the genesis file is an independent governance unit.

#### Access Tiers

| Tier                            | Source                                                                                                    | Powers                                                                            |
| ------------------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| **Root Overlord**               | Read dynamically from validator contract at `0x0000...1111` via `getRootOverlords()` / `isRootOverlord()` | Add/remove non-root overlords directly (no vote needed)                           |
| **Overlord** (non-root)         | Added by root overlord or via 2/3 supermajority overlord vote                                             | Propose and vote on governance actions (2/3 supermajority)                        |
| **Guardian**                    | Added via 2/3 supermajority overlord vote                                                                 | Operational: `proxy_linkLogicAdmin()` (one-time), trigger upgrades via ProxyAdmin |
| **Admin** (ProxyAdmin contract) | Immutable — baked into bytecode at compile/genesis time (3-gas reads)                                     | ERC1967 upgrade dispatch (`upgradeTo`, `upgradeToAndCall`)                        |

Root overlords are **not stored** in the proxy — they are read live from the validator contract via `try/catch`. If the validator contract is unreachable, root overlord calls return `false` / empty array (safe degradation).

#### Overlord Count and Supermajority Threshold

- `proxy_getOverlordCount()` = non-root overlords + root overlord count (when active)
- 2/3 supermajority threshold = `ceil(count × 2 / 3)` = `(count * 2 + 2) / 3`
- Examples: 1→1, 2→2, 3→2, 4→3, 5→4, 6→4

A single overlord can pass any proposal unilaterally (supermajority threshold = 1).

#### Governance Actions (2/3 supermajority)

| Action                | Function                                     | Constraints                                                                        |
| --------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------- |
| Add overlord          | `proxy_proposeOverlordChange(target, true)`  | Not `address(0)`, not a root overlord, not already an overlord, not a guardian     |
| Remove overlord       | `proxy_proposeOverlordChange(target, false)` | Must be an overlord; cannot remove last non-root when no root overlords are active |
| Add guardian          | `proxy_proposeGuardianChange(target, true)`  | Not `address(0)`, not the validator contract, not an overlord, max 10 guardians    |
| Remove guardian       | `proxy_proposeGuardianChange(target, false)` | Must be a guardian                                                                 |
| Clear all guardians   | `proxy_proposeClearGuardians()`              | At least 1 guardian exists                                                         |
| Change vote expiry    | `proxy_proposeExpiryChange(newExpiry)`       | Minimum 100 blocks (~5 min at 3s blocks)                                           |
| Revoke root overlord  | `proxy_proposeRevokeRootOverlord()`          | Root not already revoked; at least 1 non-root overlord exists                      |
| Restore root overlord | `proxy_proposeRestoreRootOverlord()`         | Root must be revoked; only non-root overlords can propose (root is excluded)       |

#### Root Overlord Direct Actions (no vote)

| Action                | Function                     | Constraints                                                                |
| --------------------- | ---------------------------- | -------------------------------------------------------------------------- |
| Add overlord          | `proxy_addOverlord()`        | Same as voted version                                                      |
| Remove overlord       | `proxy_removeOverlord()`     | Same as voted version                                                      |
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

`proxy_linkLogicAdmin(logic, data)` — guardian-gated, can only be called once (`isInit` flag). Sets the implementation address and initializes it with `data`. The admin is immutable (baked into bytecode at compile/genesis time), so no admin assignment occurs at link time.

#### Lockout Prevention

| Scenario                                            | Guard                                                                                                            |   |                              |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | - | ---------------------------- |
| Remove last non-root overlord when root is inactive | `_rawOverlordCount() > 1 \                                                                                       | \ | (rootCount > 0 && !revoked)` |
| Voluntary root revoke with no non-root overlords    | `_rawOverlordCount() > 0`                                                                                        |   |                              |
| Force-revoke root with no non-root overlords        | Same check in `proxy_proposeRevokeRootOverlord()`                                                                |   |                              |
| Link logic with `address(0)` logic                  | Checked `!= address(0)` in `proxy_linkLogicAdmin()`                                                              |   |                              |
| Overlord/guardian dual-role                         | Both `proxy_addOverlord` and `proxy_proposeGuardianChange` cross-check to prevent any address holding both roles |   |                              |
| Mid-vote membership manipulation                    | Every direct add/remove calls `_incrementVoteEpoch()`, invalidating all pending proposals                        |   |                              |
| Single overlord stuck (threshold too high)          | Threshold formula: `(1*2+2)/3 = 1` — a single overlord passes anything                                           |   |                              |
| Guardian overflow                                   | Hard cap: `MAX_GUARDIANS = 10`                                                                                   |   |                              |

#### Constants

| Constant                    | Value             | Notes                                               |
| --------------------------- | ----------------- | --------------------------------------------------- |
| `_PROXY_ADMIN`              | `0x0000...FacAdE` | Compile-time constant admin (3-gas read, immutable) |
| `_PROXY_VALIDATOR_CONTRACT` | `0x0000...1111`   | Genesis validator contract address                  |
| `DEFAULT_VOTE_EXPIRY`       | 60,000 blocks     | ~1 week at 3s blocks                                |
| `MAX_GUARDIANS`             | 10                | Hard cap on guardian count per proxy                |

---

### ProxyAdmin

Auxiliary contract assigned as the ERC1967 admin of `TransparentUpgradeableProxy` instances. Replaces OpenZeppelin's single-owner pattern with per-proxy guardian/overlord governance — each proxy is independently governed by its own controller set.

#### Access Control

| Action                 | Who                          | How                                                           |
| ---------------------- | ---------------------------- | ------------------------------------------------------------- |
| Upgrade implementation | Guardian of the target proxy | `upgrade(proxy, impl)` or `upgradeAndCall(proxy, impl, data)` |

The `onlyGuardianOf(proxy)` modifier queries the proxy's `proxy_isGuardian(msg.sender)` — which returns `true` for mapped guardians and for active root overlords (root overlords are implicit guardians).

#### Introspection

| Function                          | Returns                                                                                                                                  |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `getProxyAdmin(proxy)`            | Current ERC1967 admin address                                                                                                            |
| `getProxyImplementation(proxy)`   | Current implementation address                                                                                                           |
| `getProxyGuardians(proxy)`        | Array of all guardian addresses                                                                                                          |
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

| Contract                | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CodeManager**         | **Patent-covered.** Permissionless unique ID registry with an independent voter pool, 2/3 supermajority quorum, public mirrored UID state, and Pente routing. Charges a configurable registration fee forwarded to a fee vault. Deterministic ID generation via `keccak256(address(this), giftContract, chainId) + counter`.                                                                                                                                                                      |
| **PrivateComboStorage** | **Patent-covered.** Pente privacy group deployment. Stores code hashes privately with contract-assigned PINs, verifies redemption codes via hash comparison, tracks execution-time UID active state privately, and emits `PenteExternalCall` events to mirror UID status and route redemptions through CodeManager. Supports ERC-2771 trusted forwarder for meta-transactions via PrivateMetaTxRelay. All configuration (admin, authorized caller, CodeManager address, trusted forwarder, max-per-PIN limit) is embedded as compile-time constants — changes require recompilation and proxy upgrade. |
| **PrivateMetaTxRelay**  | **Patent-covered.** Pente privacy group deployment. EIP-712 / ERC-2771 meta-transaction relay for PrivateComboStorage. Any privacy group member can submit signed requests; the relay verifies the signature, increments a per-signer nonce, and forwards the call with the recovered signer appended per ERC-2771. Authorization is enforced by PrivateComboStorage, not the relay. |
| **DakotaDelegation**    | Initial v1 EIP-7702 execution logic. Verifies an account-owner EIP-712 signature, enforces per-account nonces/deadlines/execution gas budgets, executes bounded call batches, and supports EIP-1271 validation. It intentionally exposes no generic owner/session-key execution API.                                                                                                                                                                                                              |
| **DakotaDelegationBeacon** | Shared implementation beacon whose constructor accepts only the implementation and derives its temporary owner from the root caller validated by `0x...1111`. After bootstrap, the fixed delegation entry owns it and Registry upgrades call `upgradeTo(newImplementation)` once.                                                                                                                                                                                                                  |
| **DakotaDelegationBeaconDispatcher** | Immutable, stateless per-account dispatcher. Each delegated EOA stores this dispatcher in its own EIP-1967 implementation slot; the dispatcher resolves current logic through the beacon.                                                                                                                                                                                                                                                                                         |
| **GasSponsor**          | Initial v1 platform-managed sponsorship treasury. Validates platform-signed vouchers, approved EIP-7702 delegation, allowlisted relayers, tenant/sponsor limits, operation replay protection, gas envelopes, and bounded reimbursement.                                                                                                                                                                                                                                                           |
| **CryftGreetingCards**  | ERC-721 NFT (service client — not patent-covered). Mint-on-purchase from pre-registered supply. Per-batch `PurchaseSegment` storage for gas-efficient buyer/URI lookups (binary search). Active-state authority is externalized to the private redeemable-code system. Interfacing with the redeemable-code service is permitted with proper fees or license.                                                                                                                                     |

---

### CodeManager (Unique ID Registry + Pente Router)

Permissionless unique ID registry with an independent voter pool. All governance actions require **2/3 supermajority quorum**: `(totalVoterCount * 2 + 2) / 3`. The voter pool is the union of local `votersArray[]` and all addresses returned by contracts in `otherVoterContracts[]`. Voter-pool changes are blocked while any tally is active (`activeVoteCount > 0`).

Also serves as the public mirror and Pente router. Authorized privacy groups call `recordRedemption`, which resolves the UID to its gift contract, marks the UID terminally redeemed, and forwards to the gift contract via try/catch. The function never reverts on precondition failures (emits `RedemptionRejected`) or gift contract errors (emits `RedemptionFailed`), guaranteeing that every `PenteExternalCall` succeeds from Pente's perspective and private state is always preserved. Active/inactive state is mirrored publicly from the private contract using sparse per-UID overrides over a default active state.

#### Governance Actions (all require voter supermajority)

| Action                               | Function                                       | Constraints                                                            |
| ------------------------------------ | ---------------------------------------------- | ---------------------------------------------------------------------- |
| Add whitelisted address              | `voteToAddWhitelistedAddress(address)`         | Voter supermajority required                                           |
| Remove whitelisted address           | `voteToRemoveWhitelistedAddress(address)`      | Voter supermajority required                                           |
| Update registration fee              | `voteToUpdateRegistrationFee(uint256)`         | Voter supermajority required                                           |
| Update fee vault                     | `voteToUpdateFeeVault(address)`                | Voter supermajority required                                           |
| Add voter                            | `voteToAddVoter(address)`                      | `activeVoteCount == 0`; not already a voter                            |
| Remove voter                         | `voteToRemoveVoter(address)`                   | `activeVoteCount == 0`; `getVoters().length > 1`                       |
| Add external voter contract          | `voteToAddOtherVoterContract(address)`         | `activeVoteCount == 0`; must implement `getVoters()` + `isVoter()`     |
| Remove external voter contract       | `voteToRemoveOtherVoterContract(address)`      | `activeVoteCount == 0`                                                 |
| Update vote tally block threshold    | `voteToUpdateVoteTallyBlockThreshold(uint256)` | 1 to 100,000 blocks                                                    |
| Authorize/de-authorize privacy group | `voteToAuthorizePrivacyGroup(address)`         | Toggles `isAuthorizedPrivacyGroup[addr]`; voter supermajority required |
| Reset expired tally                  | `resetExpiredTally(VoteType, uint256)`         | Voter-only; tally must have expired                                    |

#### Pente Router Functions (called by authorized privacy groups)

| Function                                          | Description                                                                                                                                                                                                          |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `recordRedemption(uniqueId, redeemer)`            | Resolves UID → gift contract, marks REDEEMED, calls `IRedeemable.recordRedemption()` via try/catch. Never reverts — emits `RedemptionRejected` on precondition failures, `RedemptionFailed` on gift contract errors. |
| `setUniqueIdActiveBatch(uniqueIds, activeStates)` | Mirrors sparse UID active-state changes from an authorized privacy group. Redeemed UIDs are rejected and left terminal.                                                                                              |

#### Registration (permissionless)

| Function                                             | Description                                                                                                         |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `registerUniqueIds(giftContract, chainId, quantity)` | Payable — `registrationFee × quantity`. Forwards fee to `feeVault`. Increments counter range for the gift contract. |

#### Convenience View Functions

| Function                                      | Returns                                                             | Description                                                          |
| --------------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `isVoter(address)`                            | `bool`                                                              | Check if address is a voter (local + external contracts)             |
| `getVoters()`                                 | `address[]`                                                         | All voters (local `votersArray` + external contracts)                |
| `getVoterCount()`                             | `uint256`                                                           | Total voter count (local + external) without materializing the array |
| `getSupermajorityThreshold()`                 | `uint256`                                                           | Current 2/3 supermajority threshold: `(totalVoterCount * 2 + 2) / 3` |
| `getVoteTally(VoteType, target)`              | `(totalVotes, startVoteBlock, voteExpirationBlock, votedAddresses)` | Full tally state for a vote type + target                            |
| `validateUniqueId(uniqueId)`                  | `bool`                                                              | Check if a UID is valid (registered and within counter range)        |
| `getUniqueIdDetails(uniqueId)`                | `(giftContract, chainId, counter)`                                  | Resolve a UID to its gift contract, chain, and counter               |
| `getContractData(contractIdentifier)`         | `ContractData`                                                      | Look up the gift contract and chain ID for a contract identifier     |
| `getIdentifierCounter(giftContract, chainId)` | `(contractIdentifier, counter)`                                     | Get the current counter for a gift contract + chain pair             |
| `isUniqueIdActive(uniqueId)`                  | `bool`                                                              | Public mirrored active state for a UID                               |
| `isUniqueIdRedeemed(uniqueId)`                | `bool`                                                              | Public mirrored redeemed state for a UID                             |
| `registrationFee`                             | `uint256`                                                           | Current per-UID registration fee (wei)                               |
| `feeVault`                                    | `address`                                                           | Address that receives registration fees                              |
| `voteTallyBlockThreshold`                     | `uint256`                                                           | Blocks before a vote tally expires (default: 1,000)                  |
| `activeVoteCount`                             | `uint256`                                                           | Number of currently active vote tallies                              |
| `isWhitelistedAddress[addr]`                  | `bool`                                                              | Whether an address is whitelisted for legacy operations              |
| `isAuthorizedPrivacyGroup[addr]`              | `bool`                                                              | Whether an address is an authorized Pente privacy group              |
| `hasVoted[VoteType][target][addr]`            | `bool`                                                              | Whether an address has voted on a specific tally                     |

---

### PrivateComboStorage (Pente Privacy Group)

Deployed inside a Paladin Pente privacy group. All state is private to privacy group members. Stores code hashes with contract-assigned PINs, verifies codes via hash comparison, and is the execution-time source of truth for UID active state. Valid status changes are mirrored publicly through CodeManager. On redemption, inactive or already-redeemed UIDs are skipped privately before any external redemption route is emitted.

All configuration is embedded as **compile-time constants** — no constructor, no initializer, no storage-based admin. Changes require recompilation and redeployment via proxy upgrade.

#### Constants (set at compile time)

| Constant            | Type      | Description                                                       |
| ------------------- | --------- | ----------------------------------------------------------------- |
| `ADMIN`             | `address` | Primary authorized caller                                         |
| `AUTHORIZED`        | `address` | Secondary authorized caller                                       |
| `CODE_MANAGER`      | `address` | CodeManager address on the public chain                           |
| `TRUSTED_FORWARDER` | `address` | ERC-2771 trusted forwarder (PrivateMetaTxRelay proxy address)     |
| `MAX_PER_PIN`       | `uint256` | Maximum entries per PIN slot (32)                                 |

#### Write Functions

| Function                                                                  | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `syncRegisteredCodeCountBatch(contractIdentifiers[], registeredCounts[])` | Sync the public CodeManager counter ceiling for one or more whitelisted contract identifiers. This local mirror is the store-time source of truth used to reject unregistered counters before any external call is considered.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `storeDataBatch(request)`                                                 | Bulk store code hashes using a batch-level `contractIdentifier`, batch-level PIN config (`pinLength` 1–8, `useSpecialChars`), and per-entry pre-registered `counters`. PIN settings are per-batch, not per-contract — different batches for the same gift contract can use different PIN lengths and character sets, letting callers choose security level per batch. Each entry also supplies its entropy seed and optional per-UID manager (`address(0)` means no dedicated manager). The contract reconstructs `uniqueId = contractIdentifier-counter`, rejects any counter above the synced public registration ceiling or already stored privately, assigns a PIN, and stores the hash. Returns `string[] assignedPins`. |
| `setUniqueIdManagersBatch(uniqueIds[], newManagers[])`                    | Reassign or clear per-UID managers. Current UID manager, `ADMIN`, or `AUTHORIZED` may update each UID.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `setUniqueIdActiveBatch(uniqueIds[], activeStates[])`                     | Update private execution-time UID active state and mirror valid entries to CodeManager. UID manager, `ADMIN`, or `AUTHORIZED` may update each UID.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `redeemCodeBatch(pins[], codeHashes[], redeemers[])`                      | Batch-verify codes, skip inactive/redeemed UIDs privately, delete consumed entries, mark redeemed locally, and emit `PenteExternalCall` per valid entry to route `recordRedemption` through CodeManager. CodeManager never reverts on precondition failures or gift contract errors, so Pente private state is always preserved.                                                                                                                                                                                                                                                                                                                                                                                              |

#### View Functions

| Function                       | Returns   | Description                                                            |
| ------------------------------ | --------- | ---------------------------------------------------------------------- |
| `pinSlotCount(pin)`            | `uint256` | Number of hashes stored under a PIN                                    |
| `isTrustedForwarder(address)`  | `bool`    | Whether the given address is the ERC-2771 trusted forwarder            |
| `ADMIN()`                      | `address` | Admin constant                                                         |
| `AUTHORIZED()`                 | `address` | Authorized caller constant                                             |
| `CODE_MANAGER()`               | `address` | CodeManager address constant                                           |
| `TRUSTED_FORWARDER()`          | `address` | ERC-2771 trusted forwarder address (PrivateMetaTxRelay proxy)          |
| `MAX_PER_PIN()`                | `uint256` | Max entries per PIN slot constant                                      |

---

### PrivateMetaTxRelay (Pente Privacy Group)

Deployed inside the same Paladin Pente privacy group as PrivateComboStorage. Implements the EIP-712 / ERC-2771 meta-transaction relay pattern — any privacy group member can submit signed requests on behalf of external signers. The relay verifies signatures, manages per-signer nonces, and forwards calls to PrivateComboStorage with the recovered signer address appended per the ERC-2771 trusted forwarder specification.

The relay itself is open — it performs no caller authorization. Authorization is enforced entirely by PrivateComboStorage's `_msgSender()`, which extracts the appended signer and checks it against `ADMIN`, `AUTHORIZED`, or the per-UID manager depending on the target function.

All configuration is embedded as **compile-time constants** — no constructor, no initializer.

#### Constants (set at compile time)

| Constant                | Type      | Description                                                 |
| ----------------------- | --------- | ----------------------------------------------------------- |
| `ADMIN`                 | `address` | Paladin signer address (retained for future admin functions) |
| `PRIVATE_COMBO_STORAGE` | `address` | Target PrivateComboStorage proxy address within the group   |

#### EIP-712 Signing Domain

| Field               | Value                                        |
| ------------------- | -------------------------------------------- |
| `name`              | `"PrivateMetaTxRelay"`                      |
| `version`           | `"1"`                                       |
| `chainId`           | `block.chainid`                              |
| `verifyingContract` | `address(this)` (proxy address in Pente)     |

#### ForwardRequest Struct

```solidity
struct ForwardRequest {
    address from;       // The original signer (recovered via ecrecover)
    bytes   data;       // ABI-encoded function call to PrivateComboStorage
    uint256 nonce;      // Per-signer replay-protection nonce
    uint256 deadline;   // block.timestamp expiry
}
```

#### Write Functions

| Function                                       | Description                                                                                                                                                                                   |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `execute(request, signature)`                  | Forward a single signed request. Verifies signature, consumes nonce, calls PrivateComboStorage with `abi.encodePacked(request.data, request.from)`. Reverts if signature or forwarded call fails. |
| `executeBatch(requests[], signatures[])`        | Forward multiple independent signed requests. Invalid entries (bad signature length, expired, wrong nonce, bad signature) are skipped with `MetaTxFailed` events. Failed forwarded calls are reported, not reverted. |

#### View Functions

| Function                       | Returns   | Description                                                                |
| ------------------------------ | --------- | -------------------------------------------------------------------------- |
| `getNonce(address)`            | `uint256` | Current nonce for a signer (monotonically increasing)                      |
| `verify(request, signature)`   | `bool`    | Non-consuming check: would this request pass verification at current block |
| `domainSeparator()`            | `bytes32` | EIP-712 domain separator for this relay instance                           |
| `ADMIN()`                      | `address` | Admin constant                                                             |
| `PRIVATE_COMBO_STORAGE()`      | `address` | Target contract constant                                                   |

#### Security Model

- **Open relay, enforced target**: The relay has no `onlyAdmin` gate — any privacy group member may submit. Authorization is enforced by PrivateComboStorage's `_msgSender()` against the recovered signer.
- **EIP-712 typed signatures**: Prevent cross-chain and cross-contract replay via domain separator.
- **Per-signer nonces**: Monotonically increasing, consumed on successful verification. Prevents replay of the same request.
- **Deadline enforcement**: Requests expire at `block.timestamp > deadline`.
- **EIP-2 low-s check**: Rejects malleable signatures (`s > secp256k1n/2`).
- **ERC-2771 forwarding**: `abi.encodePacked(request.data, request.from)` appends the 20-byte signer address. PrivateComboStorage's `_msgSender()` extracts it when `msg.sender == TRUSTED_FORWARDER`.

---

### Native EIP-7702 Delegation and Gas Sponsorship

The current sponsorship stack is an initial v1 deployment built directly on EIP-7702. It does **not** use ERC-4337, a bundler, an EntryPoint, or a paymaster. The authoritative deployment and canary procedure is [Contracts/Genesis/7702/GAS-SPONSORSHIP.md](Contracts/Genesis/7702/GAS-SPONSORSHIP.md).

#### Fixed Deployment Anchors

| Purpose | Address |
| --- | --- |
| Chain ID | `112311` |
| Validator/root registry | `0x0000000000000000000000000000000000001111` |
| ProxyAdmin | `0x0000000000000000000000000000000000FacAdE` |
| EIP-7702 delegation entry | `0x00000000000000000000000000000000de1E6A7E` |
| GasSponsor proxy | `0x000000000000000000000000000000000000FEeD` |
| Retained root overlord | `0x2B7361056b31D2bf201E6764e7825fd31c0D223A` |

The retained root is already an overlord and guardian on both custom genesis proxies. Do not add it again or revoke it during this deployment.

#### Runtime Route

```text
relayer
  -> GasSponsor at 0x...FEeD
  -> delegated user EOA
  -> EIP-7702 indicator: 0xef0100 || 0x...de1E6A7E
  -> genesis proxy code executing in the user account context
  -> user EIP-1967 implementation slot
  -> DakotaDelegationBeaconDispatcher
  -> DakotaDelegationBeacon
  -> DakotaDelegation
  -> authorized target calls
```

At its own address, `0x...de1E6A7E` is first-linked to the upgradeable `DakotaDelegationRegistry` control plane. Direct calls to the fixed entry expose canonical component addresses, the current registry and delegation implementations, verified release history, capabilities, and delegated-account readiness.

Each authorized user account has separate proxy storage and links `DakotaDelegationBeaconDispatcher` in that account's EIP-1967 implementation slot. The dispatcher is immutable and stateless; user execution therefore bypasses registry logic and normal delegation upgrades update the shared beacon once. The fixed entry owns that beacon and registry calls validate and record each implementation activation atomically.

#### Initial-Release and Storage Rules

- Before first deployment, both reserved genesis proxies must report `proxy_getIsInit() == false` and a zero EIP-1967 implementation slot.
- `DakotaDelegationRegistry` uses `initialize(...)` with `initializer`, and its implementation constructor disables direct initialization.
- `GasSponsor` uses `initialize(...)` with `initializer`. There is no `initializeV2(...)`, numbered reinitializer, or prior implementation state to migrate.
- The `GasSponsor` implementation constructor disables direct initialization.
- Direct execution against the `DakotaDelegation` implementation is rejected; it must execute through a delegated account.
- Genesis proxy governance state is namespaced and implementation routing uses the EIP-1967 slot.
- Delegation registry state uses `erc7201:dakota.storage.DakotaDelegationRegistry`.
- Sponsorship state uses `erc7201:dakota.storage.GasSponsor`.
- Per-user nonce and reentrancy state use `erc7201:dakota.storage.DakotaDelegation`.

#### Contract Set

| Contract | Responsibility |
| --- | --- |
| `DakotaDelegation` | Verifies the user-account EIP-712 signature, account nonce, deadline, executor, call count, and execution gas budget before executing up to 32 calls. |
| `DakotaDelegationBeacon` | Shared beacon with root-validated bootstrap ownership. Deploy it directly from a root recognized by `0x...1111`, then transfer ownership to the fixed delegation entry. Do not renounce ownership. |
| `DakotaDelegationBeaconDispatcher` | Stateless resolver stored in each delegated account's EIP-1967 implementation slot. |
| `DakotaDelegationRegistry` | Upgradeable implementation first-linked at `0x...de1E6A7E`; the fixed entry owns the beacon and exposes the verified release ledger, current implementation directory, capability surface, and delegated-account readiness view. |
| `GasSponsor` | Validates sponsorship vouchers and delegation readiness, enforces global pause/relayer controls plus sponsor and tenant limits, prevents operation replay, executes the signed account calldata, and reimburses the relayer within the signed cap. |

#### Build and Deployment

Compile with Solidity `0.8.34`, Osaka, optimizer enabled, and `200` runs. The deployment gate is:

```bash
python Tools/SolcCompiler/check_gas_sponsor.py
```

The gate checks initial-release naming and initializer semantics, ERC-7201 storage locations, linear storage, retired selector absence, proxy selector collisions, shared capability assignments, registry control-plane invariants, dispatcher statelessness, and runtime size. Archive and verify the exact Standard JSON input; flattened sources are not the deployment source of truth.

Deploy in this order:

1. `DakotaDelegation()` version `1.1.0`
2. From `ROOT`, `DakotaDelegationBeacon(delegationImplementation)`; the
   constructor validates `msg.sender` against `0x...1111` and makes that
   validated caller the temporary owner.
3. `DakotaDelegationBeaconDispatcher(beacon)`
4. `DakotaDelegationRegistry()`
5. `GasSponsor()`

Encode `DakotaDelegationRegistry.initialize(dispatcher, beacon, 0x...FEeD)`;
the live root caller becomes registry admin. Then `ROOT` first-links `0x...de1E6A7E` with:

```solidity
proxy_linkLogicAdmin(
    DAKOTA_DELEGATION_REGISTRY_IMPLEMENTATION,
    REGISTRY_INITIALIZE_CALLDATA
)
```

Transfer beacon ownership to `0x...de1E6A7E`. The fixed entry must report one
initial release and `currentSnapshot().registryControlsBeacon == true`. Normal
delegation upgrades call `upgradeDelegation(newImplementation,
expectedRuntimeCodeHash)` through the registry ABI at `0x...de1E6A7E`.

Encode the initial sponsor state:

```solidity
GasSponsor.initialize(
    PLATFORM_ADMIN,
    VOUCHER_SIGNER,
    0x00000000000000000000000000000000de1E6A7E,
    100000
)
```

Then `ROOT` performs the one-time first link at `0x...FEeD`:

```solidity
proxy_linkLogicAdmin(GAS_SPONSOR_IMPLEMENTATION, INITIALIZE_CALLDATA)
```

Do not use `ProxyAdmin.upgrade(...)` for this first link: it would not set the custom genesis initialization flag. After linking, `implementationVersion()` must return `"1.0.0"` and sponsorship must remain paused until configuration and exact-transaction simulation are complete.

#### User Onboarding

The user signs an EIP-7702 authorization for chain `112311`, contract `0x...de1E6A7E`, and the user's current account nonce. The user never provides a private key. `ROOT` submits the type-4 transaction to the user account with:

```solidity
proxy_linkLogicAdmin(DAKOTA_DELEGATION_DISPATCHER, hex"")
```

After onboarding, confirm the EIP-7702 code indicator, custom proxy initialization flag, per-account dispatcher slot, retained root authority, `implementationVersion() == "1.1.0"`, the required capability bitmap, registry readiness, and `GasSponsor.isDelegationReady(account) == true`.

#### DakotaDelegation API

| Function | Description |
| --- | --- |
| `executeSponsored(request, ownerSignature)` | Executes the signed, nonce-bound, executor-bound call batch through the delegated user account. |
| `getNonce()` | Returns the current per-account sponsored-execution nonce. |
| `hashCalls(calls)` | Produces the canonical hash of the call array. |
| `getExecutionDigest(...)` | Produces the user EIP-712 digest before signing. |
| `domainSeparator()` | Returns the account-specific `DakotaDelegation` / version `1` domain separator. |
| `isValidSignature(hash, signature)` | Implements EIP-1271 for the delegated account. |
| `delegationProtocolId()` | Returns the initial sponsored-execution protocol identifier. |
| `delegationCapabilities()` | Returns the stable v1 capability bitmap for dashboard and router feature discovery. |
| `implementationVersion()` | Returns `"1.1.0"`. |
| `supportsInterface(interfaceId)` | Reports the delegation, ERC-165, EIP-1271, ERC-721 receiver, and ERC-1155 receiver surfaces. |

#### DakotaDelegationRegistry API

| Scope | Functions | Purpose |
| --- | --- | --- |
| Initial link | `initialize` | Binds the dispatcher, beacon, sponsor, initial admin, protocol, and first verified release at the fixed delegation entry. |
| Registry admin | `proposeAdmin`, `acceptAdmin`, `cancelAdminTransfer` | Two-step control-plane administration without an ownerless state. |
| Registry admin | `upgradeDelegation` | Validates the exact runtime code hash, protocol, required capabilities, and interfaces before atomically upgrading and recording. |
| Registry admin | `recordCurrentImplementation` | Captures an implementation changed before the fixed delegation entry acquired beacon ownership. |
| Registry admin | `transferBeaconOwnership` | Explicit migration escape hatch to a replacement control plane. |
| Read paths | `currentSnapshot`, `currentRelease`, `releaseAt`, `releaseCount` | Exposes canonical routing and release history. |
| Entry reads | `registryImplementation`, `registryVersion`, `registryStorageLocation`, `genesisProxyAdmin` | Exposes the control-plane implementation and fixed proxy integration details. |
| Account reads | `accountStatus`, `isAccountReady`, `getAccountNonce`, `getAccountDomainSeparator`, `getAccountExecutionDigest` | Consolidates EIP-7702, proxy, protocol, capability, signer, and sponsor readiness. |

#### GasSponsor API

| Scope | Functions | Purpose |
| --- | --- | --- |
| Platform admin | `setVoucherSigner`, `setApprovedDelegate`, `setRelayer`, `setPaused`, `setFixedOverheadGas` | Controls the global signing, delegation, relayer, pause, and gas-overhead policy. |
| Platform admin | `configureSponsor`, `setSponsorManager`, `setSponsorAdminEnabled` | Binds a stable sponsor address to a canonical tenant ID hash, manager, hard limits, and platform enable switch. |
| Sponsor manager | `setTenantLimits`, `setTenantEnabled`, `withdrawSponsor` | Applies tenant limits no greater than platform limits, controls the tenant enable switch, and withdraws sponsor funds. |
| Any funder | `depositFor` | Directly deposits native currency into an already configured sponsor account; platform allocations should use the governed `caFE` sponsor-funding flow. |
| Allowlisted relayer | `executeSponsored` | Submits signed execution calldata plus a platform-signed voucher and receives bounded reimbursement. |
| Read paths | `getSponsorAccount`, `voucherDigest`, `isDelegationReady`, `isOperationConsumed`, `isRelayer` | Exposes configuration and readiness checks needed by the router, dashboard, and relayer. |

Use a stable tenant-owned address, normally its tenant registry, as `SPONSOR`. Derive `tenantId` consistently as `keccak256(bytes(canonicalTenantId))`. Effective per-operation and daily limits are the lower of the platform and tenant values, and both platform and tenant enable switches must remain active.

The user signs `SponsoredExecutionRequest` under:

```text
name = DakotaDelegation
version = 1
chainId = 112311
verifyingContract = user account
executor = 0x...FEeD
```

The platform signs `SponsorshipVoucher` under:

```text
name = DakotaGasSponsor
version = 1
chainId = 112311
verifyingContract = 0x...FEeD
delegate = 0x...de1E6A7E
executionHash = keccak256(executionData)
relayer = allowlisted relayer
```

The relayer calls `GasSponsor.executeSponsored(voucher, executionData, voucherSignature)`. Each `operationId` is single-use. A failed user execution still consumes the operation and reimburses the relayer within the signed cap.

#### Upgrade Paths

- Delegation logic: pause sponsorship, deploy and verify compatible logic, derive its runtime code hash from the archived artifact, call `upgradeDelegation(newImplementation, expectedCodeHash)` at `0x...de1E6A7E`, then confirm the release record and existing-account nonce preservation before unpausing.
- Delegation control plane: preserve the `Initializable` linear prefix and `erc7201:dakota.storage.DakotaDelegationRegistry`, then use the fixed ProxyAdmin to upgrade `0x...de1E6A7E`; use `upgradeAndCall` only if a future implementation introduces a numbered migration.
- GasSponsor without migration: pause sponsorship, deploy and verify storage-compatible logic, then call `ProxyAdmin.upgrade(GAS_SPONSOR_PROXY, newImplementation)`.
- GasSponsor with a future migration: use `ProxyAdmin.upgradeAndCall(...)` and introduce a numbered reinitializer only in that future implementation.
- GasManager sponsor funding: deploy and verify the storage-compatible implementation, confirm its linear layout still ends at slot `71`, then call `ProxyAdmin.upgrade(GAS_MANAGER_PROXY, newImplementation)`. No reinitializer is required because sponsor bindings use a new ERC-7201 namespace with valid zero-state defaults. Confirm `implementationVersion() == "2.5.0"` and `gasSponsor() == 0x...FEeD` through the `0x...caFE` proxy after upgrading.
- Per-account dispatcher replacement is a recovery path, not the normal delegation upgrade mechanism.

---

### CryftGreetingCards (ERC-721 NFT)

ERC-721 NFT gift card contract. Service client of the redeemable-code system — not itself patent-covered. UID registration is decoupled from purchasing — when admin increases `maxSaleSupply`, the delta UIDs are registered on CodeManager automatically. Buyers mint from pre-registered supply. Uses per-batch `PurchaseSegment` storage for O(1) buyer/URI lookups via binary search. Tokens live in an internal vault until redemption.

#### Status Derivation (no explicit state flags)

| Status       | Derivation                                                                            |
| ------------ | ------------------------------------------------------------------------------------- |
| **Frozen**   | Inverse of CodeManager's mirrored active state                                        |
| **Redeemed** | Token exists AND is no longer held by the vault (`ownerOf(tokenId) != address(this)`) |

#### Write Functions

| Function                                | Access                          | Description                                                                                                                                                    |
| --------------------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `buy(buyer, quantity, redeemedBaseURI)` | Anyone (payable)                | Purchase cards — pays `pricePerCard × qty`. Mints into vault from pre-registered supply.                                                                       |
| `setMaxSaleSupply(supply)`              | Owner (payable)                 | Increase max purchasable supply (can only increase). Atomically registers the delta UIDs on CodeManager — `registrationFee × delta` must be sent as msg.value. |
| `recordRedemption(uniqueId, redeemer)`  | CodeManager only (Pente router) | Route redemption from privacy group — transfers NFT from vault to redeemer.                                                                                    |

#### Convenience View Functions

| Function                              | Returns                                  | Description                                                                                   |
| ------------------------------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------- |
| `getCardStatus(uniqueId)`             | `(tokenId, nftHolder, frozen, redeemed)` | Single-call full card status — use for UI status displays                                     |
| `tokenURI(tokenId)`                   | `string`                                 | IPFS metadata URI — unredeemed: `baseTokenURI/tokenId.json`; redeemed: per-batch redeemed URI |
| `contractURI()`                       | `string`                                 | Collection-level metadata for marketplaces (OpenSea standard)                                 |
| `ownerOf(tokenId)`                    | `address`                                | Current holder — vault address if unredeemed, recipient if redeemed                           |
| `totalSupply()`                       | `uint256`                                | Total minted tokens                                                                           |
| `availableSupply()`                   | `uint256`                                | Cards registered but not yet purchased                                                        |
| `pricePerCard`                        | `uint256`                                | Current price per card (wei)                                                                  |
| `maxSaleSupply`                       | `uint256`                                | Maximum cards available for purchase                                                          |
| `totalRedeems`                        | `uint256`                                | Total number of redeemed cards                                                                |
| `getUniqueIdForToken(tokenId)`        | `string`                                 | Compute uniqueId from tokenId (deterministic, no storage)                                     |
| `getTokenForUniqueId(uniqueId)`       | `uint256`                                | Parse tokenId from uniqueId (no storage)                                                      |
| `cardBuyer(tokenId)`                  | `address`                                | Original purchaser (binary search through purchase segments)                                  |
| `isUniqueIdFrozen(uniqueId)`          | `bool`                                   | Compatibility alias: inverse of CodeManager mirrored active state                             |
| `isUniqueIdRedeemed(uniqueId)`        | `bool`                                   | Derived redeemed status (IRedeemable implementation)                                          |
| `isValidUniqueId(uniqueId)`           | `bool`                                   | Validates against CodeManager registry (read-only pass-through)                               |
| `getDetailsFromCodeManager(uniqueId)` | `(giftContract, chainId, counter)`       | Fetches UID details from CodeManager (read-only pass-through)                                 |

---

## Tools

### `Tools/KeyWizard/dakota_keywizard.py`

Interactive wizard for generating and distributing three types of cryptographic keys across your node network. No external Python packages required (stdlib only).

**Key types:**
- **EOA accounts** — private key + address, optional keystore V3 JSON
- **Besu node keys** — `key` + `key.pub` for P2P identity / validator signing

**SCP distribution:** After generation, the wizard can distribute each key set to remote nodes via SCP with per-key review, retry on failure, and optional deletion of local originals.

**Interactive mode (default):**
```bash
python3 Tools/KeyWizard/dakota_keywizard.py
```

**CLI flags for scripted/batch use:**
```bash
# Generate 4 Besu node keys, no EOA, with SCP step
python3 Tools/KeyWizard/dakota_keywizard.py \
  --besu-count 4 \
  --no-eoa \
  --scp

# Generate 3 EOAs with keystore JSON, output to custom directory
python3 Tools/KeyWizard/dakota_keywizard.py \
  --eoa-count 3 \
  --eoa-keystore \
  --out /home/user/my-keys

# Non-interactive batch (no SCP, uses defaults)
python3 Tools/KeyWizard/dakota_keywizard.py \
  --non-interactive \
  --besu-count 4
```

**All flags:**

| Flag                  | Default         | Description                               |
| --------------------- | --------------- | ----------------------------------------- |
| `--out`               | `~/dakota-keys` | Base output directory                     |
| `--non-interactive`   | off             | Run without prompts (uses flags/defaults) |
| `--no-eoa`            | off             | Disable EOA generation                    |
| `--eoa-count`         | 1               | Number of EOA accounts to generate        |
| `--eoa-keystore`      | off             | Also generate keystore V3 JSON            |
| `--eoa-keystore-pass` | prompt          | Keystore password                         |
| `--besu-count`        | 0               | Number of Besu node keys to generate      |
| `--name-prefix-eoa`   | `eoa-`          | Folder prefix for EOA keys                |
| `--name-prefix-besu`  | `besu-node-`    | Folder prefix for Besu node keys          |
| `--scp`               | off             | Enable SCP distribution step              |

### `Tools/BytecodeReplacer/replace_bytecode.py`

Bulk bytecode replacer for genesis files. Finds all occurrences of one runtime bytecode string and replaces it with another — designed for large genesis files (hundreds of MB) with tens of thousands of identical pre-deployed contract entries.

**Workflow:**
1. Paste the **old** runtime bytecode (hex, with or without `0x`) into `old.txt`
2. Paste the **new** runtime bytecode into `new.txt`
3. Run against the target file:

```bash
python3 Tools/BytecodeReplacer/replace_bytecode.py Contracts/Genesis/BesuGenesis.json  # path to extracted genesis
```

**Options:**

| Flag                | Description                                                      |
| ------------------- | ---------------------------------------------------------------- |
| `--old-file <path>` | Path to old bytecode file (default: `old.txt` in same directory) |
| `--new-file <path>` | Path to new bytecode file (default: `new.txt` in same directory) |
| `--dry-run`         | Count matches without modifying the file                         |
| `--no-backup`       | Skip creating a `.bak` backup before replacing                   |

The tool automatically normalizes `0x` prefixes (strips them for matching, preserves them in the output), creates a backup by default, and verifies the replacement count after writing.

### `Tools/TxSimulator/tx_simulator.py`

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
python3 Tools/TxSimulator/tx_simulator.py \
  --rpc http://100.111.32.1:8545 \
  --prompt-mnemonic

# 10 HD accounts, weighted senders, random recipients, Poisson timing
python3 Tools/TxSimulator/tx_simulator.py \
  --rpc http://100.111.32.1:8545 \
  --prompt-mnemonic --num-accounts 10 \
  --sender-mode weighted --sender-weights 50,20,10,5,5,3,3,2,1,1 \
  --recipient-mode random-uniform \
  --amount-mode log-normal --amount-min-eth 0.00001 --amount-max-eth 0.1 \
  --timing-mode poisson --target-tps 5

# Private keys from file, burst timing, star fan-out
python3 Tools/TxSimulator/tx_simulator.py \
  --rpc http://100.111.32.1:8545 \
  --private-keys-file keys.txt \
  --recipient-mode star-fan-out \
  --timing-mode bursts --burst-size 20 --burst-pause 5
```

**Distribution modes:**

| Knob          | Mode               | Description                                                                          |
| ------------- | ------------------ | ------------------------------------------------------------------------------------ |
| **Sender**    | `round-robin`      | A0, A1, A2, … rotate each tx *(default)*                                             |
|               | `single`           | One account sends all txs (`--single-sender-pos`)                                    |
|               | `weighted`         | Probability weights per account (`--sender-weights`)                                 |
|               | `multi-hot`        | First K accounts send, rest are recipient-only (`--hot-senders`)                     |
|               | `random`           | Sender picked uniformly at random                                                    |
| **Recipient** | `ring`             | A[i] → A[i+1 mod n] *(default)*                                                      |
|               | `star-fan-out`     | Hub → random other (overrides sender to hub; `--hub-pos`)                            |
|               | `star-fan-in`      | Any non-hub → hub (`--hub-pos`)                                                      |
|               | `random-uniform`   | Random pair, no self-send                                                            |
|               | `random-no-repeat` | Like uniform but no immediate repeat of same pair                                    |
|               | `partitioned`      | Only send within same group (`--partition-size`)                                     |
|               | `bursty`           | Target a random subset for T seconds, then switch (`--campaign-duration`)            |
| **Amount**    | `fixed`            | Constant amount every tx *(default)*                                                 |
|               | `uniform-random`   | Uniform random in [min, max]                                                         |
|               | `log-normal`       | Many small, occasional large (`--log-sigma`; clamped to [min, max])                  |
|               | `step-schedule`    | Cycle through amounts on a timer (`--step-amounts`, `--step-duration`)               |
|               | `balance-aware`    | Half of (balance − reserve), clamped to [min, max]                                   |
| **Timing**    | `per-block`        | One tx per new block *(default)*                                                     |
|               | `fixed-tps`        | Constant transactions per second (`--target-tps`)                                    |
|               | `poisson`          | Exponential inter-arrival, average = target TPS                                      |
|               | `bursts`           | Send N rapidly, pause, repeat (`--burst-size`, `--burst-pause`)                      |
|               | `ramp`             | Linearly increase TPS (`--ramp-start-tps` → `--ramp-end-tps` over `--ramp-duration`) |
|               | `jittered`         | Base interval ± random jitter (`--jitter-base`, `--jitter-range`)                    |

**All flags:**

| Flag                   | Default       | Description                                               |
| ---------------------- | ------------- | --------------------------------------------------------- |
| `--rpc`                | *(required)*  | RPC endpoint URL                                          |
| `--mnemonic`           | —             | BIP-39 seed phrase (visible in shell history)             |
| `--prompt-mnemonic`    | off           | Prompt for mnemonic via hidden input                      |
| `--indices`            | `0,1,2`       | Comma-separated HD derivation indices                     |
| `--num-accounts`       | —             | Derive N accounts (indices 0..N-1); overrides `--indices` |
| `--private-keys`       | —             | Comma-separated hex private keys (with or without `0x`)   |
| `--private-keys-file`  | —             | File with one hex private key per line (`#` comments OK)  |
| `--sender-mode`        | `round-robin` | Sender selection strategy                                 |
| `--single-sender-pos`  | `0`           | Account position for `single` mode                        |
| `--sender-weights`     | —             | Comma-separated weights for `weighted` mode               |
| `--hot-senders`        | `1`           | Hot sender count for `multi-hot` mode                     |
| `--recipient-mode`     | `ring`        | Recipient selection strategy                              |
| `--hub-pos`            | `0`           | Hub position for `star-fan-out` / `star-fan-in`           |
| `--partition-size`     | `2`           | Group size for `partitioned` mode                         |
| `--campaign-duration`  | `30`          | Seconds per subset for `bursty` recipient mode            |
| `--campaign-subset`    | half          | Target subset size for `bursty` mode                      |
| `--amount-mode`        | `fixed`       | Amount distribution strategy                              |
| `--amount-eth`         | `0.0001`      | Fixed ETH per tx                                          |
| `--amount-min-eth`     | `0.00001`     | Min ETH for random / log-normal / balance-aware           |
| `--amount-max-eth`     | `0.01`        | Max ETH for random / log-normal / balance-aware           |
| `--log-sigma`          | `1.0`         | Sigma for log-normal (higher = heavier tail)              |
| `--step-amounts`       | —             | Comma-separated ETH amounts for `step-schedule`           |
| `--step-duration`      | `60`          | Seconds per step for `step-schedule`                      |
| `--timing-mode`        | `per-block`   | Timing / rate strategy                                    |
| `--target-tps`         | `5`           | Target TPS for `fixed-tps` / `poisson`                    |
| `--burst-size`         | `50`          | Txs per burst for `bursts` timing                         |
| `--burst-pause`        | `10`          | Pause seconds between bursts                              |
| `--ramp-start-tps`     | `1`           | Starting TPS for `ramp` mode                              |
| `--ramp-end-tps`       | `50`          | Target TPS for `ramp` mode                                |
| `--ramp-duration`      | `300`         | Ramp duration in seconds                                  |
| `--jitter-base`        | `1.0`         | Base interval seconds for `jittered` mode                 |
| `--jitter-range`       | `0.5`         | ± jitter range seconds                                    |
| `--poll-interval`      | `0.2`         | Loop sleep when idle                                      |
| `--tip-wei`            | `1000`        | Priority fee (tip) in wei                                 |
| `--max-fee-multiplier` | `2`           | `maxFee = baseFee × multiplier + tip`                     |
| `--topup-enabled`      | off           | Auto-replenish underfunded accounts                       |
| `--topup-funder-pos`   | `0`           | Funder account position                                   |
| `--topup-target-eth`   | `0.01`        | Top-up accounts to this ETH balance                       |
| `--reserve-eth`        | `0.001`       | Reserve ETH kept per account                              |
| `--max-inflight`       | `64`          | Max pending txs before pausing sends                      |

### `Tools/SolcCompiler/compile.py`

Local Solidity compiler using [py-solc-x](https://github.com/iamdefinitelyahuman/py-solc-x). Compiles all `.sol` files under `Contracts/`, resolves imports (vendored OZ 4.9.6 for Genesis contracts, GitHub download for others), and outputs ABI + bytecode artifacts to `compiled_output/`.

```bash
pip install py-solc-x
python3 Tools/SolcCompiler/compile.py
```

Options:
- `--clean-cache` — clear downloaded import cache
- `--solc-version 0.8.34` — override compiler version
- `--evm osaka` — override EVM target (default: `osaka`)

### `Tools/RedeemableCodeGenerator/generate_redeemable_codes.py`

Generates redeemable codes for `PrivateComboStorage` and computes the on-chain hash format: `keccak256(bytes(code))`. PINs are assigned by the contract during `storeDataBatch` — this tool generates the code and its hash for off-chain preparation.

> **Note:** The tool currently generates client-side PINs and hashes as `keccak256(pin + code)` — this is stale. PINs are now contract-assigned and the hash is `keccak256(code)` only. The tool needs updating to match the current contract.

Each run writes the generated output into `Tools/RedeemableCodeGenerator/results/` and also prints the same data to stdout.

```bash
python3 Tools/RedeemableCodeGenerator/generate_redeemable_codes.py --pin-length 6 --code-length 14
python3 Tools/RedeemableCodeGenerator/generate_redeemable_codes.py --pin-length 6 --code-length 14 --count 10 --format json
```

Options:
- `--pin-length` — required PIN length
- `--code-length` — required redeemable code length
- `--count` — number of records to generate (default: `1`)
- `--pin-alphabet` — optional character set for PIN generation
- `--code-alphabet` — optional character set for code generation
- `--format text|json|csv` — choose stdout and saved file format

#### Memory-Safe Assembly

All inline assembly blocks across the codebase are annotated for memory safety. Contracts targeting solc 0.8.34 (Osaka EVM) use the inline `assembly ("memory-safe") { ... }` syntax introduced in solc 0.8.13. Validator contracts targeting solc <0.8.20 (London EVM) use the NatSpec annotation `/// @solidity memory-safe-assembly` above each `assembly { ... }` block, which is the equivalent mechanism for older compiler versions.

These annotations enable the Solidity optimizer's stack-to-memory variable relocation, producing more efficient bytecode. Every annotated block has been audited to confirm it either (a) only uses `sload`/`sstore` on namespaced storage slots, (b) reads from Solidity-allocated memory without writing, or (c) takes full control of memory but never returns to Solidity (e.g., the proxy `_delegate()` pattern that terminates via EVM `return`/`revert`).

#### LF Normalization & Per-Contract Metadata

The compiler normalizes all source files to Unix LF line endings (`\n`) before compilation. This is critical for deterministic, cross-platform builds: `solc` includes a `keccak256` hash of each source file in the IPFS metadata appended to the bytecode tail. Windows CRLF (`\r\n`) vs Unix LF (`\n`) produces different hashes, which changes the IPFS CID embedded in the final ~43 bytes of every contract's bytecode — even though the executable logic is identical.

Normalization is applied at three points:

| Stage                 | What happens                                                                                 |
| --------------------- | -------------------------------------------------------------------------------------------- |
| **Local source copy** | `_copy_normalized()` strips `\r\n` → `\n` when copying `.sol` files into the build directory |
| **Import downloads**  | Remote files fetched from GitHub are normalized on download                                  |
| **All output writes** | ABI, artifact, metadata, and manifest files are written with `newline="\n"`                  |

The compiler also exports each contract's **solc metadata JSON** (the JSON blob whose IPFS hash is embedded in the bytecode) as a `_metadata.json` file alongside the standard ABI and artifact outputs. This file can be published to IPFS or Sourcify for on-chain source verification:

```
compiled_output/
  Genesis/
    7702/
      DakotaDelegation/
        DakotaDelegation_abi.json
        DakotaDelegation_artifact.json
        DakotaDelegation_metadata.json    # solc metadata (IPFS-verifiable)
        ...
```

As long as all parties compile from LF-normalized sources, the resulting bytecode — including the metadata tail — will be identical regardless of operating system.

---

## Repository Structure

```
dakota-network/
├── LICENSE                            # Apache 2.0 + patent notice
├── IMPLEMENTATION.md                  # Full deployment & operations guide
├── Contracts/
│   ├── Genesis/
│   │   ├── BesuGenesis.7z             # Besu genesis file (7z-compressed; extract before use)
│   │   ├── 7702/
│   │   │   ├── DakotaDelegation.sol  # Signed sponsored-execution logic for delegated EOAs
│   │   │   ├── DakotaDelegationBeacon.sol  # Shared implementation beacon
│   │   │   ├── DakotaDelegationBeaconDispatcher.sol  # Stateless per-account dispatcher
│   │   │   ├── DakotaDelegationRegistry.sol  # Fixed-entry control plane and release directory
│   │   │   ├── GasSponsor.sol        # Platform-voucher sponsorship treasury
│   │   │   ├── GAS-SPONSORSHIP.md    # Authoritative deployment/canary/upgrade runbook
│   │   │   ├── EIP-7702-Instructions.md  # Broader EIP-7702 integration guide
│   │   │   ├── Interfaces/
│   │   │   │   ├── IDakotaDelegation.sol
│   │   │   │   ├── IDakotaDelegationRegistry.sol
│   │   │   │   └── IGasSponsor.sol
│   │   │   └── Libraries/
│   │   │       ├── DakotaDelegationCapabilities.sol  # Shared stable feature bitmap
│   │   │       └── DakotaECDSA.sol   # Strict ECDSA recovery helper
│   │   ├── GasManager/
│   │   │   └── GasManager.sol        # Gas beneficiary — voter-governed funding & burns
│   │   ├── ValidatorContracts/
│   │   │   ├── ValidatorSmartContractAllowList.sol  # QBFT validator governance
│   │   │   └── ValidatorSmartContractInterface.sol  # Shared interface
│   │   └── Upgradeable/              # OpenZeppelin 4.9.6 upgradeable contracts (MIT)
│   │       ├── AddressUpgradeable.sol
│   │       ├── Initializable.sol
│   │       ├── ReentrancyGuardUpgradeable.sol
│   │       ├── Proxy/                # Transparent proxy, ERC1967, beacon
│   │       ├── Interfaces/           # Proxy interfaces (IERC1967, IERC1822)
│   │       └── Utils/                # Address, StorageSlot, StringsUpgradeable
│   │           └── Math/             # MathUpgradeable, SignedMathUpgradeable
│   ├── CodeManagement/
│   │   ├── CodeManager.sol       # Permissionless unique ID registry (fee-based)
│   │   ├── PrivateComboStorage.sol # Pente privacy group (private redemption)
│   │   └── Interfaces/
│   │       ├── ICodeManager.sol
│   │       ├── IComboStorage.sol
│   │       └── IRedeemable.sol
│   └── Tokens/
│       ├── GreetingCards.sol          # ERC-721 greeting card NFT (CryftGreetingCards)
│       └── Interfaces/
│           ├── ICodeManager.sol
│           ├── IComboStorage.sol
│           └── IRedeemable.sol
├── Tools/
│   ├── BytecodeReplacer/
│   │   ├── replace_bytecode.py        # Bulk bytecode replacer for genesis files
│   │   ├── old.txt                    # Old bytecode to find (paste here)
│   │   └── new.txt                    # New bytecode to replace with (paste here)
│   ├── KeyWizard/
│   │   └── dakota_keywizard.py       # EOA and Besu node key generator
│   ├── RedeemableCodeGenerator/
│   │   ├── generate_redeemable_codes.py # PIN/code/hash generator for PrivateComboStorage
│   │   └── results/                   # Generated redeemable code output files
│   ├── TxSimulator/
│   │   └── tx_simulator.py            # Block-paced ETH transfer loop (QBFT/PoA)
│   └── SolcCompiler/
│       ├── compile.py                # Local Solidity compiler (py-solc-x)
│       ├── check_gas_sponsor.py      # Initial v1 storage/selector/runtime gate
│       └── compiled_output/          # ABI and artifact output
└── README.md
```

---

## License

All project-owned smart contracts and tools are licensed under the **Apache License, Version 2.0**.

This software is part of a patented system. See the [LICENSE](LICENSE) file for the full license text and patent notice, and <https://cryftlabs.org/licenses> for additional details.

OpenZeppelin-derived contracts under `Contracts/Genesis/Upgradeable/` retain their original **MIT** license.

### Patent Enforcement

The `CodeManager` and `PrivateComboStorage` contracts implement methods claimed in [U.S. Patent Application Serial No. 18/930,857](https://patents.google.com/patent/US20250139608A1/en). **Any unauthorized use, reproduction, or deployment of these contracts or substantially similar implementations will be pursued through legal action. All costs, damages, and attorney fees will be sought against the infringing party.** Contact <https://cryftlabs.org/licenses> for licensing.
