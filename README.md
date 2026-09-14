# Dakota Network

Smart contracts, tools, and node configuration for the **Dakota Network** — an enterprise QBFT blockchain built on Hyperledger Besu with [Paladin](https://github.com/LFDT-Paladin/paladin) privacy, designed for permissioned environments where a fully public and decentralized network is not required.

All project-owned contracts are licensed under **Apache 2.0**. This software is part of a patented system — see the [LICENSE](LICENSE) file and <https://cryftlabs.org/licenses> for details.

The [tenant allowance release](Tools/TenantAllowances/README.md) adds GasSponsor
1.1.0 and an optional tenant-owned allowance template. It preserves existing
storage and genesis, supports sponsored member and admin wallets, and provides
per-operation/day rules with atomic reimbursement accounting. Reproducible
Standard JSON inputs, metadata and validation records are under
`Releases/TenantAllowances/1.0.0`; code compiles with Solidity 0.8.37 for Osaka.
Validator contracts retain London. Account management and template ownership are
separate authorities; adding sponsorship permission grants neither.

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


## Development release status

The owner subsequently authorized implementation merges on September 11.
Network, KotaRouter, website and explorer main now contain their reviewed source
and documentation. Source publication does not deploy application services.
Review branches remain for traceability. Start with [current status and documentation
index](docs/CURRENT_STATUS.md), [operations](IMPLEMENTATION.md), and the
[resume prompt](docs/ONE_SHOT_DEPLOYMENT.md). Main records development work and is
not a production deployment approval. Historical acceptance reports keep their
original audit blocks, compiler hashes and results.

The September 11 development deployment has initialized the four named genesis
services and passed public-chain governance, funding, redemption and real EIP-7702
sponsorship checks. All 100 submitted receipts were reconfirmed, and nested calls
are indexed by the Nebula explorer. Metadata/source CIDs were read back from
Backend-01's IPFS pins and private gateway. See [live acceptance](docs/live-genesis-acceptance-20260911.md)
and [the observer/handoff prompt](Tools/LiveGenesis/FOLLOW_AND_HANDOFF_PROMPT.md).
Paladin/Pente is also running: five private code redemptions delivered public card
NFTs, including native EIP-7702 sponsored settlement, delivery recovery and concurrent
redemption checks. The strict settlement upgrade prevents public rejection from
consuming a private code. See [Paladin acceptance](docs/paladin-acceptance-20260911.md)
and the [maintenance/funding runbook](Tools/Paladin/README.md). Sponsorship is paused
after cleanup. Final admin acceptance, Router/application integration and production
acceptance remain outstanding.

The management address is `0x9247524040D91D5dd1521A25f2e7711d4a0fe921`.
Kota tenant administration is fully handed over to this address. Core network,
sponsor/delegation, card and private-state handovers remain separate; see the
[authority inventory](docs/CURRENT_STATUS.md). Remove remaining deployment-account
roles only after their replacements are effective and required acceptance is complete.

The new Kota release added ten fully verified public instances and 43 verified
IPFS objects. The moment.cards registry is `0xA6B1dFA510B2854b8FA33ab3865535bb41CC2340`.
These membership credentials are separate from redeemable card NFTs. The 32,451
address genesis/application audit remains its historical baseline; its counts
and hashes are not rewritten to include later deployments.

## Quick Reference

| Component                | Version | Notes                                                        |
| ------------------------ | ------- | ------------------------------------------------------------ |
| **Besu**                 | 26.8.1  | Java 25, QBFT consensus                                      |
| **solc**                 | 0.8.37  | This repository's current non-validator artifacts                     |
| **solc**                 | 0.8.19  | Validator contracts only (pragma `<0.8.20`)                  |
| **EVM target**           | Osaka   | Public contracts compiled with solc 0.8.37                   |
| **Private EVM target**   | Shanghai | Newest execution target selected by installed Pente v1.0.0; live opcode checks passed |
| **EVM target**           | London  | Validator contracts (solc 0.8.19 maximum)                    |
| **Kota tenant contracts** | 1.4.0 / v7 | Separate KotaRouter release: solc 0.8.34 / Osaka / MIT |
| **Paladin**              | v1.0.0  | Pente privacy domain (replaces Tessera)                      |
| **Native sponsorship**   | 1.0.0   | EIP-7702; no ERC-4337, bundler, EntryPoint, or paymaster     |

> **System maintenance:** the existing **[Implementation Guide](IMPLEMENTATION.md)** covers Besu, genesis, networking, services and handover; its **[Paladin runbook](Tools/Paladin/README.md)** records the deployed rootless services, funding addresses and private-state recovery procedures.

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

The genesis file (`Contracts/Genesis/besuGenesis.7z`, compressed) contains the full initial state for the network. Extract with 7-Zip before use — the uncompressed JSON is ~1.25 GB.

#### Chain Parameters

| Parameter               | Value                                                                      |
| ----------------------- | -------------------------------------------------------------------------- |
| **Chain ID**            | `112311`                                                                   |
| **Consensus**           | QBFT (Istanbul BFT)                                                        |
| **Gas limit**           | 64,000,000 (`0x3D09000`)                                                   |
| **Block reward**        | 3.2 ETH per block (sent to `miningBeneficiary`)                            |
| **Contract size limit** | 32,768 bytes (32 KiB)                                                      |
| **EVM fork**            | Osaka + BPO5 (Osaka execution rules, BPO1–BPO5 at timestamp 0)               |

The development genesis uses **`config.contractSizeLimit: 32768`**. The compiler and
runtime receipts identify its exact bytecodes. Besu 26.8.1 requires the supported
`emptyBlockPeriodSeconds` name for the existing 64-second interval. Preserve all
other chain settings from the archive. A live boundary deployment remains an
acceptance test; historical `compiled_output/` files are not current release inputs.

#### Ethereum Fork Activation

The applicable execution rules through Osaka are active from genesis. Earlier
forks use block-number fields; Shanghai and later use timestamp fields. Setting
these timestamps to `0` makes them active from genesis, even though the genesis
header has its own nonzero creation timestamp. QBFT remains the consensus engine;
mainnet-only DAO recovery, difficulty-bomb and PoS transition settings are not
required to obtain the Osaka EVM on this chain.

The archive enables Homestead, EIP-150, EIP-155/158, Byzantium,
Constantinople, Petersburg, Istanbul, Muir Glacier, Berlin and London at block 0;
Shanghai, Cancun, Prague, Osaka and BPO1–BPO5 at timestamp 0. The archive is the
source of truth for exact field names and values. Besu compatibility must be
verified against the pinned binary; do not substitute a generic development genesis.

**Milestone review — 2026-09-11, Besu 26.8.1:** the pinned release recognizes
`bpo3Time`, `bpo4Time`, `bpo5Time` and `amsterdamTime` beyond the former BPO2
configuration. The existing README is updated here to distinguish supported
configuration fields from finished EVM upgrades.

| Milestone | Decision for this genesis | Effect |
|---|---|---|
| Osaka | `osakaTime: 0` | Current finalized EVM; public compiler target remains Osaka. |
| BPO1–BPO5 | All five `bpoNTime` fields are `0` | Finalized parameter-only milestones; no new opcodes. |
| Amsterdam | Omitted | Besu 26.8.1 explicitly marks it unfinalized and warns against production use. Changes include gas accounting, transfer logs, block access lists and header requirements; evaluate separately. |
| Future/experimental EIPs | Omitted | Development definitions, not an automatic way to enable supported production features. |
| Bogota, Polis, Bangkok | Not configured | Names exist in the EVM library, but this release's genesis timestamp schedule does not register corresponding activation fields. |

**BPO parameters are not implied by the milestone name.** This custom genesis
does not define `blobSchedule`. Besu 26.8.1 therefore inherits the existing Prague
defaults: target **6**, maximum **9** blobs per block, base-fee update fraction
**5,007,716**. Adding BPO3–BPO5 preserves those values; it does not automatically
adopt Ethereum mainnet's larger BPO settings. This is not a blob-capacity upgrade
or evidence that QBFT blob transactions have passed application acceptance.

A read-only probe against the installed Besu 26.8.1 libraries compared the old
BPO2 and new BPO5 QBFT schedules using the live genesis state root. Both produced
genesis block hash `0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8`,
Osaka execution, the **32,768-byte** code limit, the **49,152-byte** initcode limit,
the same blob/gas settings and QBFT reward. The archive changes only three
timestamp fields; all allocation bytecodes, storage, balances and header values
are byte-preserved. No contract recompilation or IPFS metadata republishing is
needed for this parameter-only update. Validator compilation remains London and
its `getValidators()` ABI is unchanged.

See [the controlled update procedure](Tools/Deployment/README.md) and
`Contracts/Genesis/development-release.json` for archive hashes. Deployment receipts
must separately confirm each host restarted with `[BPO5:0]`; the source archive
alone is not proof of live rollout. Never generalize this compatible update to a
retroactive Amsterdam activation or any other change to executed rules.

The development rollout is now verified: all seven hosts hold the new archive's
genesis, all six Besu services restarted with `[BPO5:0]`, and all six synchronized
at block 43 after the final validator restart. No database reset or application
transaction was needed. See [recorded evidence](docs/besu-milestone-review.json).

Sources: [26.8.1 release notes](https://github.com/besu-eth/besu/releases/tag/26.8.1),
[pinned fork finalization flags](https://github.com/besu-eth/besu/blob/26.8.1/datatypes/src/main/java/org/hyperledger/besu/datatypes/HardforkId.java),
[pinned timestamp schedule](https://github.com/besu-eth/besu/blob/26.8.1/ethereum/core/src/main/java/org/hyperledger/besu/ethereum/mainnet/milestones/MilestoneDefinitions.java),
[BPO parameter inheritance](https://github.com/besu-eth/besu/blob/26.8.1/ethereum/core/src/main/java/org/hyperledger/besu/ethereum/mainnet/MainnetProtocolSpecs.java),
[genesis configuration reference](https://docs.besu-eth.org/public-networks/reference/genesis-items).

#### Alloc Entries (32,436 total)

| Category                    | Count  | Description                                                                  |
| --------------------------- | ------ | ---------------------------------------------------------------------------- |
| Addresses ending in `323`   | 32,324 | Pre-deployed contract instances (greeting card service)                      |
| Addresses ending in `c0DE`  | 100    | Pre-deployed contract instances (code management service)                    |
| Repeating-pattern addresses | 4      | Reserved contract slots (`0x2222...`, `0x2323...`, `0x3232...`, `0x3333...`) |
| Reserved system addresses   | 7      | Governance and infrastructure contracts (see below)                          |
| EOA accounts                | 3      | Management account: 32 ETH; deployment and delegation test accounts: 1 ETH each                                 |

#### Reserved System Addresses

| Address             | Comment                    | Purpose                                                                       |
| ------------------- | -------------------------- | ----------------------------------------------------------------------------- |
| `0x0000...1111`     | Validator smart contract   | `ValidatorSmartContractAllowList` — QBFT validator/voter/overlord governance  |
| `0x0000...cafE`     | GasManager smart contract  | `GasManager` — block reward beneficiary, voter-governed gas funding and burns |
| `0x0000...c0DE`     | CodeManager smart contract | `CodeManager` — official Dakota code management service (patent-covered)      |
| `0x0000...Face`     | ERC-8004 Agent Registry    | Official ERC-8004 agent identity contract                                     |
| `0x0000...FacAdE`   | ProxyAdmin smart contract  | `ProxyAdmin` — guardian-gated ERC1967 upgrade dispatch                        |
| `0x0000...de1E6A7E` | EIP-7702 delegation entry  | Registry control plane; user EOAs authorize the separate immutable dispatcher directly |
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

### ValidatorSmartContractAllowList

The registry at `0x0000000000000000000000000000000000001111` retains voter-governed validator, voter, and root-overlord membership. Decisions require `ceil(2N/3)` approvals from the unique approved electorate. This is the retained governance model, with the pre-genesis fixes described below.

**Besu compatibility:** `getValidators()` remains `public view override returns (address[] memory)`, with the same selector and standard ABI encoding. The registry address and `ValidatorSmartContractInterface` are unchanged. Compile this contract with **Solidity 0.8.19, London, optimizer 200 runs**. The initial list comes from reviewed genesis storage; later queries return the approved validator set without consulting external providers on Besu's read path. Updated sets are unique and sorted by address.

#### Governance changes

| Area | Current behavior |
| --- | --- |
| Membership ballots | A proposal can receive its second and subsequent votes. Membership proposals no longer block themselves through `activeVoteCount`. |
| Quorum | Each ballot freezes its unique electorate, threshold, and expiry when its first vote is cast. An address receives one vote even when present in several registries. |
| External providers | Membership changes and explicit refreshes validate bounded provider responses. Provider failure leaves the last approved list and pending ballot threshold intact. |
| Membership refresh | `previewVoters`, `previewValidators`, and `previewRoots` expose candidate lists and their hashes. The corresponding `voteToRefresh*` action adopts the exact reviewed list. Provider changes are not adopted automatically. |
| Atomic recovery | `voteToSetVoterConfiguration`, `voteToSetValidatorConfiguration`, and `voteToSetRootConfiguration` replace local members and providers together. This permits removing multiple failed providers or transferring sole authority without an empty intermediate set. |
| Pending ballots | An approved voter configuration or refresh advances the governance epoch, invalidating other pending ballots. Already approved application funding remains subject to its original execution rules. |
| Validator safety | Membership changes retain at least four unique validators and do not exceed `maxValidators`. The configurable maximum is 4–64. `voteToReplaceValidator` replaces a local validator atomically, including at the minimum. |
| Authority safety | Changes cannot empty the effective voter or root-overlord set. Zero addresses, self-administration, and the fixed ProxyAdmin facade cannot become effective governance members. |
| Expiry | New ballots use 1–100,000 blocks, default 1,000. Anyone may clear an expired tally with `resetExpiredTally`; this grants no voting authority. |

`getVoters`, `getValidators`, `getRootOverlords`, their count functions, and their membership predicates all describe the same respective approved sets. Existing voting function selectors and enum values remain; new values are appended. `getVoteTally`, `hasVoted`, and `activeVoteCount` retain their callable signatures. `getProposalSnapshot` and `governanceEpoch` expose the additional ballot state. The active counter includes expired ballots until cleanup/restart and resets on epoch invalidation.

#### External management revocation

The existing irreversible revocation sequence remains: root-overlord management, validator management, then voter management. Each revoked domain must have no local entries and a usable external set; validators must still number at least four. Revocation freezes local/provider configuration, including the new atomic configuration methods. Explicit refresh votes remain available to adopt upstream changes. It does not introduce a bypass for a failed permanently selected provider.

**Bootstrap decision retained:** `initialize()` still checks whether the local voter array is empty. This is not a permanent initialization guard, including after a later external-only handover. Restricted initial access was the operator's explicit decision; the initializer must be revisited before broader access or that handover. No new root EOA or validator addresses have been selected by this change.

See the [governance maintenance guide](Contracts/Genesis/GOVERNANCE.md) for operational steps, limits, authority differences, and fresh-genesis requirements, and [local regression tests](Tests/Governance/README.md) for verification.

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
`.call{value:}`, while sponsor funding invokes the typed `depositGasCredit` entry
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

The GasManager has its own local `votersArray[]` and pluggable `otherVoterContracts[]`, completely independent from the ValidatorSmartContractAllowList voter pool. External providers supply `getVoters()`; membership checks use the approved unique array rather than trusting a separate provider predicate. The shared snapshot, explicit refresh, and atomic recovery rules above apply. A membership change must leave at least one effective voter; successful changes invalidate pending ballots.

#### Convenience View Functions

| Function                           | Returns                                                             | Description                                                          |
| ---------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `isVoter(address)`                 | `bool`                                                              | Check if address is a voter (local + external contracts)             |
| `getVoters()`                      | `address[]`                                                         | Unique approved local and external voters                |
| `getVoterCount()`                  | `uint256`                                                           | Number of unique approved voters |
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

The shared governance engine rejects empty effective voter sets and invalid authorities. Atomic voter configuration permits a sole-voter handover and removal of several failed providers. Snapshot thresholds cannot fall when a provider fails, and expired ballots can be cleared without voter privileges.

Guardians remain operational roles that voters can add again after removal; an empty guardian list therefore does not destroy governance. Funding and burn execution retain reentrancy and balance checks. Funding recipients remain bound to their approved requests. GasManager's named custom errors replace several revert strings; integrations must use the rebuilt ABI when decoding failures.

#### Upgradeability

GasManager inherits `Initializable` and `ReentrancyGuardUpgradeable` from OpenZeppelin v4.9.6. The constructor calls `_disableInitializers()` to lock the implementation contract. `initialize()` retains direct-caller setup; `initializeWithVoter(address)` supports an explicit usable voter during atomic proxy/factory initialization. This explicit initializer is also available on CodeManager. Neither accepts the application itself or the fixed ProxyAdmin facade as the voter.

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

Root authority is read dynamically from the validator registry; no root EOA is compiled into the proxy. The registry serves its last approved root set independently of upstream provider availability. Proxy ballot membership reads fail closed if the registry itself cannot return a valid bounded list, rather than silently reducing quorum.

#### Overlord Count and Supermajority Threshold

- `proxy_getOverlordCount()` = unique union of local overlords and active roots; an overlapping address counts once
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
| Change vote expiry    | `proxy_proposeExpiryChange(newExpiry)`       | 100–100,000 blocks                                           |
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
- **Vote expiry**: Default 60,000 blocks; a ballot freezes its expiry at its first vote. Allowed settings are 100–100,000 blocks. Expired proposals start a new round.
- **Vote context**: A fingerprint includes the current unique root/local controller set, root-revocation state, and epoch. Root rotation or a local governance change invalidates pending proxy votes. Each ballot freezes its electorate and threshold.
- **Proposal rounds**: Each proposal key tracks a round counter. On expiry, the round increments, creating a fresh proposal ID while preserving the base key.

#### Storage Design

All proxy governance state is stored in **namespaced `keccak256` slots** (e.g., `keccak256("TransparentUpgradeableProxy.overlordMap")`) to avoid collisions with the implementation contract's storage. Proxy voting uses `keccak256("cryft.proxy.governance.votes.v1")`; application voting uses `keccak256("cryft.governance.snapshot.v1")`. These must stay separate because the application executes through delegatecall at the same address. Local proxy-controller enumeration is fresh-genesis state, not an automatic migration of a previously deployed shell.

#### Proxy Linkage (One-Time)

`proxy_linkLogicAdmin(logic, data)` — guardian-gated, can only be called once (`isInit` flag). Sets the implementation address and initializes it with `data`. The admin is immutable (baked into bytecode at compile/genesis time), so no admin assignment occurs at link time.

#### Lockout Prevention

| Scenario | Guard or recovery |
| --- | --- |
| Remove the final effective controller | Rejected; local and active root membership are counted uniquely |
| Revoke roots without a local controller | Rejected for both direct and voted revocation |
| Remove every explicit guardian | Controllers can vote to add operational guardians again |
| Change controller membership during a ballot | The membership fingerprint and epoch invalidate stale approvals |
| Configure an unusable vote expiry | Only 100–100,000 blocks are accepted |
| Overlap local and root roles | A controller counts once toward quorum |
| Interfere with application voting through the proxy | Proxy and application ballots use separate storage namespaces |
| Upgrade through ProxyAdmin after root rotation | The former root loses authority; the current root is resolved dynamically |

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
| **CodeManager**         | **Patent-covered.** Gift-authorized unique ID registry with an independent voter pool, 2/3 supermajority quorum, public mirrored UID state, and Pente routing. Charges a configurable registration fee forwarded to a fee vault. Deterministic ID generation via `keccak256(address(this), giftContract, chainId) + counter`.                                                                                                                                                                      |
| **PrivateComboStorage** | Private hash/PIN state, bounded batches, rotatable service roles and two-step administration. |
| **PrivateMetaTxRelay** | Disabled legacy fallback; requires separate hardening if live delegation tests establish a need. |
| **DakotaDelegation**    | Initial v1 EIP-7702 execution logic. Verifies an account-owner EIP-712 signature, enforces per-account nonces/deadlines/execution gas budgets, executes bounded call batches, and supports EIP-1271 validation. It intentionally exposes no generic owner/session-key execution API.                                                                                                                                                                                                              |
| **DakotaDelegationBeacon** | Shared implementation beacon whose constructor accepts only the implementation and derives its temporary owner from the root caller validated by `0x...1111`. After bootstrap, the fixed delegation entry owns it and Registry upgrades call `upgradeTo(newImplementation)` once.                                                                                                                                                                                                                  |
| **DakotaDelegationBeaconDispatcher** | Immutable direct EIP-7702 route with beacon/protocol getters. |
| **GasSponsor**          | Initial v1 platform-managed sponsorship treasury. Validates platform-signed vouchers, approved EIP-7702 delegation, allowlisted relayers, tenant/sponsor limits, operation replay protection, gas envelopes, and bounded reimbursement.                                                                                                                                                                                                                                                           |
| **CryftGreetingCards**  | ERC-721 NFT (service client — not patent-covered). Mint-on-purchase from pre-registered supply. Per-batch `PurchaseSegment` storage for gas-efficient buyer/URI lookups (binary search). Active-state authority is externalized to the private redeemable-code system. Interfacing with the redeemable-code service is permitted with proper fees or license.                                                                                                                                     |

---

### CodeManager (Unique ID Registry + Pente Router)

Gift-authorized unique ID registry with an independent voter pool. All governance actions require **2/3 supermajority quorum**: `(totalVoterCount * 2 + 2) / 3`. The approved voter pool is the unique union of local and explicitly adopted external members. It uses the same snapshot, refresh, atomic recovery, and last-voter protections as the validator registry. Membership ballots can finish while other ballots are pending; approval invalidates the other pending ballots.

Also serves as the public mirror and Pente router. Private code consumption uses `recordRedemptionStrict`, which reverts rejected public preconditions so the enclosing Pente transition leaves its private code unspent. The legacy `recordRedemption` ABI remains best-effort. Accepted redemptions mark the UID terminally redeemed and record its recipient before bounded gift delivery; delivery failure supports permissionless retry to that same recipient. Active/inactive state is mirrored publicly with sparse overrides. The strict implementation is 24,784 bytes, within this chain’s existing 32,768-byte limit, with unchanged storage layout.

#### Governance Actions (all require voter supermajority)

| Action                               | Function                                       | Constraints                                                            |
| ------------------------------------ | ---------------------------------------------- | ---------------------------------------------------------------------- |
| Add whitelisted address              | `voteToAddWhitelistedAddress(address)`         | Voter supermajority required                                           |
| Remove whitelisted address           | `voteToRemoveWhitelistedAddress(address)`      | Voter supermajority required                                           |
| Update registration fee              | `voteToUpdateRegistrationFee(uint256)`         | Voter supermajority required                                           |
| Update fee vault                     | `voteToUpdateFeeVault(address)`                | Voter supermajority required                                           |
| Add voter                            | `voteToAddVoter(address)`                      | Not already an effective voter; safe resulting set                            |
| Remove voter                         | `voteToRemoveVoter(address)`                   | Resulting effective voter set must remain nonempty                       |
| Add external voter contract          | `voteToAddOtherVoterContract(address)`         | Bounded `getVoters()` response; safe unique resulting set     |
| Remove external voter contract       | `voteToRemoveOtherVoterContract(address)`      | Safe resulting effective voter set                                                 |
| Update vote tally block threshold    | `voteToUpdateVoteTallyBlockThreshold(uint256)` | 1 to 100,000 blocks                                                    |
| Authorize/de-authorize privacy group | `voteToAuthorizePrivacyGroup(address)`         | Toggles `isAuthorizedPrivacyGroup[addr]`; voter supermajority required |
| Reset expired tally                  | `resetExpiredTally(VoteType, uint256)`         | Permissionless; tally must have expired                                    |

#### Pente Router Functions (called by authorized privacy groups)

| Function                                          | Description                                                                                                                                                                                                          |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `recordRedemptionStrict(uniqueId, redeemer)` | Private/public atomic boundary: reverts public precondition rejection; accepted delivery failures retain the recipient for retry. |
| `recordRedemption(uniqueId, redeemer)`            | Legacy best-effort boundary. Resolves UID → gift contract, marks REDEEMED, calls `IRedeemable.recordRedemption()` with bounded delivery and a committed-recipient retry record. Inspect application and delivery status separately. |
| `setUniqueIdActiveBatch(uniqueIds, activeStates)` | Mirrors sparse UID active-state changes from an authorized privacy group. Redeemed UIDs are rejected and left terminal.                                                                                              |

#### Registration (gift-authorized)

| Function                                             | Description                                                                                                         |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `registerUniqueIds(giftContract, chainId, quantity)` | Gift or approved registrar only; payable — `registrationFee × quantity`. Forwards fee to `feeVault`. Increments counter range for the gift contract. |

#### Convenience View Functions

| Function                                      | Returns                                                             | Description                                                          |
| --------------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `isVoter(address)`                            | `bool`                                                              | Check if address is a voter (local + external contracts)             |
| `getVoters()`                                 | `address[]`                                                         | Unique approved local and external voters                |
| `getVoterCount()`                             | `uint256`                                                           | Number of unique approved voters |
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

### PrivateComboStorage (Pente privacy group)

Private state stores hashes, assigned PINs, registered counter ceilings, active
status and redemption state. Initialize a private proxy atomically using
`initialize(admin, service, forwarder)`. `ADMIN`, `AUTHORIZED` and
`TRUSTED_FORWARDER` are storage-backed getters; addresses can change without
recompiling. Use zero forwarder for the direct/delegated path. The implementation
is locked against direct initialization. Use a private-domain proxy whose authority
exists in that group; the public validator registry cannot be assumed available there.

Admin transfer is proposed, accepted by the recipient, or cancelled. Rotate the
service/forwarder and audit per-UID managers during handover. Batch operations are
bounded to 100 entries. PIN/hash reservations within a batch prevent duplicate
allocation; canonical identifiers prevent ambiguous registration/redemption routes.
The current implementation emits `recordRedemptionStrict` so public rejection cannot
silently consume a private code. Public delivery retries retain the original committed
recipient. See the live [upgrade and lifecycle evidence](docs/paladin-acceptance-20260911.md).

### PrivateMetaTxRelay (legacy fallback, disabled)

The existing v1 source remains for compatibility research. It has compile-time
addresses and an older signature envelope. It is not enabled in the deployment
profile. Test private native delegation and sponsored Pente transition settlement
first. Use a relay only after evidence establishes that it is required, followed by
a separate hardening review and live tests. A successful public EIP-7702 transaction
does not establish private EIP-7702 support.

### Native EIP-7702 delegation and gas sponsorship

The account route is `EOA -> immutable v2 dispatcher -> beacon -> account logic`.
The reserved `0x...de1E6A7E` proxy hosts the release registry. The reserved
`0x...FEeD` proxy hosts GasSponsor. Neither requires a fixed implementation baked
into genesis. No per-account proxy initializer or EIP-1967 slot write is needed.

The sponsor verifies the direct authorization route, dispatcher code hash,
execution signature and voucher limits. Query `minimumCallGas` before signing;
return data and gas forwarding are bounded. `depositFor` funds a refundable tenant
balance; `depositGasCredit` funds restricted sponsorship credit. GasManager uses
restricted credit, which tenant managers cannot withdraw. Credit is spent first.

Use the current [sponsorship guide](Contracts/Genesis/7702/GAS-SPONSORSHIP.md)
for deployment order, readiness checks, replay protection and ownership handover.
The July live-deployment runbook is historical evidence, not this release's configuration.

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

Each compiled contract, library, interface and abstract contract now has a self-contained `<Contract>_standard_input.json` for verification. Output folders include the EVM target; compiler identity and input SHA-256 are recorded in the artifact/manifest. Validators stay pinned to solc 0.8.19/London. Private contracts use the target supported by the selected Pente runtime, independently of the public chain. See the [compiler guide](Tools/SolcCompiler/README.md) for verification replay, private proxies and the pending EVM upgrade.

```bash
pip install py-solc-x==2.0.5
python3 Tools/SolcCompiler/compile.py --output-dir /absolute/path/to/review-artifacts
```

Options:
- `--clean-cache` — clear downloaded import cache
- `--solc-version 0.8.37` — override compiler version
- `--evm osaka` — override EVM target (default: `osaka`)
- `--private` — compile a selected proxy/dependency for the private EVM too
- `--private-evm shanghai` — explicit private target, subject to Pente support
- `--output-dir PATH` — write review artifacts outside historical checked-in output

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

All inline assembly blocks across the codebase are annotated for memory safety. Contracts targeting solc 0.8.37 (Osaka EVM) use the inline `assembly ("memory-safe") { ... }` syntax introduced in solc 0.8.13. Validator contracts targeting solc <0.8.20 (London EVM) use the NatSpec annotation `/// @solidity memory-safe-assembly` above each `assembly { ... }` block, which is the equivalent mechanism for older compiler versions.

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
│   │   ├── CodeManager.sol       # Gift-authorized unique ID registry (fee-based)
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

### Deployed artifact verification

**Source verification is complete for all 32,451 public addresses**, including
every genesis proxy. Independent checks matched every stored runtime/source hash
and license, with no partial matches or failures. Read the
[final report and evidence](docs/blockscout-verification-20260911.md).

The [2026-09-11 verification package](Contracts/Verification/20260911/README.md)
includes Standard JSON input/output, exact compiler metadata, ABI and bytecode for
all 21 distinct audited deployed builds. Its inventories cover 32,433 genesis
contracts, 18 later public creations, five private deployments and 18 native
precompile exclusions. Every Solidity build reproduced exactly. See the manifest
for the audit block and precise coverage; this does not assert completed explorer
uploads. The [Blockscout runbook](Tools/BlockscoutVerification/README.md) and
[handoff prompt](Tools/BlockscoutVerification/HANDOFF_PROMPT.md) preserve actual
per-target licenses: Apache-2.0 uses `apache_2_0` (12), MIT uses `mit` (3).

### Source notices

Project-owned contracts and tools generally use the **Apache License, Version 2.0**.
The new `Contracts/Paladin/ManagedProxyAdmin.sol` and `DeliveryFailureProbe.sol`
declare **MIT**; preserve each source file's actual SPDX notice and deployed metadata.

This software is part of a patented system. See the [LICENSE](LICENSE) file for the full license text and patent notice, and <https://cryftlabs.org/licenses> for additional details.

OpenZeppelin-derived contracts under `Contracts/Genesis/Upgradeable/` retain their original **MIT** license.

### Patent Enforcement

The `CodeManager` and `PrivateComboStorage` contracts implement methods claimed in [U.S. Patent Application Serial No. 18/930,857](https://patents.google.com/patent/US20250139608A1/en). **Any unauthorized use, reproduction, or deployment of these contracts or substantially similar implementations will be pursued through legal action. All costs, damages, and attorney fees will be sought against the infringing party.** Contact <https://cryftlabs.org/licenses> for licensing.
