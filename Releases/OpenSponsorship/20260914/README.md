# Open sponsorship restoration

Restore GasSponsor 1.1.0 at the existing FEeD proxy using
[`restore_open.py`](../../../Tools/ApprovedSponsorship/restore_open.py).
The default command is read-only; `--execute` applies one governed proxy upgrade
from a clean pushed review branch. It never reinitializes or moves Account funds.

The exact implementation is `0x83AaF0a9d4FE1748e1fCFFd5a3adfd60a16E86dF`.
Use [the original release](../../TenantAllowances/1.0.0) for Apache-2.0 source,
Standard JSON and metadata. No compilation or fresh implementation deployment is needed.
The earlier 1.2.0 allowlist release is historical, with its storage left unused.
Activation is recorded in `deployment.json` after receipt and state verification.

Retained security: signed execution and vouchers; nonce/operation replay checks;
authorized relayers; enabled switches; bounded execution; tenant/wallet/tier spending
limits; optional allowance settlement; and restricted gas reimbursement custody.
Independent registries do not populate the official c0DE registry. Hosted Dakota
redemption and its registration fee remain unchanged. Open calls still need an
authorized voucher; this is not a permissionless signing API.

Tests use the exact original bytecode in an isolated EVM, including transition from
1.2.0, independent contracts, invalid envelopes, replay protection, spending policy,
gas custody and canonical registration fees. See `Tests/Readiness/test_open_sponsorship.py`.
