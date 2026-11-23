# Dakota native sponsorship: development release v2 route

This guide describes the current review branch. Production promotion requires
live acceptance and owner approval. The July `LIVE-DEPLOYMENT-RUNBOOK.md` records
an older deployment and must not supply this release's addresses or bytecodes.

## 1. Addresses and execution boundary

| Role | Address or source |
|---|---|
| Chain | 112311, settings from the compressed genesis |
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
EIP-7702 user EOA -> immutable dispatcher -> shared beacon -> DakotaDelegation
```

The EOA's authorization designates the dispatcher directly. Its embedded beacon
address works in the EOA's execution context without initialized proxy storage.
There is no account `proxy_linkLogicAdmin` call or EIP-1967 slot write. The fixed
registry proxy remains an upgradeable control plane; GasSponsor also remains
behind its fixed custom proxy. This removes the former per-account proxy workaround.

The immutable dispatcher exposes `delegationBeacon()` and `dispatcherProtocolId()`
(`keccak256("dakota.delegation.direct-beacon-dispatch.v2")`). Readiness validates
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
2. Deploy DakotaDelegation. Deploy its beacon from the temporary root. The beacon
   constructor checks the live validator registry. Deploy the immutable dispatcher
   using that beacon; verify both configuration getters and runtime code hash.
3. Deploy GasSponsor and registry implementations. Atomically first-link the
   sponsor with `initialize(platformAdmin, voucherSigner, dispatcher, overhead)`.
   Initialize the registry with
   `initializeWithAdmin(dispatcher, beacon, gasSponsor, registryAdmin)` through its
   reserved proxy. Use the temporary controller for setup duties that require
   subsequent signatures; record every temporary role for final handover.
4. Propose beacon ownership to the registry proxy. The registry admin calls
   `acceptBeaconOwnership()` through the registry. Verify actual `owner()` and
   registry snapshots. The beacon remains controlled until acceptance succeeds.
5. Configure the allowlisted relayer, voucher signer, sponsor tenant bindings,
   managers, hard caps and tenant caps. Sponsorship starts paused. Unpause only
   after route, signature, funding and end-to-end execution checks succeed.

Upgrade through `upgradeDelegation(implementation, expectedCodeHash)` on the
registry. It verifies the supported protocol/capabilities/interfaces, activates
the beacon and records release history atomically. Preserve each account's nonce
and namespaced storage; an upgrade must not reactivate old signed operations.

## 3. User authorization, execution and reimbursement

Submit a properly signed EIP-7702 authorization with the chain-bound authorization
nonce, designating the verified dispatcher. Read back the account code and route.
The account transaction nonce and Dakota execution nonce are different values.
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

`ProgramGasSponsor` 1.5.0 (`Releases/GasSponsor/1.5.0`, built by `Tools/GasSponsor/build_1_5_0.py`) closes every coin path into or
out of a sponsor opened by the developer gas program (`openProgramSponsor`):

| call | program sponsor | every other sponsor |
|---|---|---|
| `depositFor` | reverts `ProgramSponsorGasOnly` (from anyone) | unchanged: refundable deposit |
| `withdrawSponsor` | reverts `ProgramSponsorNoWithdraw` | unchanged: the manager withdraws the refundable part |
| `depositGasCredit` | only from the program (`NotProgram`) | unchanged: anyone |
| `recoverGasCredit` | the platform admin or the program, to the program only (`ProgramSponsorRecoverToProgram`) | unchanged: the platform admin, any address |

Spending is unchanged: a program sponsor is spent from only while the program answers eligible (its developer's Pass active, the
program not paused), so a revoked Pass stops spending at the very next execution. No storage is added; `layout-proof.json` proves
the layout append-only against both live predecessors (1.3.0 at `0x…FEeD`, 1.4.0 behind the dev test sponsor). Runtime 28,547 bytes
(Dakota's limit 32,768).

## GasSponsor 1.5.1: a program sponsor's credit is recovered by the program alone (2026-11-23)

`ProgramGasSponsor` 1.5.1 (`Releases/GasSponsor/1.5.1`, built by `Tools/GasSponsor/build_1_5_1.py`; the independent review's P2-D)
changes one row of the table above: `recoverGasCredit` for a program sponsor is the **program's alone** (`NotProgram` for anyone
else, the platform administrator included), still only to the program (`ProgramSponsorRecoverToProgram`). The program's own rules
(DeveloperGasProgram 1.2.0: the 90-day freeze before an ordinary reclaim, an abuse reclaim of a frozen Pass, a paid top-up's refund
by receipt) are the only way credit leaves a developer's account. Every other sponsor is unchanged. No storage is added;
`layout-proof.json` proves the layout append-only against 1.3.0 (`0x…FEeD`), 1.4.0 and 1.5.0 (the dev test sponsor since PB-2).
Runtime 28,498 bytes (margin 4,270 to Dakota's 32,768).
