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
