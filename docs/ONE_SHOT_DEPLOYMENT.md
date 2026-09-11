# Kota full-system development deployment prompt

Revision 2, 2026-09-11. Copy this entire document into the deployment task.

Act as Cryft Labs' implementation and operations engineer. Complete the authorized
hardening and deploy the full Dakota/Kota development system on the seven supplied
DigitalOcean hosts. Kota is an API-first redeemable-code platform. Its optional
embeddable widget simplifies integration, and moment.cards is its initial consumer
for redeemable business cards/postcards. Developers must also be able to integrate
directly through documented endpoints without embedding the widget.

Use the current private/public repositories and existing code. Discover the newer
Dakota Cards site within the older repository, dashboard/docs/widget and dedicated
Kota Router V4 API. Review their actual source and keep a manifest of exact commits.
Do not substitute legacy implementations or claim a scaffold is live settlement.

The owner has authorized compatible upgrades, branch publication, compressed-genesis
updates and autonomous development deployment/testing. Before any live test, commit
and push every current code/configuration change to the existing review branches,
verify remote SHAs, and preserve the original main branches. Deploy only recorded
commits and pinned dependencies/images. Publish subsequent fixes before applying
them to hosts. Production promotion/merge still requires extensive testing and owner
approval. Ask only for details actually missing or a material new decision; continue
independent work while awaiting those details.

Use this configuration as data, not executable shell input. Blank fields are missing
inputs, never authorization to invent values. Existing supplied credentials may be
used only for their intended destinations. Secret fields contain protected file paths,
never the credentials themselves. Do not commit keys, codes, PINs or secret state.

