# Backend-01 IPFS deployment candidate

These files are local review candidates, not an installed service. Apply the
approved committed infrastructure release after Nebula/operator access is ready.
The user selected Nebula-only IPFS peers and a public Cloudflare HTTP gateway.
Do not change that policy merely because Kubo supports hole punching.

## Layout and access

| Component | Identity | Listener/access |
|---|---|---|
| Kubo v0.43.0 | `cryft-ipfs` | API `127.0.0.1:5001`; read-only local gateway `127.0.0.1:8081` |
| IPFS peer transport | `cryft-ipfs` | Backend Nebula `100.111.67.1:4001` TCP/QUIC; explicit Nebula peers only |
| Nginx | `cryft-proxy`, master and workers | Private publishing `100.111.67.1:8444` with publisher mTLS; gateway `127.0.0.1:8080` |
| Named Cloudflare Tunnel on Backend-01 | `cryft-tunnel` | Outbound tunnel; dedicated gateway hostname -> local Nginx |

The gateway hostname is still required. Give it a separate hostname from Kota,
moment.cards and login/admin sites. Only `/ipfs/` GET/HEAD routes are public.
Publishing exposes only `add`, `cat` and `pin/ls` through a separate private server
with a dedicated publisher client CA. Clients require the server CA and their
own certificate/key; the server certificate must include `100.111.67.1` as an IP
SAN. Add authorized compiler hosts deliberately to the Nebula/firewall allowlist.
Never tunnel the publishing port or the raw Kubo API.

`configure.py` disables bootstrap, mDNS, routing/provider announcements, relays,
hole punching, port mapping and fetching missing content through the public
gateway. It preserves the existing node identity and adds filters allowing only
loopback and the configured Nebula CIDR. Add actual peer IDs and their Nebula
multiaddresses through `--peers-file`; no peer IDs are invented. A single node
with no peer entries can still pin files and serve them through its HTTP gateway.
This is network isolation, not an IPFS swarm-key encryption deployment.

Our gateway can serve `/ipfs/<CID>`. Other gateways are not automatically able to
discover this isolated node. Source verification tooling may need our explicit
gateway URL or the standard JSON export. A Cloudflare HTTP tunnel is not an IPFS
DHT registration or a public swarm transport. See [Kubo configuration](https://github.com/ipfs/kubo/blob/v0.43.0/docs/config.md).

## Installation sequence after release approval

1. Confirm Backend-01 identity, Nebula `100.111.67.1`, storage and current services.
   Select the gateway hostname, configure DNS/named tunnel and issue publisher
   mTLS credentials through the protected workflow. Keep private keys out of Git.
2. Pin the selected binaries. The official Kubo v0.43.0 Linux amd64 release archive
   SHA-256 is `2ccb2c16c4ed0c893858dc6ac8a062d789e36a03339a7164459a917b64354c3d`.
   Obtain it from the [official release](https://github.com/ipfs/kubo/releases/tag/v0.43.0),
   verify the hash, and install root-owned under `/opt/cryft/ipfs/v0.43.0` with a
   root-controlled `/opt/cryft/ipfs/current` symlink. Record Nginx/cloudflared
   versions and hashes as well; their versions remain release selections.
3. Create non-login `cryft-ipfs`, `cryft-proxy` and `cryft-tunnel` accounts. Create
   `/var/lib/cryft-ipfs` mode 0700 owned by `cryft-ipfs`. Initialize with
   `IPFS_PATH=/var/lib/cryft-ipfs ipfs init --profile=server` **as that user only if
   no config exists**. Never regenerate an existing identity on a rerun.
4. With Kubo stopped, run the approved `configure.py --repo /var/lib/cryft-ipfs`
   as `cryft-ipfs`. Review the peer policy without printing `Identity.PrivKey`.
   The initial storage target is 50 GB, CPU budget two cores and memory cap 2 GiB;
   reconcile with API/database/indexer budgets before installation. Pinned content
   is not reclaimed by GC: StorageMax is not a hard disk quota. Monitor growth and
   host headroom, and expand capacity before pins exhaust the shared disk.
5. Install the service/configuration files as root-owned, runtime-read-only files.
   Merge the Nginx template into the approved backend proxy configuration. Replace
   only `${IPFS_PUBLIC_GATEWAY_HOSTNAME}` and `${IPFS_CLOUDFLARE_TUNNEL_ID}` in their
   intended templates; never evaluate them as shell code or substitute Nginx's
   own `$variables`. Keep credential files readable only by their service.
6. Enforce Kubo outbound/inbound peer filtering by service identity to loopback and
   `100.111.0.0/16`. The unit's `IPAddressDeny`/`IPAddressAllow` rules require working
   cgroup/BPF support; verify effective enforcement and equivalent host firewall
   rules. Do not apply Kubo's egress restrictions to the separate cloudflared unit.
   Allow private publishing only from selected Nebula compiler identities/IPs;
   block public 4001, 5001, 8080, 8081 and 8444, including IPv6.
7. Validate units against the installed systemd, and Nginx configuration as the
   proxy user with its runtime directories prepared. Enable `cryft-ipfs.service`,
   `cryft-nginx.service` and `cryft-ipfs-tunnel.service` after rendering secrets and
   host configuration. Disable any conflicting default root-master Nginx unit
   through a coordinated switch that preserves existing services.
8. Verify actual process UIDs, persistence after reboot, peer address restrictions,
   publisher mTLS acceptance/rejection, API command restrictions, and denial of
   direct origin/public API access. Publish a disposable test file, confirm its
   pin and bytes, then retrieve it through the public tunnel URL. Verify POST is
   rejected at the gateway and unpinned/unavailable content is not fetched.

The templates require Linux validation during deployment; local Windows Kubo tests
do not establish Linux service, Nginx, TLS, Nebula or Cloudflare readiness.

## Maintenance and recovery

Use systemd start/stop/status/reload operations and journal logs for the recorded
unit names. Collect private health/pin/disk metrics without making the full RPC
API public. Kubo upgrades require compatibility checks and an offline recoverable
repository backup; `--migrate=false` prevents unreviewed automatic migrations.

Back up the pin inventory, release bundles, configuration and repository to an
encrypted off-host target; the repo configuration contains the node's private
identity. Document a consistent stopped-node or supported snapshot backup method.
Never run two nodes with a restored copy of the same identity. A future secondary
Nebula IPFS node needs its own identity and independent verified pins. The compiler
currently confirms pins on one configured backend, not redundant availability.
Restore exercises must retrieve every required CID. Never prune compiler pins
automatically merely because a newer release exists.
