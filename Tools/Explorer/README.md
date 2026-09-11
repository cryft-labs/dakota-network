# Dakota explorer deployment

This development deployment separates the branded Dakota frontend on Frontend-01
from the Blockscout API/indexer, PostgreSQL and Redis on Backend-01. Its intended
entry point is `http://100.111.69.1:8080` over Nebula. Check live acceptance records
before treating an installation as available.

Development acceptance on 2026-09-11 verified the live browser home/block detail,
API head matching Besu at block 76, indexing complete, WebSocket subscription,
same-origin validator RPC, and a controlled API restart retaining indexed data.
See `../../docs/explorer-nebula-acceptance.json`. This does not imply production
approval or completion of the later features below.

## Source and configuration history

Frontend source: cryft-labs/dakota-explorer review/nebula-development-deployment,
revision ca603ae5656665ce9a1b21da0a5f47aaf033cb70. Backend source: official
blockscout/blockscout v11.3.0, revision 43af7ea84797e2f3a55ac1191d9cbe67436eb3e8.
The public backend `latest` image inspected during deployment was older than this
release, so both application images are built from pinned source revisions.

The earlier **Blockscout Deployment Setup** conversation
(`6a37f161-6a50-83ea-99b1-a84d0afb0045`) supplied the previous deployment settings.
The later user request in turn `4a004b91-232f-4702-ab4d-26fdf6f8ed13` changed the
currency display from ETH to **KOTA / Dakota Coin**, retaining chain ID 112311
and 18 decimals. This is presentation metadata and does not change genesis balances.
Horizontal navigation, hidden market prices, no ads/marketplace, gas tracking,
advanced filters and no public Helia peer fetching are carried forward.

The previous browser contract-read fixes used a same-origin `/api/eth-rpc` route
with `/rpc` as an alias. Both now route to the localhost Nginx archive endpoint
on Frontend-01. Old public rpc1/rpc2 endpoints and the previous 100.111.4.2 backend
are not used by this deployment. App/API URLs now share the Nebula entry point.
Development remains visibly marked as a test network until production approval.
Reown project credentials/origin registration and account login are not configured;
MetaMask add-network support alone does not enable the complete wallet-write UI.

## Persistent services and ports

| Host | Service | Exposure | Initial memory/CPU ceiling |
| --- | --- | --- | --- |
| Frontend-01 | cryft-explorer-frontend | 127.0.0.1:3001 | 4 GiB / 2 CPUs |
| Frontend-01 | cryft-nginx | Nebula and localhost :8080 | shared 512 MiB / 2 CPUs |
| Backend-01 | cryft-explorer-api | 127.0.0.1:4000 | 8 GiB / 3 CPUs |
| Backend-01 | cryft-nginx | Nebula and localhost :4002 | shared 512 MiB / 2 CPUs |
| Backend-01 | cryft-explorer-db | isolated container network :5432 | 6 GiB / 2 CPUs |
| Backend-01 | cryft-explorer-redis | isolated container network :6379 | 512 MiB / 0.5 CPU |

All containers run rootless under the non-login `cryft-explorer` host account;
applications use non-root container users. System services start at boot with
user lingering enabled, restart on failure, and stop gracefully. Container
capabilities are dropped, privilege gain is disabled, and systemd bounds resources.
Host-side Podman must retain access to its subordinate UID/GID mapping helpers;
`NoNewPrivileges` therefore applies inside containers rather than to the Podman
launcher. Existing Besu/IPFS services and archive Nginx listeners are preserved.

Nginx provides request/connection limits and Nebula source restrictions. The
backend allows Frontend-01 and the operator workstation, while the browser only
needs access to Frontend-01:8080. Raw origins have no public/Nebula listeners.
Defined Networking must permit those flows. `/node-api` remains owned by Next.js.

## Install and operate

Commit and push the exact review revisions before applying them. Run
`prepare-build.py --commit <network-review-sha> --host <host> --frontend-commit
<frontend-review-sha>` as root once per host. Monitor `cryft-explorer-build` and
require a successful exit plus the image ID file under `/var/lib/cryft-explorer`.
Then run `install-runtime.py --commit <network-review-sha> --host <host>` alongside
the same release's `prepare-build.py`. It verifies source, installs runtime units,
precreates a limited database role, runs migrations and tests/reloads Nginx.

Public settings live in `frontend.env` and `backend.env`; install copies are under
`/etc/cryft/explorer`. Backend-only secrets are generated once locally in a root-only
`secrets.json`; protected env files supply only the credentials each container
needs. Never print, commit or copy these into frontend public variables.
The application database role is not a superuser and cannot create roles/databases.

Data is under `/var/lib/cryft-explorer/{postgres,redis,dets}`. Container rebuilds and
restarts preserve these directories. Do not delete volumes or run initialization
against existing data to resolve a failure. Migration changes require a database
backup and a reviewed compatibility/rollback plan. Use PostgreSQL logical backups
and test recovery before production; no off-host backup policy is implied here.

Inspect `systemctl status <service>` and `journalctl -u <service>` as an operator.
Use `systemctl restart` for a controlled restart. Routine reboot persistence is
configured; a full host reboot acceptance test remains a separate deployment gate.
The receipt `/etc/cryft/explorer/installation.json` records source/image identities.

## Acceptance and later features

Verify `/api/v2/stats`, latest blocks, a block detail, WebSocket subscriptions,
`/api/eth-rpc` chain ID and validator reads through the browser entry point. Inspect
the rendered UI, runtime public environment and service users/listeners. Confirm
the indexed head catches up to Besu and that an API restart preserves indexed data.

Charts/stats microservice, self-hosted compiler verification, account authentication,
Reown wallet writes, public Cloudflare hostnames and genesis allocation import are
separate features. They must not be reported as enabled merely because the explorer
home page is reachable. The existing 1.25 GB genesis must not be blindly loaded into
the indexer as a small chain-spec configuration file.
