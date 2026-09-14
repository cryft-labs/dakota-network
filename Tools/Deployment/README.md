# Deployment phase scripts

Run only from a committed, remote-verified review release. Root bootstrap installs
the vendor-packaged persistent DNClient service using its signed APT repository.
This networking daemon needs tunnel privileges; application services use separate
unprivileged users. Existing installations are preserved. The enrollment helper
accepts a JSON object on SSH stdin containing `code` and `nebula_ip`; neither secret
nor state is committed. It skips an already assigned address and redacts the code
from CLI output. Confirm the assigned IP and a new SSH session over Nebula before
closing public SSH. These scripts do not change SSH/firewall rules.

Vendor procedure: [Defined Networking server installation](https://docs.defined.net/get-started/dnclient-server/install/).
Record actual installed package version, service status and connectivity in the
deployment inventory. The full platform sequence is in `docs/ONE_SHOT_DEPLOYMENT.md`.

`stage-genesis.py --commit <full-review-commit> --archive-sha256 <digest>
--genesis-sha256 <digest>` pulls the exact release into `/opt/cryft/releases/`,
verifies the compressed archive against independent supplied hashes and its manifest,
extracts only BesuGenesis.json and atomically installs the verified file at
`/etc/cryft/besu/BesuGenesis.json`. Run it on every node. It preserves an identical
existing genesis and refuses a different one; it never resets chain data or starts
a node. Runtime units must explicitly use this installed genesis path.

The optional `--allow-compatible-bpo-update` flag permits **only** the reviewed
2026-09-11 transition from the exact BPO2 genesis hash in the helper to the BPO5
archive. The local Besu service must be stopped. The helper verifies the entire
candidate equals the old genesis after removing the three BPO timestamp fields,
keeps a hash-named backup, and preserves all chain data and keys. Stage the pinned
release first; update the archive and Paladin-connected Besu before restarting
one validator at a time. After each restart, check `[BPO5:0]`, the unchanged genesis
block hash, four-validator list, peer connectivity and synchronization. Retain
three healthy validators throughout. Record the new genesis receipt separately
from the historical runtime installation receipt. If a check fails, stop the
rollout and restore the retained prior genesis for that host. Never use this flag
for Amsterdam, blob-limit changes, allocations, bytecodes or storage changes.

For an explicit address/enrollment replacement, send `replace_existing: true` to
the enrollment helper over pinned bootstrap SSH. It enrolls in place, restarts the
client on success, and reports the assigned address. Verify a new private SSH
session. Never treat a submitted code as proof of connectivity.

`install-besu.py --commit <full-review-commit> --host <inventory-host>` verifies
the already pulled release and genesis, installs SHA-pinned Besu 26.8.1 with
Java 25, and creates `cryft-besu.service` under the non-login `cryft-besu` user.
It enables the service but leaves startup to the operator's acceptance sequence.
Validator keys must be securely staged at `/root/cryft-bootstrap/validator-node.key`
as a root-only file using the existing encrypted identity inventory. The installer
checks the derived address against `validator-peers.json`, never replaces an
existing key, and removes that exact staging file after installation.
Non-validator Besu peers receive a persistent new node identity.

All six Besu hosts use `/etc/cryft/besu/BesuGenesis.json`, private keys in
`/etc/cryft/besu/node.key` (root:cryft-besu, 0640), root-owned configuration and
`/var/lib/cryft/besu` for writable data. P2P listens and advertises only the host's
Nebula IP on TCP 30303, using the four static validator peers with discovery/NAT
disabled. HTTP/WS/metrics listen only on 127.0.0.1 at 8545/8546/9545; Nginx ingress
is a separate stage. Backend-01 does not run Besu in this host-role assignment.

Frontend-01 uses FOREST/FULL for archival state; the other five use BONSAI/FULL.
No archive history pruning is enabled. Initial JVM heaps are 8 GiB for the archive
and 6 GiB elsewhere, with systemd memory ceilings of 16/12 GiB and six CPU cores of
quota on the eight-vCPU hosts. These are initial capacity budgets to measure under
real workloads. Validate genesis/validator identities, private-only listeners,
peer mesh, block progression, archive queries and reboot recovery before application
transactions. Record `/etc/cryft/besu/runtime-installation.json` and actual live
acceptance separately; an installed/enabled service is not proof of a running chain.

`install-nginx.py --commit <full-review-commit> --host Frontend-01` installs the
unprivileged `cryft-nginx.service`. Both master and workers run as `cryft-proxy`.
It prevents the distribution's default service from opening public port 80.
Archive HTTP uses `http://100.111.69.1:8547/`; WebSocket uses
`ws://100.111.69.1:8547/ws`. Nginx forwards to Besu on localhost, allows the listed
operator/backend/Paladin sources, applies request and connection limits, and never
retries a submitted transaction automatically. This is a private Nebula ingress,
not a public Cloudflare target. Record real HTTP/WS, denial and runtime UID checks.
The raw RPC ports 8545/8546 and metrics 9545 remain loopback-only. The explorer
browser URL is a separate frontend service at Nebula port 8080.

Browser wallet RPC requests also require CORS on this proxy. The review template
permits exact HTTP origins for moment.cards, the widget and dashboard on ports
3033, 3034 and 3035 at localhost, 127.0.0.1 and 100.111.1.4. POST responses include
the matching origin; OPTIONS preflight returns 204. Unknown browser origins get
403, while server clients without an Origin header continue to work. No cookies
or credentials are required for this private RPC. WebSocket browser origins use
the same list. Production HTTPS origins must be explicitly added before launch.

The source-IP list is enforced with `geo` before any early preflight response;
it includes the existing service/operator addresses and the external operator
computer at 100.111.1.3. CORS approval does not admit a new Nebula peer. An external
operator computer that calls this RPC directly must
also have its exact Nebula IP approved here and in Defined Networking. Do not
expand the source list or Windows firewall to diagnose a browser-origin error.
The dashboard's Kota API calls use its same-origin `/api/platform` adapter, with
the local review Router at 127.0.0.1:4251; external clients do not use that port.

For verification, send OPTIONS with Origin `http://100.111.1.4:3035`, requested
method POST and requested header Content-Type, then a read-only `eth_chainId`
POST with the same origin. Expect 204 and 200 respectively, matching origin
headers and chain 112311. Confirm an unapproved origin returns 403, GET returns
405, and both POST and OPTIONS from an unapproved source return 403. Validate the
candidate with `nginx -t` as `cryft-proxy`, save the current config, reload
`cryft-nginx.service` gracefully and verify its active state. Keep the previous
config for rollback; do not restart Besu or alter genesis for a CORS change.

`install-ipfs.py --commit <full-review-commit>` installs and starts Backend-01's
SHA-pinned Kubo service under `cryft-ipfs`, preserving the node identity and actual
peer list. It uses the reviewed IPFS configuration/service templates and does not
publish a Cloudflare gateway or expose the raw API. Record compiler publication,
TLS gateway configuration and public gateway acceptance as subsequent stages.
