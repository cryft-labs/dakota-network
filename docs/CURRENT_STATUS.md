# Dakota / Kota system status and documentation index

## 1. Source promotion

Following the documentation-only publication, the owner explicitly authorized
merging implementation into main on September 11, 2026. The network, KotaRouter,
website and explorer main branches now include their reviewed source and docs.
KotaRouter includes exact Standard JSON and metadata. Review branches are retained;
resolve exact commits before deployment. No host release, DNS, tunnel, signing
permission or production traffic changes merely because source is promoted.

Historical reports retain their original audit blocks, hashes, compiler versions
and counts. This index points to the latest scope for each component instead of
rewriting earlier evidence to appear newer.

## 2. Maintenance map

| Need | Authoritative record |
| --- | --- |
| Architecture, hosts, low-privilege users, services, networking, recovery | [Implementation and operations](../IMPLEMENTATION.md) |
| Resume implementation without resetting the chain | [One-shot resume prompt, revision 8](ONE_SHOT_DEPLOYMENT.md) |
| Addresses, metadata locations and ownership scope | [Current address inventory](current-contract-addresses.json) |
| Latest read-only service/authority observation | [September 11 observation](documentation-live-check-20260911.json) |
| Genesis/governance acceptance | [Public genesis-service acceptance](live-genesis-acceptance-20260911.md) |
| Paladin operation, funding and recovery | [Paladin runbook](../Tools/Paladin/README.md) and [acceptance](paladin-acceptance-20260911.md) |
| Explorer and trace endpoints | [Explorer runbook](../Tools/Explorer/README.md) |
| Original 32,451-address source audit | [Blockscout verification](blockscout-verification-20260911.md) |
| Current Kota tenant artifacts/addresses/receipts | [Kota tenant manual](https://github.com/CryftCreator/KotaRouter/blob/main/router_v4/contracts/deployment/README.md) |
| Router, widget and direct API integration gaps | [Kota current system](https://github.com/CryftCreator/KotaRouter/blob/main/router_v4/docs/CURRENT_SYSTEM.md) |
| moment.cards branding, card types and retained site paths | [Site manual](https://github.com/CryftCreator/cryftcomingsoon-main/blob/main/docs/MOMENT_CARDS.md) |

## 3. What is running and verified

The read-only observation at block 630 confirms the expected `cryft-*` services
are active on all seven hosts: four validators, Paladin's connected Besu and
Paladin/database, Frontend archive/explorer UI, and Backend explorer/database/Redis,
Rust verifier and IPFS. Nginx runs on the application hosts. This is an active-service
check, not a new reboot, backup restore or throughput test.

The network is chain 112311 with genesis hash
`0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8`.
Besu 26.8.1/Java 25 uses Osaka and BPO1–BPO5 from genesis; Amsterdam remains disabled.
The validator stays compiled for London. Public RPC is restricted to the private
Nginx route `http://100.111.69.1:8547/`; explorer UI is
`http://100.111.69.1:8080/`. Interhost/SSH traffic uses Nebula.

Acceptance evidence is separated by scope:

- Original genesis services: 100 successful public transactions, governance and
  native EIP-7702 sponsorship checks.
- Paladin: five private redemptions delivered public card NFTs; strict rollback,
  delivery recovery, concurrent redemption and controlled service restart passed.
- Original explorer audit: 32,451 public addresses fully verified through its
  recorded block range, with explicit Apache/MIT licenses and 224 IPFS objects.
- Kota tenant release: ten additional instances fully verified, 40 successful
  transactions, 32 live checks and 43 exact IPFS objects; original permission bugs
  reproduced, fixed and upgrade-tested. IPFS sets overlap; do not sum object counts
  as unique backend pins or reuse the earlier audit count as a current census.

Kota tenant contracts use 0.8.34/Osaka and MIT. Network non-validator artifacts
use 0.8.37 with public Osaka/private Shanghai, and the validator uses 0.8.19/London.
Exact Standard JSON and deployed metadata decide the compiler and license, not
the latest compiler default or an explorer dropdown's default selection.

## 4. Authority is tracked independently

Final requested administrator: `0x9247524040D91D5dd1521A25f2e7711d4a0fe921`.
Deployment operator: `0x633309d1155fD658a717e4f5E4FA853615400867`.

| Authority | Observed status at block 630 |
| --- | --- |
| Kota access issuer, factory admin, both tenant operators, both ProxyAdmins | Final administrator controls them; temporary Kota credentials/minters removed |
| Kota shared beacon | Owned by the root-controlled factory proxy |
| Validator roots | Final administrator and deployment operator are both roots |
| Validator, GasManager and CodeManager voters | Deployment operator is still the recorded voter |
| GasSponsor admin | Deployment operator; final administrator pending acceptance; sponsorship paused |
| Delegation registry admin | Deployment operator; final administrator pending acceptance |
| Redeemable card NFT owner and its ProxyAdmin | Deployment operator; no pending owner in the read-only observation |
| Private Combo/group signing and control | Separate Paladin identities; see the private runbook; final private handover remains incomplete |

No ownership changes were made during this documentation review. Do not remove
remaining network/bootstrap controls based on the completed Kota handover. Actual
recipient signatures are still required for two-step acceptance, and private
control requires a verified private identity/group arrangement. Keep Paladin
recovery secrets on Paladin-01 under the owner's existing instruction.

## 5. Next implementation work

moment.cards reuses the existing Greeting Cards application and adds business
cards and postcards. Dakota Cards is the platform/dashboard/docs application.
The widget is optional; direct service clients must receive equivalent API functionality.

The live membership registry is
`0xA6B1dFA510B2854b8FA33ab3865535bb41CC2340`, with exact tenant ID `moment.cards`.
It is empty and unlocked. The local `/v1/platform` companion instead seeds the slug
`moment-cards` and uses database membership. Reconcile that identity, registration,
on-chain gate, signer authorization and retained widget/API lifecycle before writes.
The generic private module remains blocked; the optional worker is disabled and
has not passed a retained-widget live lifecycle test. Source in main does not
make these paths production-ready.

Remaining production work includes the Dakota UI dependency migration, Grok
credentials/model, private/public API integration, runtime minter policy, inventory,
database migrations and concurrency, load/restore acceptance, backup destination,
public Cloudflare routes, final network/SSH restrictions and the remaining authority
handover. Historical local scopes and SDK examples remain references, not proof
of those completed operational steps.


## 15 September deployment and owner activation

The reviewed implementations are now deployed, metadata is pinned, and the public sources are verified in Blockscout. Browser publishing remains paused. Follow the [exact owner activation and browser acceptance instructions](ISSUANCE_ACTIVATION.md). Earlier deployment snapshots above are historical.
