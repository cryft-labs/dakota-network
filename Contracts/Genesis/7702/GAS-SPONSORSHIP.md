# Cryft native sponsorship: development release v2 route

This guide describes GasSponsor 1.5.2 and the delegation contracts on the Cryft Network (chain 113211).
Addresses of the implementations come from the link journal (`Tools/Genesis/link.py`); nothing from the
previous chain applies.

## 1. Addresses and execution boundary

| Role | Address or source |
|---|---|
| Chain | 113211, settings from the compressed genesis |
| Validator/root registry | `0x0000000000000000000000000000000000001111` |
| GasManager | `0x000000000000000000000000000000000000cafE` |
| CodeManager | `0x000000000000000000000000000000000000c0DE` |
| ProxyAdmin | `0x0000000000000000000000000000000000FacAdE` |
| Delegation registry proxy | `0x00000000000000000000000000000000de1E6A7E` |
| GasSponsor proxy | `0x000000000000000000000000000000000000FEeD` |
| Final management root | `0x9247524040D91D5dd1521A25f2e7711d4a0fe921` |
| Temporary deployment root/voter | `0x633309d1155fD658a717e4f5E4FA853615400867` |
| Delegation test account | `0x991acc255761dEE0421Ccd3F436788C24425122E` |
| Dispatcher, beacon, implementation | Resolve actual deployment receipts; never infer addresses |

Account execution follows:

```text
EIP-7702 user EOA -> immutable dispatcher -> shared beacon -> CryftDelegation
```

The EOA's authorization designates the dispatcher directly. Its embedded beacon
address works in the EOA's execution context without initialized proxy storage.
There is no account `proxy_linkLogicAdmin` call or EIP-1967 slot write. The fixed
registry proxy remains an upgradeable control plane; GasSponsor also remains
behind its fixed custom proxy. This removes the former per-account proxy workaround.

The immutable dispatcher exposes `delegationBeacon()` and `dispatcherProtocolId()`
(`keccak256("cryft.delegation.direct-beacon-dispatch.v2")`). Readiness validates
the 23-byte `ef0100 || dispatcher` designator, deployed dispatcher code hash,
beacon binding and account protocol. A call to an account without code can succeed
without executing anything, so transaction success alone is insufficient evidence.
The legacy `proxyInitialized` field in registry status means immutable-route
validity in this revision. Clients must use the new ABI and interpretation.

## 2. Build and first deployment

Use Solidity 0.8.37, Osaka, optimizer 200 for public contracts; only the validator
stays 0.8.19/London. Archive the self-contained standard JSON, ABI, exact metadata,
compiler hash and source commit. Deployment addresses and constructor immutables
must be included in verification records. Runtime templates containing immutables
are not byte-for-byte deployed runtime until those values are resolved.

1. Confirm the live chain ID and genesis checksum. Inspect reserved proxies:
   initialization false, implementation zero, correct facade and expected roots.
   If any differs, inspect the existing deployment; do not relink or reset it.
2. Deploy CryftDelegation. Deploy its beacon from the temporary root. The beacon
   constructor checks the live validator registry. Deploy the immutable dispatcher
   using that beacon; verify both configuration getters and runtime code hash.
3. Deploy GasSponsor and registry implementations. Atomically first-link the
   sponsor with `initialize(platformAdmin, voucherSigner, dispatcher, overhead)`.
   Link the registry with
   `initializeWithAdmin(dispatcher, beacon, gasSponsor, registryAdmin, upgradeDelay)` through its
   reserved proxy. `Tools/Genesis/link.py` does steps 1-3 and checks every result.
4. The beacon is owned by the registry entry 0x…de1E6A7E from construction: there is no ownership
   handover. Verify `beacon.owner()` and the registry snapshot.
5. Configure the allowlisted relayer, voucher signer, sponsor tenant bindings,
   managers, hard caps and tenant caps, each sponsor's operations per day (1.5.2:
   zero runs none) and the pauser. Seed the program deny list before `setProgram`
   (1.5.2 reverts otherwise). Sponsorship starts paused. Unpause only
   after route, signature, funding and end-to-end execution checks succeed.

