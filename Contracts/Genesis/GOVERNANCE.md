# Dakota governance maintenance guide

## 1. Scope and release status

This revision retains enterprise governance by approved voters and the existing dynamic root registry. It addresses ballot completion, duplicate membership, changing quorum, and unintended loss of controllers. It is intended for a **fresh genesis**, subject to the final contract, address, and authority review.

Do not deploy the archived `besuGenesis.7z` or previously committed compiled artifacts as this revision. Rebuild from the approved source commit, replay every Standard JSON input, review storage allocations and runtime hashes, and publish the exact metadata and referenced source bytes. Source publication does not establish IPFS publication or authorize chain deployment.

The documented runtime contract limit remains **32,768 bytes**. The archived genesis places `contractSizeLimit` outside `config`; the fresh genesis must use `config.contractSizeLimit: 32768`, verified against the selected Besu release. A source-size check is not proof that a running node applies that setting. Test an ordinary contract creation on both sides of the boundary in an isolated Besu network before launch.

The validator build remains Solidity **0.8.19 / London / optimizer 200 runs**. Other public contracts use **0.8.34 / Osaka / optimizer 200 runs**. A private execution profile is a separate Paladin/Pente compatibility decision.

## 2. Authorities and the changes in each contract

| Contract | Authority and changes | Recovery or meaningful difference |
| --- | --- | --- |
| `ValidatorSmartContractAllowList` at `0x...1111` | Retains voter ballots. Adds unique approved membership, frozen ballot parameters, explicit upstream refresh, atomic configurations, and a four-validator floor. | Governance can replace a sole voter/root or a validator at the floor without an empty intermediate state. Existing irreversible management revocation remains. |
| `GasManager` at `0x...cafE` | Same shared voting engine, with an independent voter pool. Adds explicit-voter initialization. Several revert strings become named custom errors. | Voters can restore removed guardians. Funding, burn, recipient binding, sponsor deposits, and execution permissions retain their existing economic rules. |
| `CodeManager` at `0x...c0DE` | Same shared voting engine and explicit-voter initialization. | Voters can restore privacy-group authorization and update fee routing. Registration and public redemption behavior are outside this governance change. |
| Custom `TransparentUpgradeableProxy` | Retains dynamic roots, local overlords, operational guardians, and one active governance session. Deduplicates controller overlap and invalidates ballots after root rotation. Proxy voting has storage separate from its delegated application. | Last-controller checks remain; root revocation requires a local controller. Local controllers can vote to restore roots. Expiry must be 100–100,000 blocks. A proxy with zero explicit guardians is recoverable by its controllers. |
| `ProxyAdmin` at `0x...FacAdE` | Unchanged: checks guardian authority on the target proxy before dispatching an upgrade. | It has no independent owner to rotate or recover. Dynamic root rotation is tested through actual proxy upgrades. |
| `GasSponsor` at `0x...FEeD` | Retains two-step platform-admin transfer; adds cancellation and rejects self/facade admin identities. | Admin controls remain available while sponsorship is paused. Sponsor-manager rotation remains direct because platform administration can recover it; it is not a transfer of sole chain authority. |
| `DakotaDelegationRegistry` at `0x...de1E6A7E` | Retains propose/accept/cancel registry-admin transfer and rejects self/facade identities. Adds registry calls to accept and cancel beacon ownership transfers. | The current admin remains active until acceptance. The registry can accept ownership of its configured beacon and continue validated implementation upgrades. |
| `DakotaDelegationBeacon` | Changes ownership transfer to propose/accept, adds cancellation, and disables renunciation. | The old owner can still upgrade or cancel until acceptance. A multisig/contract owner must be capable of making the acceptance call. |
| `DakotaDelegation` | Unchanged account execution/signature rules. | This is delegated account logic, not a chain-administrator registry; adding an admin backdoor would change its authorization model. |
| `DakotaDelegationBeaconDispatcher` | Unchanged stateless routing and beacon binding. | Recover the implementation through the beacon/registry, not by introducing a second dispatcher owner. |
| Vendored ERC1967, Initializable, reentrancy, and utility contracts | Unchanged. | They supply mechanisms to the above concrete contracts. Their inherited APIs do not create additional deployed governance authorities. |

The fixed registry and facade addresses are protocol wiring, not hard-coded EOAs. This change does not choose a replacement bootstrap root or final validator identities. Private code-storage contracts and their address constants remain a separate review.