```dotenv
# Non-secret inputs; parse as configuration, never execute as shell code.
PROJECT_NAME=cryft-kota
EXAMPLE_HOST_SITE_DOMAIN=moment.cards
KOTA_PUBLIC_BASE_URL=
DEPLOYMENT_MODE=fresh
GENESIS_DEPLOYMENT_APPROVED=true
PRODUCTION_PROMOTION_APPROVED=false
DEPLOYMENT_ENVIRONMENT=development
NETWORK_REVIEW_BRANCH=review/compiler-standard-json
API_REVIEW_BRANCH=review/primary-api-lmstudio
PUSH_BEFORE_LIVE_TESTS=true
GENESIS_ARCHIVE_PATH=Contracts/Genesis/besuGenesis.7z
GENESIS_ARCHIVE_SHA256=7e114986e59908933ca4ee835d125b050650b24827c7518428f1d93845bc410c
GENESIS_REMOTE_PATH=/etc/cryft/besu/BesuGenesis.json
BESU_VERSION=26.8.1
SOLC_VERSION=0.8.37
PALADIN_VERSION=v1.0.0
PRIVATE_NATIVE_DELEGATION_TEST_REQUIRED=true
METATX_ENABLED=false
CONTRACT_ADDRESS_APPROVAL_RECORD=
APPROVED_CONTRACT_MANIFEST_SHA256=
BOOTSTRAP_SSH_USER=root
BOOTSTRAP_SSH_PORT=22
ADMIN_SSH_IDENTITY_FILE="C:/Users/ChadS/Documents/Codex/2026-09-08/a/outputs/cryft-ssh/private/cryft-admin"
OPERATOR_SSH_USER=cryft-ops
ADMIN_NEBULA_IP=100.111.1.4
TEMPORARY_BOOTSTRAP_SOURCE_CIDR=
NEBULA_PROVIDER=defined-networking

VALIDATOR_01_NEBULA_IP=100.111.32.101
VALIDATOR_02_NEBULA_IP=100.111.32.102
VALIDATOR_03_NEBULA_IP=100.111.32.103
VALIDATOR_04_NEBULA_IP=100.111.32.104
PALADIN_01_NEBULA_IP=100.111.32.201
BACKEND_01_NEBULA_IP=100.111.67.1
FRONTEND_01_NEBULA_IP=100.111.69.1

VALIDATOR_01_PUBLIC_IP=137.184.70.9
VALIDATOR_02_PUBLIC_IP=134.209.124.114
VALIDATOR_03_PUBLIC_IP=157.230.0.98
VALIDATOR_04_PUBLIC_IP=142.93.0.157
PALADIN_01_PUBLIC_IP=146.190.75.149
BACKEND_01_PUBLIC_IP=206.81.13.59
FRONTEND_01_PUBLIC_IP=147.182.191.138

VALIDATOR_01_ENROLLMENT_KEY_FILE=
VALIDATOR_02_ENROLLMENT_KEY_FILE=
VALIDATOR_03_ENROLLMENT_KEY_FILE=
VALIDATOR_04_ENROLLMENT_KEY_FILE=
PALADIN_01_ENROLLMENT_KEY_FILE=
BACKEND_01_ENROLLMENT_KEY_FILE=
FRONTEND_01_ENROLLMENT_KEY_FILE=

NETWORK_REPOSITORY=cryft-labs/dakota-network
NETWORK_REFERENCE_COMMIT=8999a9aa187c34232a5ce3bbd63fcaabc07b6ace
EXPLORER_FRONTEND_REPOSITORY=cryft-labs/dakota-explorer
EXPLORER_REFERENCE_COMMIT=818c3cef62685e52f19470573012f092c6c1c6d9
CRYFT_SITE_REFERENCE_REPOSITORY=CryftCreator/CryftLabs.org
CRYFT_SITE_REFERENCE_COMMIT=337bb7e66a3214b1f76bd31818695d9f7533c44d
DAKOTA_SITE_REPOSITORY=
DAKOTA_SITE_SOURCE_REF=
DAKOTA_SITE_SOURCE_DIRECTORY=
DASHBOARD_REPOSITORY=
DASHBOARD_SOURCE_REF=
DOCS_REPOSITORY=
DOCS_SOURCE_REF=
WIDGET_REPOSITORY=
WIDGET_SOURCE_REF=
WIDGET_SOURCE_DIRECTORY=
SERVICE_API_NAME="Kota Router"
SERVICE_API_REPOSITORY=CryftCreator/KotaRouter
SERVICE_API_SOURCE_REF=67be819ec854bd7771a6d4ad17d63dc821c9fb86
SERVICE_API_SOURCE_DIRECTORY=router_v4/rust_core
LOCAL_DEVELOPMENT_FIRST=true
DEV_LLM_PROVIDER=lmstudio
DEV_LLM_BASE_URL=http://localhost:1234/v1
DEV_LLM_NEBULA_BASE_URL=http://100.111.1.4:1234/v1
DEV_LLM_MODEL=qwen/qwen3.8-27b
DEV_EMBEDDING_MODEL=text-embedding-nomic-embed-text-v1.5
PRODUCTION_LLM_PROVIDER=xai_grok
PRODUCTION_LLM_BASE_URL=https://api.x.ai/v1
PRODUCTION_LLM_MODEL=
PRODUCTION_LLM_API_KEY_FILE=
PUBLIC_CONTRACT_EVM=osaka
VALIDATOR_CONTRACT_EVM=london
VALIDATOR_SOLC_VERSION=0.8.19
PRIVATE_CONTRACT_EVM=shanghai
PRIVATE_EVM_UPGRADE_DECISION=
STANDARD_JSON_EXPORT_REQUIRED=true
CONTRACT_METADATA_IPFS_REQUIRED=true
IPFS_AUTO_PUBLISH=true
IPFS_HOST=Backend-01
IPFS_API_URL=https://100.111.67.1:8444
IPFS_API_AUTH_FILE=
IPFS_TLS_CA_FILE=
IPFS_TLS_CLIENT_CERT_FILE=
IPFS_TLS_CLIENT_KEY_FILE=
IPFS_TIMEOUT_SECONDS=60
IPFS_MAX_FILE_BYTES=67108864
IPFS_RUNTIME_USER=cryft-ipfs
IPFS_PEER_MODE=nebula_only
IPFS_PUBLIC_GATEWAY_HOSTNAME=
IPFS_CLOUDFLARE_TUNNEL_ID=
IPFS_CLOUDFLARE_CREDENTIAL_FILE=
IPFS_SECONDARY_PIN_TARGET=
MOMENT_SITE_REPOSITORY=
INFRASTRUCTURE_REPOSITORY=
APPROVED_NETWORK_COMMIT=
APPROVED_EXPLORER_COMMIT=
APPROVED_WIDGET_COMMIT=
APPROVED_API_COMMIT=
APPROVED_SITE_COMMIT=
APPROVED_DAKOTA_SITE_COMMIT=
APPROVED_DASHBOARD_COMMIT=
APPROVED_DOCS_COMMIT=
APPROVED_INFRASTRUCTURE_COMMIT=
RELEASE_APPROVAL_RECORD=

CHAIN_ID=112311
CHAIN_NETWORK_ID=112311
GENESIS_SHA256=95b4b05f4dea051a6f6cbf3babc164456044d55369d28548aa8026787a75e0ee
CONTRACT_ADDRESS_MANIFEST_FILE=
GENESIS_ALLOCATION_POLICY=
DELEGATION_ROUTE_POLICY=
PRIVATE_GROUP_DEPLOYMENT_DOMAIN=
VALIDATOR_KEY_SECRET_STORE=
PALADIN_KEY_SECRET_STORE=
RELAYER_KEY_SECRET_STORE=
GOVERNANCE_AUTHORITY_ADDRESSES=
WALLET_UPGRADE_AUTHORITY_POLICY=
SPONSOR_FUNDS_POLICY=
REDEEMABLE_ASSET_POLICY=

CLOUDFLARE_ACCOUNT_ID=
CLOUDFLARE_ZONE_ID=
CLOUDFLARE_HOSTNAME_ZONE_MAP_FILE=
CLOUDFLARE_TUNNEL_ID=
CLOUDFLARE_TUNNEL_TOKEN_FILE=
CLOUDFLARE_API_TOKEN_FILE=
API_PUBLIC_BASE_URL=
DAKOTA_PORTAL_HOSTNAME=
CRYFT_SITE_PUBLIC_HOSTNAME=
DOCS_PUBLIC_HOSTNAME=
DASHBOARD_PRIVATE_HOSTNAME=
EXPLORER_PUBLIC_HOSTNAME=
WIDGET_PUBLIC_BASE_URL=
ADMIN_ACCESS_MODE=nebula
ADMIN_PUBLIC_HOSTNAME=
CLOUDFLARE_ACCESS_TEAM=
CLOUDFLARE_ACCESS_AUDIENCE=
ADMIN_IDENTITY_PROVIDER=
ADMIN_IDENTITY_SECRET_FILE=
PUBLIC_RAW_RPC_ENABLED=false
SERVICE_MANAGER=systemd
HTTP_ORIGIN_BIND=127.0.0.1
NGINX_LOCAL_BIND=127.0.0.1
NGINX_LOCAL_PORT=8080
NGINX_NEBULA_PORT=8443
NGINX_RUNTIME_USER=cryft-proxy

APPLICATION_SECRET_STORE=
DATABASE_SECRET_STORE=
BACKUP_DESTINATION=
BACKUP_CREDENTIAL_FILE=
BACKUP_ENCRYPTION_KEY_FILE=
BACKUP_RETENTION_POLICY=
REQUIRED_RPO_MINUTES=
REQUIRED_RTO_MINUTES=
EXPECTED_CONCURRENT_USERS=
EXPECTED_REDEMPTIONS_PER_MINUTE=
REQUIRED_P95_API_LATENCY_MS=
MAINTENANCE_WINDOW=

# Supplied management address and generated identities for development deployment.
ROOT_OVERLORD_ADDRESS=0x9247524040D91D5dd1521A25f2e7711d4a0fe921
INITIAL_MANAGEMENT_ADDRESS=0x9247524040D91D5dd1521A25f2e7711d4a0fe921
CONTRACT_DEPLOYER_ADDRESS=0x633309d1155fD658a717e4f5E4FA853615400867
DELEGATION_TEST_ACCOUNT_ADDRESS=0x991acc255761dEE0421Ccd3F436788C24425122E
GENESIS_EDIT_OWNER=assistant_authorized_by_user
DEPLOYER_FUNDING_OWNER=genesis_allocation
INITIAL_ADMIN_BALANCE_WEI=32000000000000000000
CONTRACT_DEPLOYER_BALANCE_WEI=1000000000000000000
DELEGATION_TEST_BALANCE_WEI=1000000000000000000
BOOTSTRAP_ROOT_ADDRESSES=0x9247524040D91D5dd1521A25f2e7711d4a0fe921,0x633309d1155fD658a717e4f5E4FA853615400867
BOOTSTRAP_VOTER_ADDRESSES=0x633309d1155fD658a717e4f5E4FA853615400867
FINAL_ROOT_ADDRESSES=0x9247524040D91D5dd1521A25f2e7711d4a0fe921
FINAL_VOTER_ADDRESSES=0x9247524040D91D5dd1521A25f2e7711d4a0fe921
FINAL_ADMIN_ACCEPTANCE_REQUIRED=true
VALIDATOR_01_ADDRESS=0xCdC8d72552dC91EC70b381Cc5b869ad64cEf8451
VALIDATOR_02_ADDRESS=0x4E84562aCD2A3846C6dA115F00127EBf8279457d
VALIDATOR_03_ADDRESS=0xCaBE4444b7d2f7A859dC0a9e9963a0dD0d6D8400
VALIDATOR_04_ADDRESS=0xAFd389303A515D57dc2A97f46908c0E9DDdfa33C

# Operator-visible explorer via encrypted Nebula; application stays on localhost.
EXPLORER_NEBULA_IP=100.111.69.1
EXPLORER_NEBULA_PORT=8080
EXPLORER_NEBULA_URL=http://100.111.69.1:8080
EXPLORER_ORIGIN_BIND=127.0.0.1
EXPLORER_ORIGIN_PORT=3001
EXPLORER_START_EARLY=true
```

