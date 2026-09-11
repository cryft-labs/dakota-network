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