## 3. Ballot lifecycle

The validator registry, GasManager, and CodeManager each maintain their own approved voter set. The first successful vote on a proposal freezes the electorate, `ceil(2N/3)` threshold, starting block, and expiration block. Membership addresses are unique, sorted numerically, and restricted to 64 per effective set. Examples: one voter needs one approval; two need two; three need two; four need three.

Only members of that ballot's snapshot may vote, once per address. The vote that reaches threshold executes the proposed change atomically. If validation or execution reverts, that final vote is also rolled back; prior votes are not silently counted toward a different request.

A successful voter membership change, explicit voter refresh, or voter-management revocation advances that contract's epoch and invalidates other pending ballots. Expiry-policy changes apply to future ballots. Application operations that have already been approved, such as GasManager funding, remain governed by their separate execution and expiry rules.

`getProposalSnapshot(type, target)` reports threshold, expiry, epoch, and electorate. `getVoteTally(type, target)` retains its four return values. Expired tallies remain visible and occupy the active counter until reset/restart; `hasVoted` is false for expired or invalidated ballots. Anyone may call `resetExpiredTally` for an expired current ballot. This cannot approve a request, change membership, or clear a live ballot. At most 64 current ballots may occupy the counter; clear expired ballots before opening more. Epoch invalidation resets the active count without iterating through old storage.

Atomic-configuration targets bind the entire local/provider configuration and expected member hash. Existing enum values remain in the same positions; new values are appended. Integrations should use each contract's rebuilt ABI and enum rather than reusing numbers from a different contract.

## 4. External registries and outage recovery

External registries continue to provide `getVoters()`, `getValidators()`, or `getRootOverlords()`. Each read has a 300,000 gas allowance and checks response size/encoding before allocating its returned array. A set supports at most 16 provider addresses. Zero members, self-reference, duplicate providers, malformed results, oversize arrays, and unsuccessful calls are rejected. Duplicate members across valid providers are counted once. Recursive providers fail within the bounded call rather than silently disappearing from quorum.

Member lists used by governance and Besu are **approved snapshots**. An upstream provider changing its membership does not immediately change local voting rights, roots, validators, or an open ballot. A failed provider does not remove its approved members. Preview and ordinary membership-adoption actions fail if a provider they must read fails; unrelated ballots can continue with the cached electorate.

To adopt an upstream change:

1. Call `previewVoters()`, `previewValidators()`, or `previewRoots()` and review the returned addresses.
2. Have the current approved voters call the corresponding `voteToRefreshVoters(expectedHash)`, `voteToRefreshValidators(expectedHash)`, or `voteToRefreshRoots(expectedHash)`.
3. The final vote rereads the providers and requires the exact expected member hash. If upstream data changed, review the new list and start a proposal for its hash.
4. Confirm the approved query and count match the reviewed list. Track the epoch after voter changes and re-propose any invalidated work.

To replace providers or transfer authority, use the corresponding `voteToSet*Configuration(local, providers, expectedHash)`. For an outage, submit a complete replacement configuration excluding every unavailable provider; the final approval only reads providers in the replacement. This avoids the need to remove failed providers one by one. All approving voters still come from the old approved electorate.

`expectedHash = keccak256(abi.encode(sortedUniqueEffectiveAddresses))`, with Solidity type `address[]`. This is ABI encoding, not packed encoding or a JSON hash. Sort addresses by their numeric value, not display-case spelling. A configuration proposal target is `uint256(keccak256(abi.encode(local, providers, expectedHash)))`. Obtain it from `VoteCast` or compute it using types `address[]`, `address[]`, `bytes32`.

This design requires enough existing voting keys to remain available. It cannot recover a quorum whose keys are all lost. Test provider contracts against the gas allowance before registering them; supporting 64 addresses does not guarantee every provider implementation fits the read budget.

## 5. Besu validator-list compatibility

Besu calls `getValidators()` at `0x0000000000000000000000000000000000001111`. The function remains `public view override returns (address[] memory)` with standard ABI encoding; `ValidatorSmartContractInterface.sol` is unchanged. No pagination, tuple, or alternate selector is introduced.

Before the first approved validator change, the function returns the reviewed local genesis array. Afterward it returns the cached approved unique array. Provider reads occur when adopting a change, not during Besu's validator query. Local EVM tests check the raw selector and encoded result. Final validation must also confirm the pinned Besu engine reads the registry and continues producing blocks across a membership change.