## Deployment sequence and requirements

1. Inspect the current local and remote state, read repository instructions, preserve
   existing files/data and recover the latest checkpoint. Review changes, verify
   compiler exports/regressions and secret exclusions, commit/push to review branches,
   then record full remote SHAs and unchanged main SHAs. Update the technical manual
   as each fact is verified. A published test checkpoint is not production certification.
2. Bootstrap using the supplied root SSH identity and pinned host keys. Enroll each
   host in Defined Networking using its assigned enrollment key/IP. Verify operator
   SSH over Nebula before removing public SSH/root access. Configure Nebula peer and
   host firewall rules by role while preserving its required UDP underlay. All P2P,
   internal RPC, database and SSH connections use Nebula thereafter. Public web
   traffic uses Cloudflare Tunnel; no public application ports are exposed.
3. Create separate non-login, low-privilege runtime users, protected configuration
   and secret files, writable data directories, pinned releases, and persistent
   systemd service units with restart/backoff, startup dependencies and resource
   budgets. Application HTTP origins bind localhost behind local unprivileged Nginx.
   Add request/concurrency limits, safe timeout/retry behavior, trusted ingress rules
   and authentication appropriate to each service. Test restarts and reboots.
4. Use chain details from the existing genesis, including chain ID, fork schedule,
   gas/contract size, QBFT parameters and preassigned system addresses. Preserve the
   validator's London/0.8.19 build and getValidators() return encoding. Compile other
   public contracts with 0.8.37/Osaka and private contracts for the newest target
   supported by the tested Paladin runtime. Use pinned current Besu 26.8.1/Java 25 and
   Paladin v1.0.0 images, verifying actual image provenance. Normalize only required
   removed Besu aliases with an explicit recorded diff. The reviewed genesis has
   Osaka plus BPO1–BPO5 at timestamp 0, preserving inherited blob parameters.
   Do not enable unfinalized Amsterdam/future/experimental forks. Check the pinned
   release's actual genesis schedule rather than treating EVM-library names as
   supported activation fields. Preserve the validator's London target.