Upgrade in two phases on the registry: `scheduleDelegationUpgrade(implementation, expectedCodeHash)`
(public event), then `executeDelegationUpgrade` once `upgradeDelay` has passed; the admin or any
proxy guardian can `cancelDelegationUpgrade`. Execution re-verifies the protocol, capabilities and
interfaces, activates the beacon and records release history atomically. Preserve each account's nonce
and namespaced storage; an upgrade must not reactivate old signed operations.

## 3. User authorization, execution and reimbursement

Submit a properly signed EIP-7702 authorization with the chain-bound authorization
nonce, designating the verified dispatcher. Read back the account code and route.
The account transaction nonce and Cryft execution nonce are different values.
Sign the account's EIP-712 execution envelope with its executor, operation ID,
nonce, expiry, calls and execution gas limit. The sponsor voucher separately binds
tenant, campaign, sponsor, account, relayer, delegate, execution hash, maximum gas,
gas price, cost and deadline. Use contract digest helpers and the published ABI.

The relayer needs native balance to submit the transaction. Sponsorship reimburses
it; it does not make a zero-balance relayer able to pay the outer transaction fee.
Failed inner calls consume the voucher operation and may reimburse the relayer.
Distinguish outer receipt success, sponsored execution success and application
settlement. Do not report redeemed merely because the relay transaction was mined.

Query `minimumCallGas(executionGasLimit, executionCalldataBytes)` before signing.
The formula accounts for dispatch/EIP-150 and post-execution work. Execution budget
is at most 5,000,000; calldata at most 65,536 bytes. The sponsor's outer call ceiling
means the largest usable inner budget is lower than 5,000,000. Bound outer intrinsic
gas as well. Per-call return data is capped at 4,096 bytes and aggregate account
return data at 16,384 bytes. Measure actual costs before setting overhead/caps.

## 4. Funding policies

`depositFor(sponsor)` creates tenant-refundable funds. The sponsor manager can
withdraw only the refundable portion. `depositGasCredit(sponsor)` creates gas-only
credit. GasManager's governed sponsorship funding uses this restricted path.
Credit is consumed first; `getSponsorFunding` returns both components. The platform
admin alone may `recoverGasCredit` to an explicit valid recipient. Record recoveries
in the operator audit log. Depositing on behalf of a tenant is a transfer into that
tenant's policy, not a refundable claim owned by the depositor.

Keep campaign/day/operation limits and balance alerts. Pausing sponsorship preserves
admin recovery methods. Tenant limits cannot exceed the platform hard limits.
Do not recycle operation IDs after failure or timeout; reconcile persisted records
and chain receipts before retrying uncertain submissions.

## 5. Private-state gas delegation

September 11 live checkpoint: native EIP-7702 sponsored public settlement of a real
prepared Pente redemption passed. The relayer was reimbursed and the recipient paid
no public gas. Private computation used Shanghai and no native balance. Ordinary
private proxy DELEGATECALL passed; private authorization-list processing is not
established. MetaTx remains disabled. See the [acceptance evidence](../../../docs/paladin-acceptance-20260911.md)
and [funding/maintenance runbook](../../../Tools/Paladin/README.md). Existing public
and private proxies now use strict settlement to preserve private codes on rejected
public preconditions. The remaining guidance describes requirements for any future
private-interpreter upgrade, not unfinished work needed for this proven gas route.

The owner requests live testing against the newest pinned Paladin release before
choosing a fallback. Test private EIP-7702 authorization processing, account code
read-back and actual execution. Separately test private DELEGATECALL and Paladin's
prepared transition approval/delegated public settlement. These are different
mechanisms and require separate evidence. A public sponsor may pay settlement gas
without proving the private VM processes EIP-7702 authorization lists.

Paladin v1.0.0 source selects London/Paris/Shanghai; use Shanghai for the compatibility
control and test a newer target explicitly before promoting it. Record the actual
container digest and image commit, since the image label differs from the source
tag commit. Keep `PrivateMetaTxRelay` and trusted forwarder disabled until real
results establish a need. Its retained v1 source requires further hardening before use.

## 6. Handover and acceptance