Validator membership changes and cap changes require an effective count of at least four and no more than `maxValidators`; the cap itself must remain between four and 64. `voteToReplaceValidator(previous, replacement)` swaps a local entry atomically. Full configuration replacement can also transfer membership between local and provider lists. These guards prevent approving an empty or undersized list; they cannot ensure operators keep validator processes online or their signing keys available.

## 6. Proxy governance and storage

Every proxy has its own local controllers and combines them with active roots from the validator registry. Root/local overlap counts once. Root changes alter the membership fingerprint and invalidate old proposals. Existing direct-root actions and the single-session voting model remain.

Application voting uses `keccak256("cryft.governance.snapshot.v1")`; proxy voting uses `keccak256("cryft.proxy.governance.votes.v1")`. Controller enumeration uses `keccak256("cryft.proxy.governance.snapshot.v1")`. Never reuse a voting namespace across a proxy shell and its delegated application. Regression tests exercise ballots in both layers at the same address and verify independent epochs, votes, and membership.

Legacy application storage positions are retained, including reserved old tally/count/vote fields. New voting state uses namespaced storage; validator cache state is appended. Old pending ballots are not migrated. These facts do not authorize an upgrade of a populated deployment: any existing-state migration needs a separate layout and governance review. In particular, this proxy shell's newly enumerable local controllers are fresh-genesis state and do not reconstruct controllers of an older shell automatically.

## 7. Safe authority handovers

GasManager and CodeManager support `initializeWithVoter(initialVoter)` for proxy/factory initialization. Their parameterless initializer remains available when the real voter is the direct caller. Do not initialize through a factory that would accidentally become the only voter. Both reject zero, their own address, and the fixed ProxyAdmin facade as initial voters. Implementations remain initialization-locked.

For a new beacon/registry deployment:

1. Deploy compatible delegation logic, the root-created beacon, dispatcher, and registry implementation; first-link the fixed registry using reviewed initializer data.
2. The current beacon owner calls `beacon.transferOwnership(fixedRegistryAddress)`. Confirm `pendingOwner()` and that `owner()` is still the old owner.
3. The registry admin calls `acceptBeaconOwnership()` through the fixed registry entry. Confirm `beacon.owner()` equals the fixed entry and `currentSnapshot().registryControlsBeacon` is true.
4. If a pending transfer is wrong, the current owner cancels it. When the registry is the current owner, its admin calls `cancelBeaconOwnershipTransfer()`.

`transferBeaconOwnership(newOwner)` through the registry now starts a handover; the recipient must call the beacon's `acceptOwnership()`. The proposal event does not prove ownership transferred. Beacon ownership cannot be renounced.

GasSponsor uses `proposePlatformAdmin`, `acceptPlatformAdmin`, and `cancelPlatformAdminTransfer`. The registry uses `proposeAdmin`, `acceptAdmin`, and `cancelAdminTransfer`. The existing authority remains active until acceptance. Test the new multisig/contract wallet's ability to make these calls before completing a handover.

## 8. Deliberate exceptions and final deployment review

The validator's original initializer is retained at the operator's request. Its empty-local-voter guard can become true again after an external-only handover. This is an acknowledged unresolved initialization issue, not a permanent one-time guarantee. Restricted initial access must be verified, and broader access or an external-only handover requires revisiting this decision.

The existing irreversible management revocations remain deliberate. They require external membership and safe effective counts; once revoked, local/provider configuration cannot be repaired here. Refresh votes can adopt changes from the permanently selected providers, and cached lists survive a provider outage, but cannot repair lost upstream authority. Keep these revocations unused for the initial enterprise deployment unless separately reviewed.

No contract can prove an arbitrary nonzero wallet has usable keys, an operational multisig, or an appropriate signing policy. Keep tested recovery signers and enough independently available voting keys. There is no added single-key emergency bypass. Proxy guardians still have their existing operational upgrade powers; this revision does not change those powers into a timelock or require a vote for every upgrade.

Before genesis approval, record final validator/voter/root addresses, confirm each runtime profile and hash, rebuild allocations, verify Besu configuration and validator reads, complete metadata publication/read-back, and run application integration tests. Gas sponsorship economics, EIP-7702 authorization behavior, and private redemption-contract changes retain their separate review requirements.
