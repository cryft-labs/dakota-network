# Kota / Dakota implementation and operations manual

## 1. Purpose and current status

Kota is the API service for issuing, managing and redeeming codes/tokens. The widget
is an optional client; sites/apps may call the documented endpoints directly.
moment.cards is the initial consumer for greeting cards, business cards and postcards. Dakota's
Besu public ledger and Paladin privacy state supply the underlying settlement.

This manual describes the development release under review. Source changes and
local checks do not establish a deployed service. Record each completed installation
in the deployment inventory with its exact commit, image digest, genesis checksum,
service unit, addresses, ports and health evidence. The explorer is verified at
`http://100.111.69.1:8080` from the administrator's computer over Nebula.
After the documentation update, the owner explicitly authorized merging the
remaining implementation into main. Reviewed KotaRouter, website and explorer
source is now published there. Production deployment remains a separate gate.

## 2. Source and release ownership

Use `cryft-labs/dakota-network/main` for current network source and documentation.
KotaRouter main now contains the reviewed implementation and exact artifacts.
Review branches are retained for provenance. Resolve
and record exact SHAs before building; main is not an automatic deployment instruction.
Website implementation is merged into `CryftCreator/cryftcomingsoon-main/main`,
with `review/moment-dakota-tenant` retained. Known build/integration gaps remain.
The existing `Greeting Cards/` application becomes moment.cards in place,
including greeting cards, business cards and postcards. `Dakota Cards/` is the
platform portal/dashboard/docs application. The widget is optional; direct
service endpoints must offer the same authorization and lifecycle semantics.
Never deploy a moving branch with an unchecked reset/pull. Preserve historical
release receipts and back up existing host configuration/data before replacement.

The owner has authorized compatible hardening, review-branch publication and
development deployment/testing. Ask only for genuinely missing access/configuration
or a material change outside that scope. Do not request the same approval again.
See [the complete deployment prompt](docs/ONE_SHOT_DEPLOYMENT.md).

## 3. Host inventory

| Host | Bootstrap public IP | Nebula IP | Role |
|---|---|---|---|
| Validator-01 | 137.184.70.9 | 100.111.32.101 | QBFT validator |
| Validator-02 | 134.209.124.114 | 100.111.32.102 | QBFT validator |
| Validator-03 | 157.230.0.98 | 100.111.32.103 | QBFT validator |
| Validator-04 | 142.93.0.157 | 100.111.32.104 | QBFT validator |
| Paladin-01 | 146.190.75.149 | 100.111.32.201 | Paladin, private storage, connected Besu |
| Backend-01 | 206.81.13.59 | 100.111.67.1 | Kota API, Blockscout backend, databases, IPFS |
| Frontend-01 | 147.182.191.138 | 100.111.69.1 | Main archival RPC, sites/widget, explorer frontend |

The administration computer is 100.111.1.4. Backend/Frontend have 32 GB RAM,
8 shared vCPU and 400 GB SSD; validators/Paladin have 16 GB RAM, 8 shared vCPU and
320 GB SSD. These are capacity inputs, not throughput guarantees. All hosts use
Ubuntu 26.04 LTS; Backend/Frontend were upgraded to 26.04.1 and reboot-checked.

## 4. Network bootstrap and access

Use the existing cryft-admin identity and pinned host keys for bootstrap SSH.
Defined Networking enrollment keys belong only in protected temporary input files,
never Git, command logs or this manual. Enroll once and verify assigned IP/certificate.
Use separate administrator and runtime users. Test a fresh operator SSH connection
over Nebula before closing public SSH or disabling root login. Retain provider-console
recovery. Nebula requires its configured underlay UDP path; do not block that path
while attempting to remove public application exposure.

