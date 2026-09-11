# Kota / Dakota implementation and operations manual

## 1. Purpose and current status

Kota is the API service for issuing, managing and redeeming codes/tokens. The widget
is an optional client; sites/apps may call the documented endpoints directly.
moment.cards is the initial consumer for business cards and postcards. Dakota's
Besu public ledger and Paladin privacy state supply the underlying settlement.

This manual describes the development release under review. Source changes and
local checks do not establish a deployed service. Record each completed installation
in the deployment inventory with its exact commit, image digest, genesis checksum,
service unit, addresses, ports and health evidence. The explorer URL below remains
planned until checked from the administrator's computer. Production promotion is
separate and leaves `main` unchanged until owner approval.

## 2. Source and release ownership

Use `cryft-labs/dakota-network`, branch `review/compiler-standard-json`, and
`CryftCreator/KotaRouter`, branch `review/primary-api-lmstudio`. Resolve and record
full commit SHAs, push current changes before live testing, then deploy exact commits.
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

All validator/P2P, internal RPC and inter-host application traffic uses Nebula with
role-specific firewall rules. Application HTTP origins bind 127.0.0.1. Cloudflare
Tunnel reaches local Nginx for public websites; sensitive admin routes require
Nebula or authenticated Access. Do not publish raw validator, database, Paladin
admin, IPFS administration or unrestricted JSON-RPC ports to the public Internet.

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
Rootless Podman preparation on Paladin-01 is not a running network. The isolated
`Tools/RuntimeReview` harness is a test tool and must not conflict with final services.

Nginx listens on unprivileged ports as its own runtime user. Validate syntax before
reload. Configure request-body limits, per-IP/per-principal rates, connection caps,
timeouts, websocket forwarding and bounded retries appropriate to each service.
Never automatically retry a value-changing POST. Accept proxy identity headers only
from authenticated/trusted ingress and overwrite spoofable forwarding headers.

## 6. Genesis and validators

The existing archive defines chain ID 112311, 64,000,000 block gas, 32,768-byte
contract limit, the fork schedule, QBFT timing and system addresses. Preserve it.
Only normalize removed option aliases for the pinned Besu version with a recorded diff.
Public builds use Solidity 0.8.37/Osaka; the validator stays 0.8.19/London with the
same `getValidators()` ABI encoding. Besu is pinned to 26.8.1, requiring Java 25.

Keep only `Contracts/Genesis/besuGenesis.7z` and its checksums in Git. The archive
contains exactly `BesuGenesis.json`. After pulling the pinned release, verify the
archive checksum, extract to a staging directory on **every Besu node**, verify
the extracted JSON checksum, then atomically install the same file at the configured
`--genesis-file` path. Include validators, the archive/RPC node, and Paladin-connected
Besu nodes. Never start nodes with different genesis hashes or upload the 1.2 GB
uncompressed JSON to Git. Do not reset an existing chain database automatically.

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

## 8. Paladin and private delegation acceptance

Use the pinned latest stable Paladin v1.0.0 image in `Tools/RuntimeReview/runtime-lock.json`.
Record both tag source and image commit label. Test actual private EIP-7702 processing,
private code designation/execution, ordinary private DELEGATECALL, and prepared
transition approval/delegated public settlement separately. Track the public payer,
gas reimbursement, private state and public side effects in one lifecycle record.

Use the latest target actually proven supported. Stock source selects Shanghai as
its newest private target; a public Osaka chain does not by itself prove private
Osaka/7702. Test the requested newer path against the actual binary. MetaTx remains
disabled unless those results establish that it is needed; the legacy relay is not
automatically a production-safe fallback. Use durable PostgreSQL for final Paladin
state and back up its keys, domain/group definitions, schemas and state together.

## 9. Explorer before application testing

Start Frontend-01's archive/RPC service, then Backend-01's Blockscout database and
indexer/API, then the explorer UI on Frontend-01. Configure the UI's API through
same-origin Nginx routes over Nebula; the browser must not be asked to reach backend
localhost. Verify Blocks, Transactions and a transaction detail against live RPC.

Planned operator URL: `http://100.111.69.1:8080`. The browser connects through
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
Disable public bootstraps/discovery and constrain swarm routes. Cloudflare exposes
the read-only gateway through Nginx; it does not enable peer discovery. Public
peering is a separate later configuration change. Protect publishing with mTLS
over Nebula. Follow `Tools/SolcCompiler/deploy/backend-ipfs/README.md`.

The compiler automatically publishes when configured, verifies metadata/source CIDs
against embedded bytecode references, pins each object, reads back bytes, and records
a release-bundle CID. Never upload runtime secrets/private state. Local `--no-ipfs`
builds are explicitly unpublished; retry with `--publish-only` when Backend is ready.
Back up Kubo identity, pins and data; test gateway access and a restore independently.

## 13. Resource budgets and scaling

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