5. Update every embedded genesis runtime from verified current artifacts. Preserve
   the four existing generated validator identities, 32 tokens for the management
   account and 1 token for each of the deployment and delegation-testing accounts.
   Keep temporary bootstrap authority only for autonomous setup/testing; record its
   removal plan. Reserved proxies remain uninitialized until separate implementation
   deployment and atomic first-link initialization. Do not regenerate node keys.
6. Compress the updated genesis as besuGenesis.7z containing BesuGenesis.json. Publish
   the archive, never the uncompressed large JSON, with SHA-256 checksums for both.
   Pull the exact release onto every Besu node, verify the archive, extract to staging,
   verify the JSON, then install it at each service's configured genesis path. Include
   validators, archive/RPC and Paladin-connected Besu nodes. Confirm identical hashes
   before any startup. Do not reset an existing chain/data directory automatically.
   For an existing deployment of the exact prior BPO2 archive, use only the
   documented compatible BPO update procedure: preserve backups/data, verify
   header/protocol equivalence, update non-validators first, and restart/check
   validators individually while retaining quorum. Other retroactive fork changes
   require a separate migration decision.
7. Start four validators with Nebula-only peering. Verify chain ID/genesis, validator
   list, quorum, block production, gas/size behavior and synchronization. Frontend-01
   hosts the main archival RPC and web interfaces. Backend-01 hosts Blockscout backend,
   database and Kota API. Paladin-01 hosts privacy services and its connected node.
