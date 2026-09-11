# Live genesis acceptance — September 11, 2026

## 1. Outcome and scope

GasManager, CodeManager, GasSponsor and DakotaDelegationRegistry are linked and
initialized on Dakota development chain **112311**. The validator registry and
ProxyAdmin match their reviewed genesis runtimes. **100 transaction
receipts and 172 recorded checks passed.** The final read-only
receipt/authority verification observed block 209 at 2026-09-11T05:23:48.153922+00:00.
No contract source or genesis bytecode changed during this initialization.

This is public development-chain acceptance, not production or full application
acceptance. Face has no approved implementation and stays unlinked. Other unused
genesis proxy slots remain reserved. Libraries/interfaces are not standalone services.

## 2. Deployed addresses

| Contract | Operational address | Implementation or purpose |
| --- | --- | --- |
| ValidatorSmartContractAllowList | `0x0000000000000000000000000000000000001111` | Genesis runtime retained |
| ProxyAdmin | `0x0000000000000000000000000000000000FacAdE` | Genesis runtime retained |
| GasManager | `0x000000000000000000000000000000000000cafE` | 0x2537E8005d9f5f3eC0e843A878fb53F658FA00f3 |
| CodeManager | `0x000000000000000000000000000000000000c0DE` | 0x31d95306D43E75ED1D38cAf44F4cDf6d01537bB9 |
| GasSponsor | `0x000000000000000000000000000000000000FEeD` | 0x31A4ea654E4C0BFd6eFD5286decC72C2CA1cdb3E |
| DakotaDelegationRegistry | `0x00000000000000000000000000000000de1E6A7E` | 0x56ff7f6A7b2e37f6C619910ABa775B8De3D06aB8 |
| ReservedAgentRegistry | `0x000000000000000000000000000000000000Face` | Unlinked reservation; implementation unavailable |
| DakotaDelegation | `0x6F7d7571f7B861C6124E3ff2A2C76C013701bbca` | Standalone deployment |
| DakotaDelegationBeacon | `0xb15883C65f85cbc6C6d0157B31AE2089f4acc8C2` | Standalone deployment |
| DakotaDelegationBeaconDispatcher | `0x5191D200046a732754DFC9126e5F5A43CD45de67` | Standalone deployment |
| GenesisCanary | `0x3C85c5777aB858a7e31F80e38FD6BBdB34b997D2` | Development fixture only |
| DakotaDelegationUpgradeCanary | `0xA198Ae8890FD7Dc008f7A9F5d64CAe315F56AB6E` | Development fixture only |

The upgrade canary uses the exact reviewed DakotaDelegation code; the shared beacon
was upgraded to it and restored to the original implementation. Registry release
history has three entries. The active account route remains EOA -> direct dispatcher
-> beacon -> DakotaDelegation; no per-account transparent-proxy initialization.

## 3. Functional evidence

- All three independent voter pools completed two-voter proposals, blocked duplicate
  votes and empty electorates, and returned to the original sole bootstrap voter.
  Duplicate configuration addresses normalize to one effective voter. Approved
  validator snapshots canonicalize ordering while retaining the existing address[]
  ABI and exactly the four supplied validator identities.
- Each service proxy rejected unauthorized upgrades, retained root authority,
  separated local-controller and operational-guardian roles, and preserved application
  state across an authorized same-implementation facade upgrade.
- GasManager V1/V2 recipient binding, replay prevention, guardian permissions,
  restricted sponsor funding and burn paths passed. The suite transferred 0.000003
  KOTA to the test EOA, burned one dummy token unit and one native wei.
- CodeManager registered three canonical UIDs, enforced registrar payment/authority,
  restricted the test group to its canary gift, rejected inactive/replayed redemption,
  and retried a deliberately failed delivery to the original committed recipient.
- A real EIP-7702 type-4 transaction installed the direct dispatcher designation.
  EIP-1271 signatures and registry/sponsor readiness passed. A sponsored two-call
  batch updated the canary and redeemed the third UID through CodeManager.