For an owner-requested address or enrollment replacement, use the committed
`Tools/Deployment/enroll-nebula.py` with protected SSH-stdin JSON and
`replace_existing: true`. Use the pinned bootstrap/recovery connection during the
transition; the old tunnel can stop working as soon as its certificate is replaced.
The default preserves existing enrollment. Replacement enrolls in place and
restarts `dnclient` after success, without deleting identity files. This follows
[Defined's server migration procedure](https://docs.defined.net/guides/migrating-between-networks/).
Verify the actual assigned address, enabled/active service, and a fresh private SSH
connection; update inventory if the assigned address differs. A successful code
submission alone does not prove tunnel reachability.

All validator/P2P, internal RPC and inter-host application traffic uses Nebula with
role-specific firewall rules. Application HTTP origins bind 127.0.0.1. Cloudflare
Tunnel reaches local Nginx for public websites; sensitive admin routes require
Nebula or authenticated Access. Do not publish raw validator, database, Paladin
admin, IPFS administration or unrestricted JSON-RPC ports to the public Internet.

Development exception recorded 2026-09-11: the owner temporarily broadened the
Defined Networking firewall rules to allow node communication during testing.
Retain this owner-selected development policy until the production network review;
record the final role/port matrix before production approval. Nginx and application
access controls still apply independently. All seven assigned Nebula addresses in
the inventory have passed fresh private SSH checks. Frontend-01 was re-enrolled to
100.111.69.1; its temporary 100.111.69.101 assignment is superseded.

Archive ingress is Nginx at `http://100.111.69.1:8547/` and
`ws://100.111.69.1:8547/ws`. Its upstream Besu HTTP/WS listeners are
`127.0.0.1:8545` and `127.0.0.1:8546`; raw origin ports are not remote entry points.
The private proxy has explicit source permissions, rate/connection limits and
timeouts, and runs with an unprivileged master and workers. P2P uses the separate
Besu protocol on Nebula TCP 30303. Cloudflare must not target private archive RPC.

## 5. Runtime users, files and services

Create separate non-login users for Besu, Paladin, Kota, Blockscout, IPFS and web
services. Keep release code/configuration root-owned and read-only to runtimes;
grant write access only to each service's data/log paths. Recommended layout:
`/opt/cryft/releases/<commit>`, `/etc/cryft/<service>`, `/var/lib/cryft/<service>`.
Secrets must be mode 0600 or systemd credentials, never world-readable environment files.

Install persistent systemd units with explicit User/Group, WorkingDirectory,
ExecStart, restart/backoff, resource limits and required network/storage dependencies.
Enable units only after configuration validation. Containers also require pinned
digests, nonroot runtime identity, writable-data mounts and supervised persistence.
Paladin and its PostgreSQL database now run persistently as `cryft-paladin` with
rootless Podman. See chapter 8 and `Tools/Paladin/README.md` for exact units, paths
and budgets. The isolated `Tools/RuntimeReview` harness remains disabled and must
not conflict with the deployed services.

Nginx listens on unprivileged ports as its own runtime user. Validate syntax before
reload. Configure request-body limits, per-IP/per-principal rates, connection caps,
timeouts, websocket forwarding and bounded retries appropriate to each service.
Never automatically retry a value-changing POST. Accept proxy identity headers only
from authenticated/trusted ingress and overwrite spoofable forwarding headers.

## 6. Genesis and validators

### Development checkpoint: 2026-09-11

Four validators, the Paladin-connected Besu and Frontend archive Besu are running
as `cryft-besu` under enabled systemd units. All six synchronized at block 43
after the compatible BPO5 rollout; all seven hosts have the same verified genesis
file. Runtime installation records describe the original binary installation;
`/etc/cryft/besu/genesis-installation.json` and `milestone-update.json` describe
the subsequent genesis update. This distinguishes binary version from current
chain configuration without rewriting historical installation evidence.

Frontend's Nginx-protected archive is reachable from Backend over Nebula at
`http://100.111.69.1:8547/`, with WebSocket at `/ws`; the raw origins remain on
loopback. Backend's persistent `cryft-ipfs` service has published 90 contract
artifacts as 164 verified IPFS objects. The release bundle is
`QmSuawtJhsHhAJNS2VtPx4UHTEPvQgDbJD7vKmkV7smMaf`. Pins and readback are verified
on Backend; public gateway access and offhost pin redundancy are not yet configured.

The explorer UI on Frontend-01 and API/indexer/database on Backend-01 are running
as persistent rootless services behind the unprivileged Nginx proxies. The browser
home page and block 72 detail were verified; the API subsequently matched Besu at
block 76 and reported indexing complete. Same-origin RPC, validator list, WebSocket
subscription, runtime KOTA branding, closed raw origins and a controlled API restart
were verified. See [explorer acceptance](docs/explorer-nebula-acceptance.json) and
[the runbook](Tools/Explorer/README.md). All genesis contract address/code records
are indexed and the original 32,451-address public audit passed; the later Kota
release added ten fully verified instances. This
does not reimport genesis balance history. Wallet-write/account UI configuration
remains pending. See [the independent verification report](docs/blockscout-verification-20260911.md).

Paladin/Pente deployment and direct private-code-to-public-NFT acceptance are
complete for the development group. Five NFTs were delivered, native public gas
sponsorship passed and database/Paladin restart preserved state. Kota application
deployment and Router adapter integration are still pending.
Full reboot/restore/load acceptance, public SSH/root-login lockdown and
Cloudflare tunnels are not completed. Kota tenant ownership is handed over;
core network/card/private-state ownership handover is not completed. The owner has
temporarily broadened Defined Networking rules for development; production must
replace that policy with tested role-specific access. Enabled services and these
network checks do not constitute production approval.

### Authoritative genesis and compatible updates

The existing archive defines chain ID 112311, 64,000,000 block gas, 32,768-byte
contract limit, the fork schedule, QBFT timing and system addresses. Preserve it.
The reviewed archive enables BPO1–BPO5 at timestamp 0 with Osaka execution rules.
It preserves the inherited blob target/max of 6/9; no new blob capacity is implied.
Amsterdam is unfinalized in Besu 26.8.1 and remains disabled. See the existing
README's milestone review for pinned source evidence and compatibility limits.
Beyond these reviewed changes, preserve the schedule and record any proposed diff.
Public builds use Solidity 0.8.37/Osaka; the validator stays 0.8.19/London with the
same `getValidators()` ABI encoding. Besu is pinned to 26.8.1, requiring Java 25.

Keep only `Contracts/Genesis/besuGenesis.7z` and its checksums in Git. The archive
contains exactly `BesuGenesis.json`. After pulling the pinned release, verify the
archive checksum, extract to a staging directory on **every Besu node**, verify
the extracted JSON checksum, then atomically install the same file at the configured
`--genesis-file` path. Include validators, the archive/RPC node, and Paladin-connected
Besu nodes. Never start nodes with different genesis hashes or upload the 1.2 GB
uncompressed JSON to Git. Do not reset an existing chain database automatically.

The specific BPO2-to-BPO5 transition is covered by the deployment helper's
`--allow-compatible-bpo-update` option. It requires the exact previous genesis
hash and a stopped local Besu service, and verifies that removing only the three
new fields reconstructs the old file byte for byte. It retains the old genesis
as a hash-named backup and never changes keys or chain data. Restart/check the
archive first, then Paladin's Besu, then one validator at a time while the other
three remain healthy. Verify `[BPO5:0]`, the same genesis block hash, validator
list, peers, synchronization and continued block production. This exception is
not a general permission to change a live chain's past execution rules.

| Validator | Public address |
|---|---|
| 01 | `0xCdC8d72552dC91EC70b381Cc5b869ad64cEf8451` |
| 02 | `0x4E84562aCD2A3846C6dA115F00127EBf8279457d` |
| 03 | `0xCaBE4444b7d2f7A859dC0a9e9963a0dD0d6D8400` |
| 04 | `0xAFd389303A515D57dc2A97f46908c0E9DDdfa33C` |

Use the already generated protected node keys; do not regenerate identities. Read
back the validator list and compare its ABI result on the actual Besu network.
The management account receives 32 native tokens and each of the two development
accounts receives 1. The deployment account is a temporary root/sole bootstrap
voter; the supplied management root remains recognized. Handover must remove the
temporary rights after replacement control succeeds. See `development-release.json`.

### Fee policy (applied 2026-09-12)

Inclusion floor: every Besu node keeps `min-gas-price=1000000000` (1 gwei effective gas
price). Validators keep `min-priority-fee` at its default of 0; setting a tip floor there
would reject transactions priced at exactly 1 gwei, which is how MetaMask's network
suggestion and Paladin's fixed-price settlements are built, because the EIP-1559 base fee
rests at 7 wei on an idle chain.

Suggestion floor: the archive/RPC node on Frontend-01 sets `min-priority-fee=1000000000`.
On a non-validator this changes no inclusion rule; it makes `eth_maxPriorityFeePerGas`
return 1 gwei whenever recent blocks are empty, so wallet libraries that build EIP-1559
fees from base fee plus the suggested tip clear the validators' floor. `eth_gasPrice`
already returns 1 gwei (Besu floors it at `min-gas-price`), and the explorer's gas tracker
reports 1 gwei. `eth_feeHistory` rewards remain zero for empty blocks in Besu 26.8.1; the
bounding options for that endpoint are not exposed in this build.

`Tools/Deployment/install-besu.py` applies the archive-only setting; the live edit is
backed up under `/srv/backups/besu-fee-policy-*` on Frontend-01. Symptom that this fixes:
a wallet transaction accepted by the archive pool at a few wei that never leaves pending.

## 7. Contract deployment and governance

### Live initialization and functional acceptance: 2026-09-11

The named GasManager, CodeManager, GasSponsor and DakotaDelegationRegistry proxies
are initialized on the running development chain. The validator registry and
ProxyAdmin retain their reviewed genesis runtime. The shared beacon is owned by
the fixed delegation registry. Do not repeat first-link initialization.

The live suite confirmed 100 transaction receipts and 172 checks covering voter
quorum/recovery, proxy role separation and upgrades, native funding/burns, restricted
gas credit, code registration/redemption/delivery repair, real public EIP-7702
sponsorship, replay/owner-signature enforcement and beacon-upgrade nonce retention.
The explorer indexes the nested calls, including the sponsored redemption. See
[the full acceptance record](docs/live-genesis-acceptance-20260911.md),
[deployment tools](Tools/LiveGenesis/README.md), and
[the observer/handoff prompt](Tools/LiveGenesis/FOLLOW_AND_HANDOFF_PROMPT.md).

Cleanup removed temporary test voters/controllers, the canary privacy-group grant,
treasury guardian and relayer. Sponsorship is paused; the canary tenant is disabled
and its funding is zero. Remaining bootstrap voters/root/platform administrator
and voucher signer are retained for the authorized application deployment. The
supplied management address is nominated for GasSponsor and registry admin
acceptance; it has not accepted, and final ownership handover is not complete.

Face remains an unlinked reserved agent-registry proxy because an approved
implementation is unavailable. The development canary is not a production gift
or account-registration service. Paladin private execution has a separate completed
development acceptance record; Router integration remains unfinished. The retained validator initializer exception in
GOVERNANCE.md must be revisited before any external-only voter configuration.

Reserved proxies initially have zero implementation and unset initialization.
Deploy implementations separately, verify runtime and storage layouts, and link
with initializer calldata atomically. Public proxy governance resolves roots from
the validator contract. Private proxies need authority available inside their group;
do not assume the public registry is part of the private world state.

Follow [governance](Contracts/Genesis/GOVERNANCE.md) and
[native sponsorship](Contracts/Genesis/7702/GAS-SPONSORSHIP.md). Approved voter
snapshots prevent provider outages from lowering quorum. Membership is unique;
atomic replacements prevent empty controller sets and preserve four validators.
External registries stay unused initially. Never exercise irreversible governance
revocation as routine maintenance. Explicit initializer exceptions remain scoped
to the owner-approved closed bootstrap environment.

Code registration requires the gift contract or its approved registrar. Scope each
privacy group to approved gifts; use global group authorization only by deliberate
governance choice. Canonical UIDs and bounded batches prevent aliasing and resource
abuse. Redemption delivery records a recipient and supports retry to that same
recipient. The API must inspect delivery state and cannot replace it with a client flag.

## 8. Paladin operation, funding and private settlement

The deployed single-member Pente group runs on Paladin-01 (`100.111.32.201`) with
Paladin v1.0.0, PostgreSQL 17.11 and the existing connected Besu. The enabled units
`cryft-paladin` and `cryft-paladin-db` run as the non-login `cryft-paladin` user;
Nginx runs as `cryft-proxy`. Raw RPC, database and metrics bind loopback. The
privileged signing endpoint `http://100.111.32.201:8550/` permits only the admin
workstation, Backend-01 and loopback through Nginx. It is not a browser API.

The [Paladin maintenance runbook](Tools/Paladin/README.md) is part of this manual.
It includes exact service units, ports, images, data/secret paths, contract addresses,
funding, receipt reconciliation, restart, recovery, IPFS, upgrade and handover steps.
Read the [acceptance evidence](docs/paladin-acceptance-20260911.md) and
[dated funding snapshot](docs/paladin-funding-20260911.json) before changes.

| Funding role | Address | Rule |
|---|---|---|
| Automatic Paladin public settlement | `0x08Bb45a62993dC2BdEB0b5aebA28A191B9cC4549` | Fund native KOTA on chain 112311; 0.024371939 KOTA at block 362 |
| Deployment/development public relayer | `0x633309d1155fD658a717e4f5E4FA853615400867` | Needs native transaction-fee reserve even when later reimbursed |
| Private operator | `0xe7850EcEDe5d6f7d0B2d2cCaBfC2f29D2C345125` | Private execution does not require native balance |
| GasSponsor tenant | Card `0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410` | Deposit through FEeD ledger methods; separate from wallet funding |

Use `Tools/Paladin/funding.py` for a fresh read-only balance snapshot. The runbook
explains direct transfers and GasManager proposal/vote/execute funding. A suggested
development settlement reserve alerts below 0.01 KOTA and refills toward 0.03;
neither alert nor refill is automated. Registration currently costs 0.001 KOTA per UID.

Current private Combo proxy: `0x7a3eacca11e28712ed6e0dfc464795b2a0c2a342`.
Public group: `0x533E526f095407490BB0089D3fc38e73484523B0`.
Private group ID: `0x8b4e5a042c782d363c72538b2a518679c8a6e942c1b9850e768d975af54eba79`.
The public CodeManager and private Combo were upgraded without storage changes to
use `recordRedemptionStrict`: rejected public preconditions roll back the private
spend, while accepted redemptions with failed delivery retain the recipient for retry.
Five private redemptions delivered five public card NFTs. A public-only freeze and
retry of the exact same prepared transition proved the rejection recovery path.

Private contracts use Solidity 0.8.37/Shanghai, the installed interpreter's newest
supported execution target. Public contracts use Osaka; the validator remains London.
Private PUSH0 passed and MCOPY failed, while Besu accepted both. Ordinary private
proxy DELEGATECALL and native **public** EIP-7702 sponsorship of prepared Pente
settlement passed. Private EIP-7702 authorization processing is not established.
MetaTx and the trusted forwarder remain disabled. Sponsorship was paused and all
temporary sponsor funding/roles were cleaned up after acceptance.

A controlled PostgreSQL/Paladin restart preserved the same identities, group,
private roles, implementations and NFT ownership. An actual host reboot, independent
restore and multiparty/load acceptance remain separate work. **The owner instructed
that recovery secrets stay on Paladin-01; no off-server Paladin secret copy was made.**
Do not export its signing seed or database credentials without a new explicit decision.
The full recovery plan must preserve the seed, database and group/runtime configuration
together. Public admin possession is not automatically private signing access;
private identity and public/private ownership handover remain to be completed.

## 9. Explorer before application testing

Start Frontend-01's archive/RPC service, then Backend-01's Blockscout database and
indexer/API, then the explorer UI on Frontend-01. Configure the UI's API through
same-origin Nginx routes over Nebula; the browser must not be asked to reach backend
localhost. Verify Blocks, Transactions and a transaction detail against live RPC.

Live operator URL: `http://100.111.69.1:8080`. The browser connects through
Nebula; the UI origin remains `127.0.0.1:3001`. Inform the owner only after this URL
has been checked from their computer. Indexing lag must be visible and monitored.
Configure contract verification using exact standard JSON and compiler versions.

## 10. Kota API, widget and moment.cards

Build the Rust V4 core and portable modules from the review commit. Do not use the
legacy moving-main/V1 deployment script. The current private-operation adapter
reports `blocked/private_submission_not_implemented` for live requests and
`simulated` for dry runs. Implement and test real chain submission/settlement before
enabling issuance/redemption. A disabled capability is preferable to a false success.

Complete verified tenant/principal/scope authorization on every state-changing and
job/status route; signed admin requests must bind body, deployment domain and nonce.
Use PostgreSQL as the durable source of operations with atomic tenant/principal/action
idempotency keys, payload hashes, outbox, leases and crash recovery. Redis may cache
or rate-limit; it is not proof that value-moving requests are exactly-once. Associate
async jobs and delivery tokens with authenticated owners. Audit without logging codes,
PINs or private payloads. Keep deployment behind private ingress while blockers remain.

Discover and review the newer Dakota Cards/dashboard/docs/widget sources before
reusing them. Publish their exact refs and integration contracts. The API owns
business rules and supports arbitrary host sites; the widget and moment.cards consume
the same authenticated endpoints. Provide local admin UI for tenant, code lifecycle,
private/public state, sponsorship, receipts and pending-delivery repair. The UI cannot
hold privileged chain keys or authorize itself by claimed wallet/cookie flags.

## 11. LLM configuration

Development uses LM Studio `http://localhost:1234/v1`, model `qwen/qwen3.8-27b`;
remote development may use `http://100.111.1.4:1234/v1` after Nebula binding is verified.
Production uses xAI Grok when the owner supplies model and credentials. Configure
intent/planner/completion separately; never fall back to the operator's computer in
production. LLM output cannot authorize asset movement or tenant management. Bound
tokens, latency, concurrency and cost; test errors and cancellation.

## 12. IPFS and verification artifacts

Backend-01 hosts persistent Kubo with loopback API/gateway and Nebula-only peers.
Public bootstraps/discovery remain disabled. Current publishing uses pinned-host-key
SSH over Nebula to the loopback API. The private loopback gateway has been verified
through that SSH connection. Cloudflare gateway exposure and persistent mTLS
publishing are planned, not installed. A tunnel to the read-only gateway does not
enable peer discovery; public peering is a separate later configuration change.
Follow `Tools/SolcCompiler/deploy/backend-ipfs/README.md`.

Live deployed bytecode trailers were decoded and their exact metadata/source bytes
checked against Backend-01 recursive pins, API readback and private gateway readback.
The core 90-artifact bundle remains
`QmSuawtJhsHhAJNS2VtPx4UHTEPvQgDbJD7vKmkV7smMaf`; the development fixture has its
own metadata CID. `Tools/LiveGenesis/verify_ipfs.py` records per-address CIDs and
source hashes. The additional Paladin/application artifacts are tracked separately
in `docs/paladin-acceptance-20260911.json`: ten builds, 88 compiler objects, and two
preserved NFT metadata directories. Deployed public runtime bytes and private code
hashes match those pinned artifacts. The latest verification API check reports the
Rust verifier enabled with both required compilers. Subsequent source verification
completed for all 32,451 public addresses, with every stored runtime/source hash and
license checked independently. Missing genesis contract records were resolved.
The completed maintenance job is disabled; its evidence and pre-import database
backup remain on Backend-01. See `docs/blockscout-verification-20260911.md`.

The complete deployed-contract package is
[`Contracts/Verification/20260911`](Contracts/Verification/20260911/README.md): 21
replayed builds, all 32,433 genesis contracts, 18 later public creations and five
private deployments at the manifest's recorded audit block. It includes Standard
JSON input **and full output**, exact metadata, ABI, bytecode, per-file hashes,
constructor arguments and per-target SPDX/API licenses. Eighteen native precompiles
are catalogued as client code with no Solidity metadata. Use
[the verification runbook](Tools/BlockscoutVerification/README.md) and
[the other-LLM handoff](Tools/BlockscoutVerification/HANDOFF_PROMPT.md).
The publication receipt is `docs/blockscout-artifact-ipfs-20260911.json`; it records
all pinned artifact/source CIDs and exact API/gateway readback. Do not confuse MIT
proxy licenses with their Apache-2.0 implementation licenses.

The compiler automatically publishes when configured, verifies metadata/source CIDs
against embedded bytecode references, pins each object, reads back bytes, and records
a release-bundle CID. Never upload runtime secrets/private state. Local `--no-ipfs`
builds are explicitly unpublished; retry with `--publish-only` when Backend is ready.
Back up Kubo identity, pins and data; test gateway access and a restore independently.

## 13. Resource budgets and scaling

The explorer's pinned builds, runtime services, protected environment files and
recovered historical Dakota settings are documented in [the explorer runbook](Tools/Explorer/README.md).
It separates the API/database on Backend-01 from the UI/archive on Frontend-01.

Start with bounded workers and queues, not one process per shared vCPU by default.
Leave memory for the OS/page cache, databases and colocated services. Measure heap,
disk IOPS, RPC/indexing lag and p95 API latency; cap expensive traces/log queries.
Archive state and explorer indexes may outgrow 400 GB. Alert on disk headroom and
project growth before exhaustion; never silently prune the required archive.

Scale stateless API workers only after durable idempotency and ownership tests pass.
Separate pools for chat, issuance, redemption, private execution and indexing. Use
bounded connection pools and per-tenant backpressure. Four validators tolerate one
fault under QBFT; avoid restarting more than one together. Shared CPU latency needs
actual monitoring. Additional Paladin participants require explicit privacy membership.

## 14. Maintenance, recovery and final handover

For each release: record commits/digests/checksums, back up, validate config/migrations,
install staged artifacts, restart in dependency order, check health and a complete
lifecycle, and retain the previous release. Binary rollback is not safe across an
incompatible database migration; document its restore procedure. Never replace a
live genesis or node key to repair synchronization. Inspect genesis hash, peers,
time, disk, permissions and logs first. Redact credentials and redemption material.

Back up databases with point-in-time recovery, private keys/state and configuration,
genesis, IPFS pins and public deployment manifests to an independent encrypted target.
The backup destination, retention and RPO/RTO are deployment inputs still to be supplied.
Test restore and host reboot, service ordering, Nebula reconnection and explorer catch-up.

Handover includes every owner, pending owner, voter/root, proxy controller, issuer,
minter/recovery role, sponsor manager/signer/relayer, private service/UID manager,
SSH operator, tunnel credential and backup access. Recipient acceptance requires
the recipient's actual signature. Keep the old controller until acceptance/control
is verified, then remove temporary rights and verify they can no longer act.
Document all remaining operational roles; funding a test account does not authorize
it to retain contract ownership.

## 15. Required acceptance evidence

Record actual results for genesis/validator identity; restart persistence; public
and private delegation; gas credit/withdrawal restrictions; issue/register/store/
redeem/delivery/retry; duplicate/race/crash recovery; tenant isolation; admin handover;
explorer visibility; IPFS retrieval; API/widget/direct integration; backups/restore;
and measured concurrency. Do not promote unresolved critical API, contract or
privacy-path blockers. Send production promotion for owner review after these pass.

## 16. Kota tenant access contracts — validated deployment

Kota tenant release `1.4.0` is deployed on the existing chain and genesis, from
`CryftCreator/KotaRouter` deployment source commit
`d1402eb7071a32af98a6359d9992578226c766a7`. The access credential proxy is
`0xa6a1161Fc96561c5DD94Ab4082D8b867E7C102C0` and factory proxy is `0xD99A083A2125dB1881e1D315885c7ba0FAc933d0`.
The moment.cards membership registry/public routing key is `0xA6B1dFA510B2854b8FA33ab3865535bb41CC2340`.
These are service access credentials, separate from the existing redeemable card NFT.

Forty successful transactions and 32 live checks validated issuance, caps, locks,
metadata, recovery and removal of temporary authority. All ten implementation,
proxy, ProxyAdmin and beacon addresses are fully verified in Blockscout with MIT
licensing. All 43 public source/metadata objects were pinned and retrieved through
Backend-01 IPFS. Compiler 0.8.34 targets Osaka; no genesis or Paladin state changed.

The final root `0x9247524040D91D5dd1521A25f2e7711d4a0fe921` controls issuer, factory admin, both tenant operators
and both ProxyAdmins. The factory owns the shared beacon. Temporary deployer and
tester credentials were revoked and their tenant minting rights invalidated.
The test registry is empty and locked; moment.cards is empty and unlocked, with
three active registries allowed, 10000 holders each and a 128 lifetime-slot bound.

See KotaRouter `router_v4/contracts/deployment/README.md`, `addresses.json`,
`router-bindings.env.example`, and `receipts/` for the full maintenance procedure,
review findings, metadata CIDs, all addresses and transaction evidence. The network
inventory `docs/current-contract-addresses.json` includes this deployment under
`kota_tenants`, retaining the earlier verification timestamp for other contracts.
The router/widget binding and redemption API lifecycle still require integration.
No service minter is authorized yet; the root operator must explicitly approve
a runtime issuance wallet when that integration is ready. Fund that wallet with
native gas or an approved sponsor policy; do not fund the membership contracts.

## 17. Current maintenance index and acceptance boundaries

Use [current system status](docs/CURRENT_STATUS.md) for the active inventory and
document map. The [read-only September 11 snapshot](docs/documentation-live-check-20260911.json)
records service state, wallet balances, verified Kota addresses and independent
authority planes. Old receipt timestamps remain historical evidence, not live balances.
The one-shot prompt is a resume procedure: no genesis reset, reenrollment,
reinitialization, redundant contract deployment or duplicate IPFS/source upload.

Canonical Rust routes check registry locks uncached. The optional platform
companion currently uses database membership and the slug `moment-cards`;
the deployed registry's ID is exactly `moment.cards`. Reconcile identities,
registration and on-chain authorization before connecting it to the widget or
direct API clients. A public profile key and an Origin header are not credentials.
Source promotion does not resolve these integration gaps or authorize a live cutover.

## September 12 tenant API lifecycle acceptance

The published KotaRouter review branch completed a service-created postcard and
private-code redemption to development wallet
`0x35f9a01bc437c998175E56eD78F77C808FC64c18` (public card NFT token 6).
Delivery transaction: `0x1613fed4e6f9a3a01a030b5af446b0800a40d91c140ae5c170bdf01e456ab01c`.
The recipient spent no native gas. API/database acceptance does not imply that
Kota application services have already been installed on the droplets.

Monitor **both** public gas accounts on Paladin-01:

- `0x08Bb45a62993dC2BdEB0b5aebA28A191B9cC4549`: Pente public settlement.
- `0xe7850EcEDe5d6f7d0B2d2cCaBfC2f29D2C345125`: operator for direct public mint submissions.

The operator was separately funded with 0.03 KOTA for the acceptance test. Funding
settlement alone had left its mint pending. The original Paladin transaction ID
was resumed after funding; a second mint was not submitted. Paladin keys remain on
Paladin-01. Public sponsorship deposits do not replace these account balances.

The test raised bounded card sale inventory from 5 to 8 with the existing card
owner account. Confirm launch inventory and finish the recorded owner handover
before production. The supplied root remains the tenant operator; test wallets
were not given tenant-owner authority. See the KotaRouter tenant service manual
and sanitized acceptance reports for API operations, encryption and restore rules.

## 18. Token-bound accounts — review only, not deployed

An ERC-6551 v0.3.1 compatible registry and `MomentCardAccount` implementation are
in `Contracts/Accounts/` for moment.cards inventories. They are not on chain
112311. Canonical registry `0x000000006551c19487814612e58FE06813775758` and
Nick's CREATE2 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` have no
bytecode on this genesis. Occupying the canonical registry address requires the
factory first, then the original v0.3.1 bytecode — the 0.8.37 Osaka review build
cannot land there. If the factory's pre-EIP-155 transaction is rejected, accept a
non-canonical registry after review.

Application salt is `keccak256("moment.cards:tba:v1")`. Bind the first resolved
account per card; a later implementation address is a different TBA and must not
be switched silently. Nested CARD NFTs from the parent collection
`0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410` are rejected. See
`Contracts/Accounts/README.md` and `docs/current-contract-addresses.json` `tba`.


## Issuance and concurrency review — 15 September 2026

The review uses locally generated 12-character codes and private-state assigned
three-digit prefixes, optional encrypted local backups, receipt-bound UID tracking
and shared batch metadata. Membership spending uses gas allocations; max batch size
and batches per minute are separate traffic safeguards. Card-per-hour quotas have
been retired. API 1.14.0, the widget and moment.cards must deploy together after
the matching public/private contract and allowance activation.

Offline regression and PostgreSQL concurrency tests pass. This does not activate
browser publishing. The root wallet must approve the reviewed public upgrades and
gas configuration; private deployment, metadata publication, runtime pins and live
browser creation/redemption must then be verified. Do not advertise this review as
production-ready or merge main as a substitute for that acceptance.