Propose and accept the registry/platform/private-admin/card-owner roles. Verify a
real authorized call from the recipient before removing old rights. The registry
normally owns the beacon. Root governance may later move to an approved multisig
that can execute the required calls. Membership voting and owner acceptance are
separate operations; possessing a public address does not let the deployer sign
the final owner's acceptance.

Inventory voter/root sets, proxy-local overlords/guardians, voucher signer,
relayer allowlists, sponsor managers, private service/UID managers, card owners and
Kota issuer/minter/recovery roles. Remove bootstrap authority only after replacement
controllers and recovery paths are proven. Some explicit governance revocations are
irreversible; they are not routine handover actions. The existing initialization
exception is retained only for the owner-approved, closed bootstrap network.

## GasSponsor 1.5.0: program sponsors hold gas credit only (2026-11-23)

`ProgramGasSponsor` 1.5.0 closes every coin path into or
out of a sponsor opened by the developer gas program (`openProgramSponsor`):

| call | program sponsor | every other sponsor |
|---|---|---|
| `depositFor` | reverts `ProgramSponsorGasOnly` (from anyone) | unchanged: refundable deposit |
| `withdrawSponsor` | reverts `ProgramSponsorNoWithdraw` | unchanged: the manager withdraws the refundable part |
| `depositGasCredit` | only from the program (`NotProgram`) | unchanged: anyone |
| `recoverGasCredit` | the platform admin or the program, to the program only (`ProgramSponsorRecoverToProgram`) | unchanged: the platform admin, any address |

Spending is unchanged: a program sponsor is spent from only while the program answers eligible (its developer's Pass active, the
program not paused), so a revoked Pass stops spending at the very next execution. No storage is added.

## GasSponsor 1.5.1: a program sponsor's credit is recovered by the program alone (2026-11-23)

`ProgramGasSponsor` 1.5.1 (the independent review's P2-D)
changes one row of the table above: `recoverGasCredit` for a program sponsor is the **program's alone** (`NotProgram` for anyone
else, the platform administrator included), still only to the program (`ProgramSponsorRecoverToProgram`). The program's own rules
(DeveloperGasProgram 1.2.0: the 90-day freeze before an ordinary reclaim, an abuse reclaim of a frozen Pass, a paid top-up's refund
by receipt) are the only way credit leaves a developer's account. Every other sponsor is unchanged. No storage is added;
**Correction (2026-11-25 audit, X-18):** in 1.5.1 this claim did not hold: `setProgram` was the platform administrator's at any
time, so `setProgram(attacker)` followed by `recoverGasCredit` took every program sponsor's credit, and `configureSponsor` /
`setSponsorManager` could reconfigure a program sponsor. 1.5.2 (below) closes all three. Likewise "governed by the program deny
list" (C3 below) failed open on a fresh genesis, where `programDenied` is empty (X-20).
Two more from the safe-coding review of the live contracts (Chad: "fix all of them"):

- **C3, call approvals on chain again.** `ProgramGasSponsor` now inherits `ApprovedGasSponsor` (GasSponsor 1.2's mandatory
  target/selector approvals: code hash, implementation, max value, CodeManager). Every sponsored execution of a sponsor that is
  NOT a developer program's must call only approved (target, selector, value), else `CallNotApproved` (nothing charged). A
  developer program's sponsor is exempt: its calls are governed by the program deny list, its manager's targets and the
  router's lists. Only the platform administrator sets approvals (`setCallApprovals`, 1 to 64 at a time; a zero code hash
  revokes); `initializeCallApprovals` is removed (the 32 KB budget). Storage: ApprovedGasSponsor's own namespace,
  `keccak256("cryft.storage.ApprovedGasSponsor.v1")`, apart from the other three namespaces and the plain slots.
- **C4, stuck worker reservations.** `releaseWorker(id)`: the platform administrator at any time, or ANYONE once
  `RESERVATION_RELEASE_AFTER` (7 days) has passed since the reservation, settles it at its maximum (the bound the tenant agreed
  to), pays the treasury captured at reservation (or defers its revenue), and emits `WorkerReleased(id, sponsor, by, cost,
  policySettled)`. Idempotent: an operation already settled, released or never reserved changes nothing and returns 0. The
  policy's `settle` is asked with 200,000 gas and a refusal does not keep the reservation stuck.