- The successful operation reimbursed 501626000000000 wei from restricted gas credit,
  leaving the refundable deposit untouched. Invalid relayer, voucher, changed
  payload and replay checks passed. A deliberately invalid account-owner signature
  produced success=false without advancing the account nonce or delivering an asset.
  Its accepted voucher was consumed/reimbursed under the documented policy.
- Equivalent-code beacon upgrade/restoration preserved account nonce and readiness.
  Two-step admin nominations retained the current controller, rejected acceptance
  by another account and could be canceled safely.

[Watch the successful sponsored redemption](http://100.111.69.1:8080/tx/0x736a0ca20599061dcf1b7c89a0b3b1cf896d5e1ca75710ccce5639482128fdb6).
Archive TRACE and Blockscout both expose its nested calls. Registration traces
confirm the exact registration fee reached GasManager. All submitted outer receipts
succeeded; the deliberate inner failure is recorded separately by its event.
Total gas used was 35,906,284, with transaction fees of
0.035906284 KOTA across both project accounts.

## 4. Exact metadata publication

The final IPFS audit at 2026-09-11T05:24:20.135909+00:00 checked **16 deployed
runtimes and 53 unique metadata/source/bundle objects**. Each live
Solidity CBOR trailer matched its compiler metadata CID. Exact bytes, source
keccak256 hashes, recursive pins, API readback and private-gateway readback passed
on Backend-01. The core bundle still contains 90 compiler artifacts and is
`QmSuawtJhsHhAJNS2VtPx4UHTEPvQgDbJD7vKmkV7smMaf`. These are dependency/artifact counts, not active
service counts. The canary metadata/source were published separately.

The API/gateway were accessed over pinned-host-key SSH/Nebula to Backend loopback
ports 5001/8081. Public Cloudflare gateway, secondary off-host pins and explorer
source-verifier acceptance remain pending. Matching code and hosted metadata do
not mean Blockscout currently labels the contract source verified.

## 5. Cleanup and ownership

Temporary validation voters, proxy local controllers, the canary privacy-group
grant, treasury guardian and relayer are removed. The canary tenant is disabled,
sponsorship is paused and its ledger is zero. The 0.001 KOTA refundable deposit
was returned to its payer; unused restricted credit returned to GasManager.
The test EOA remains delegated for later application testing and holds no platform
or governance management role. No transaction is pending on either project account.

The supplied admin `0x9247524040D91D5dd1521A25f2e7711d4a0fe921` remains a root and
is now pending administrator for GasSponsor and the delegation registry. Acceptance
has **not** been signed. The deployment account remains bootstrap voter in the
validator/GasManager/CodeManager pools, root, platform/registry admin and voucher
signer for authorized application setup. Final handover must prove the recipient's
control, rotate service/signing roles and atomically replace the remaining voters
and roots. Do not remove the working controller before that process completes.

## 6. Remaining work and known boundaries

The validator retains its owner-requested initializer guard based on an empty local
voter array. This is not a permanent one-time initialization flag. Keep the current
local-voter model; revisit this acknowledged issue before any external-only handover.
No irreversible governance-management revocation was exercised.

Pending: approved agent-registry source; private Paladin EIP-7702/runtime acceptance;
production gift/account-registration contracts; Kota Router registration and full
redeemable lifecycle integration; widget and moment.cards deployment; load,
reboot/restore and off-host backups; final access hardening and owner handover.
Public sponsorship success does not establish private Paladin support.

## 7. Reproduction and takeover

Read [the operator runbook](../Tools/LiveGenesis/README.md) and
[the copy-ready observer/handoff prompt](../Tools/LiveGenesis/FOLLOW_AND_HANDOFF_PROMPT.md).
Do not run two signers concurrently. Reconcile signed hashes and nonces before
continuing a partial stage; never delete the journal to retry initialization.
Some checks describe historical intermediate states and are not final-state flags.

Evidence: [public journal](live-genesis-journal-20260911.json),
[final chain verification](live-genesis-chain-verification-20260911.json),
[IPFS verification](live-genesis-ipfs-verification-20260911.json), and
[address manifest](live-genesis-addresses-20260911.json).
Each transaction records the pushed review commit used for signing. Main is preserved.
