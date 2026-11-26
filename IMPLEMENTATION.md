# Kota / Cryft implementation and operations manual

> **Note (2026-11-23).** The consumer app is **Cryft Cards** (`cryft.cards`). On-chain strings and deployed contract names keep
> their deployed values.

## 1. Purpose and current status

Kota is the API service for issuing, managing and redeeming codes/tokens. The widget
is an optional client; sites/apps may call the documented endpoints directly.
Cryft Cards is the initial consumer for greeting cards, business cards and postcards. Cryft's
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
with `review/moment-cryft-tenant` retained. Known build/integration gaps remain.
The existing `Greeting Cards/` application becomes Cryft Cards in place,
including greeting cards, business cards and postcards. `Cryft Cards/` is the
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

### Genesis

The chain is 113211. Its genesis is built from source by `Tools/Genesis/build.py`;
`python Tools/Genesis/build.py --check` rebuilds `Contracts/Genesis/CryftGenesis.json`
and `genesis-release.json` byte for byte. The validator set is
`Tools/Genesis/validators.json`. Public builds use Solidity 0.8.37/Osaka; the
validator stays 0.8.19/London. See `Tools/Genesis/README.md`.

Install the same genesis file on every Besu node (validators, the archive/RPC node
and Paladin-connected Besu). Never start nodes with different genesis hashes, and
never replace a live genesis or node key to repair synchronization.

### Fee policy

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
Use `Tools/Paladin/funding.py` for a fresh read-only balance snapshot. The runbook
explains direct transfers and GasManager proposal/vote/execute funding. A suggested
development settlement reserve alerts below 0.01 CRYFT and refills toward 0.03;
neither alert nor refill is automated. Registration currently costs 0.001 CRYFT per UID.

The public CodeManager and private Combo use `recordRedemptionStrict`: rejected public
preconditions roll back the private spend, while accepted redemptions with failed
delivery retain the recipient for retry.

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

## 10. Kota API, widget and Cryft Cards

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

Discover and review the newer Cryft Cards/dashboard/docs/widget sources before
reusing them. Publish their exact refs and integration contracts. The API owns
business rules and supports arbitrary host sites; the widget and Cryft Cards consume
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

The compiler automatically publishes when configured, verifies metadata/source CIDs
against embedded bytecode references, pins each object, reads back bytes, and records
a release-bundle CID. Never upload runtime secrets/private state. Local `--no-ipfs`
builds are explicitly unpublished; retry with `--publish-only` when Backend is ready.
Back up Kubo identity, pins and data; test gateway access and a restore independently.

## 13. Resource budgets and scaling

The explorer's pinned builds, runtime services, protected environment files and
recovered historical Cryft settings are documented in [the explorer runbook](Tools/Explorer/README.md).
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

## 16. Acceptance boundaries

Canonical Rust routes check registry locks uncached. The optional platform
companion currently uses database membership and the slug `cryft-cards`;
the deployed registry's ID is exactly `cryft.cards`. Reconcile identities,
registration and on-chain authorization before connecting it to the widget or
direct API clients. A public profile key and an Origin header are not credentials.
Source promotion does not resolve these integration gaps or authorize a live cutover.