## GasSponsor 1.5.2: the contract audit's P-1, for the fresh chain (2026-11-25)

`ProgramGasSponsor` 1.5.2 (`Tools/GasSponsor/build_1_5_2.py`; release files under `Releases/GasSponsor/1.5.2` once written with
`--write`) is what genesis links at `0x…FEeD` on chain 113211, the first release there. The tool records the storage layout
(every namespaced struct and the plain slots, the namespaces apart) that later upgrades must stay append-only against. One version string, `1.5.2`, for every layer. Runtime 32,491 bytes (margin
277 to Cryft's 32,768).

| finding | 1.5.2 |
|---|---|
| X-9 | A `pauser` (`setPauser`, the platform administrator's; zero removes it) may `setPaused(true)` and `setSponsorAdminEnabled(sponsor, false)`, nothing else: it moves no coin and changes no role. Resuming stays the administrator's. The administrator may be a contract (a timelock). |
| X-18 | `openedBy[sponsor]` records the program that opened each program sponsor; only it funds the sponsor (`depositGasCredit`), sets its caps (`setProgramSponsorCaps`), recovers its credit (to itself) and answers its eligibility. `setProgram` is **one-time** for the address (later calls may only re-set the same program's hard caps): the program is a proxy at a stable address and never needs to move, and a one-time set is smaller and stronger than tracking whether any program sponsor still holds credit. |
| X-20 | `setProgram` reverts until the deny list holds at least one entry (`deniedCount`; the release tool seeds the platform's own non-genesis contracts first). Every address below 2^32 (the genesis system contracts 0x…1111, cafE, c0DE, FacAdE, FEeD, de1E6A7E and the precompiles) is denied to program credit in code, seeded or not. The release tool still adds each new platform contract in the same step that deploys it. |
| X-60 | `configureSponsor`, `setSponsorManager` and `setSponsorOpsPerDay` revert `ProgramSponsorAdminLocked` for a program sponsor; the program's hard caps clamp its caps at every spend (and in `getSponsorAccount`), so a lowered hard cap binds every open program sponsor at once. |
| X-19 | Every sponsor has an operations-per-day counter (vouchers and worker reservations; `setSponsorOpsPerDay`, `sponsorOps`): zero, the default, runs none. A program sponsor's limit is its tier's, on the same counter (`ProgramDailyOpsReached` is now `DailyOpsReached(address,uint256)`). A new sponsor requires approved wallets until its manager opts out; a program sponsor always does. Per-wallet limits keyed on a card, Pass or account remain the allowance policy's job. |
| X-57 | `releaseWorker` after the 7 days by anyone charges **nothing** (the platform administrator's release still charges the maximum); the policy's settle is given its full 200,000 gas or the call reverts. `redirectWorkerRevenue(from, to)` (administrator) moves a treasury's deferred revenue to a claimant when that treasury can neither take coin nor claim. |
| X-58 | Consumed operation ids are per sponsor (`isOperationConsumed(sponsor, id)`), so a worker of one sponsor cannot burn another's voucher ids. Worker reservation ids remain one book among the platform's workers. |
| X-59 | The policy's `settle` runs with 120,000 gas, inside the 150,000 charged as overhead, and best-effort (`AllowancePolicySettleFailed(operationId, policy)` on failure), so a policy can neither underpay nor sink the relayer. The execution gas reserve is checked after the calldata copy. |
| X-66 | An approval with no implementation (an immutable target) is refused when the target's code pushes the EIP-1967 implementation or beacon slot (OZ transparent, ERC1967, UUPS and beacon proxies): EVM code cannot read another contract's storage, so the code is scanned. The release tool should still read the slots with `eth_getStorageAt`. |

Size work: the access checks are functions rather than inlined modifiers, coin transfers share one helper, the execution envelope's
calls are decoded once, revert strings became custom errors, and the V2 allowance policy's `reserveCalls` now receives the whole
validated execution envelope (`bytes executionData`) instead of target and selector arrays (no V2 policy existed).