8. Bring the explorer up before application deployment/testing: Backend indexer/API
   plus Frontend UI with same-origin Nginx routes over Nebula. The operator URL is
   http://100.111.69.1:8080, with UI origin localhost:3001. Verify from the operator's
   computer that blocks and a transaction detail load, then immediately provide the
   working URL so the owner can watch. Do not announce a planned URL as running.
   Use the pinned rootless services and recovered Dakota settings documented in
   Tools/Explorer/README.md. Publish configuration changes before running its installer.
9. Install Backend IPFS as a persistent nonroot service with Nebula-only peers,
   loopback origins, protected mTLS publishing API and read-only Cloudflare gateway.
   Do not enable public swarm discovery/peering now. Configure automatic compiler
   publication of exact metadata, referenced sources, standard JSON, ABI and bytecode.
   Verify embedded CIDs, pins and read-back bytes and record the release-bundle CID.
   Gateway access does not imply public peering. Never upload private runtime data.
10. Deploy/link/initialize public implementations using the reserved addresses.
    Follow the current direct dispatcher sponsorship route: EOA -> immutable v2
    dispatcher -> shared beacon -> delegation logic. The registry and GasSponsor
    remain upgradeable at their reserved proxies. No EOA proxy initialization is
    needed. Use gas-only treasury credits, signed bounded vouchers, tenant caps,
    persistent nonces/idempotency and receipt reconciliation. Start sponsorship paused.
11. Test the owner's requested private delegation against the actual latest runtime:
    private authorization processing and code read-back/execution, private DELEGATECALL,
    and approved delegated public settlement of prepared private transitions. Record
    each result separately, including public payer/gas and private/public state.
    Test newer EVM support explicitly; unsupported requests or successful no-op calls
    are not proof. Use native delegation where verified. Only use MetaTx if tests
    establish necessity, and harden/test that fallback before enabling it.
12. Complete Kota V4 authorization, durable PostgreSQL operations/outbox, atomic
    tenant/principal/action idempotency, job ownership, body/domain/nonce-bound admin
    signatures, real Paladin/chain adapters, account registration contracts, and
    issuance/redemption/status/delivery APIs. Keep unresolved paths disabled behind
    private ingress. Validate the full lifecycle and failure recovery through real
    endpoints. A simulated/blocked private operation cannot be reported submitted.
13. Build the local admin UI, optional widget, docs/dashboard and moment.cards using
    the same documented service contract. Admins can generate/manage codes and inspect
    private/public lifecycle and sponsorship states through the API. Enforce tenant
    isolation, scoped credentials, origin policy and redacted audit records. No browser
    secrets, wallet-claim bypasses or LLM-authorized asset movement. Developers can
    replace the widget with their own clients without losing service functionality.
14. Develop LLM functions using local LM Studio at localhost:1234/v1 (or the verified
    Nebula endpoint) with qwen/qwen3.8-27b. Production uses Grok once the owner supplies
    credentials/model. Explicitly configure planner/intent/completion roles and test
    provider errors, budgets and concurrency; no production fallback to local LM Studio.
15. Measure concurrency before scaling. Use bounded workers/queues/pools, per-tenant
    quotas and backpressure. Monitor shared CPU, disk/IOPS, memory, peer health,
    database recovery, indexing lag and archive growth. Keep headroom and plan storage
    expansion. Test duplicate redemption, replay, expiry, failed delivery/retry, cross-
    tenant access, crash/restart, key rotation, one-validator outage and backup restore.
16. Finish the management handover to the supplied admin or a later approved multisig.
    Inventory owners, voters/roots, proxy guardians, issuers/minters/recovery roles,
    private services/UID managers, sponsor managers/signers/relayers and off-chain
    credentials. Propose two-step transfers, obtain actual recipient acceptance,
    verify control, then remove temporary deployment authority. Never remove the last
    working controller while acceptance is pending. Clearly report any recipient
    signature still needed; do not pretend to control the owner's private key.

Maintain a chaptered technical operations manual in the existing repository. Include
architecture, endpoint/schema/client integration, exact inventories and addresses,
service users/units/startup paths, firewall/Nginx/tunnel rules, releases, contract
storage/ABI/authority, genesis checksums, IPFS CIDs, backup/restore, troubleshooting,
runbooks, scaling, testing and handover. Record actual versus planned state and each
material change so a new developer can maintain the system without prior context.

Finish with pushed review branch/commit links, actual service and explorer URLs,
test results and limitations, genesis/archive hashes, contract/address/ownership
manifest, IPFS publication receipts, maintenance manual and any truly missing input.
Preserve main branches until explicit production approval after acceptance.
