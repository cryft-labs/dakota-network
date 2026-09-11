# Isolated Besu / Paladin compatibility test

This directory prepares an isolated development chain on Paladin-01. It does not
start the Dakota genesis, use its validator identities, or use funded owner keys.
The test copies chain settings from the existing genesis, including chain ID
112311, fork schedule, QBFT timing/rewards/contract-validator mode, gas limit and
32 KiB contract-size limit. The removed Besu `xemptyBlockPeriodSeconds` alias is
normalized to `emptyBlockPeriodSeconds` with the same value. Four isolated test
validators are used. Test allocations/keys are recorded separately; this is not
the production genesis deployment. All endpoints and P2P bind to loopback. Containers
run under an unprivileged host account and systemd supervision, using immutable
image digests. MetaTx is disabled throughout this test.

The owner requested execution evidence for private delegation before choosing any
fallback. Test these distinct paths and record receipts, not just accepted input:

1. Public EIP-7702 authorization and subsequent delegated execution on Besu.
2. Pente private DELEGATECALL with caller/storage semantics preserved.
3. Native authorization-list processing and account-code resolution inside Pente.
   Unknown fields being ignored, or a no-code call succeeding, is not a pass.
4. A prepared, endorsed private transition settled by a separate gas payer,
   including sponsorship through the public delegated account where applicable.
5. Replays, unauthorized execution, state rollback and final private receipt.

Runtime pins are in `runtime-lock.json`. Public Besu and the Pente embedded EVM
are separate components. The stable release source selects Shanghai for Pente;
the executable test determines the actual supported path. Compiling newer EVM
bytecode does not by itself add transaction-envelope support.

`bootstrap-test-host.sh` installs the rootless container prerequisites and creates
the isolated runtime user/directories. Run only on an authorized test host as root.
No private credentials belong in Git. Generate ephemeral test identities locally
in an ignored directory and transfer over the existing pinned SSH connection.

Status: harness preparation. No live test result is asserted by this README.
