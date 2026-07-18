# Dakota Native Gas Sponsorship

This is the initial deployment of the native EIP-7702 delegation and gas
sponsorship stack. It does not use ERC-4337, a bundler, an EntryPoint, or a
paymaster.

## Fixed Dakota Addresses

| Purpose | Address |
| --- | --- |
| Chain ID | `112311` |
| Validator/root registry | `0x0000000000000000000000000000000000001111` |
| ProxyAdmin | `0x0000000000000000000000000000000000FacAdE` |
| EIP-7702 delegation entry | `0x00000000000000000000000000000000de1E6A7E` |
| GasSponsor proxy | `0x000000000000000000000000000000000000FEeD` |
| Retained root overlord | `0x2B7361056b31D2bf201E6764e7825fd31c0D223A` |

The retained root is already recognized by both genesis proxies as an
overlord and guardian. Do not call `proxy_addOverlord(root)`, and do not
revoke the root for this deployment.

## Initial-Release Semantics

Neither genesis proxy has ever had an implementation. Before deployment,
confirm that both report `proxy_getIsInit() == false` and have a zero EIP-1967
implementation slot.

`GasSponsor` therefore uses `initialize(...)` with the `initializer` guard.
There is no prior implementation state to migrate and no reinitializer to
call. The implementation constructor disables initialization on the logic
contract itself.

Proxy state is still collision-sensitive. The custom genesis proxy stores its
governance state in namespaced slots and its implementation in the EIP-1967
slot. `GasSponsor` keeps sponsorship state under
`erc7201:dakota.storage.GasSponsor`, while `DakotaDelegation` keeps each
user's nonce and reentrancy state under
`erc7201:dakota.storage.DakotaDelegation`.

## Delegation Route

```text
user EOA
  -> EIP-7702 indicator: 0xef0100 || 0x...de1E6A7E
  -> genesis proxy code executing in the user account context
  -> user EIP-1967 implementation slot
  -> DakotaDelegationBeaconDispatcher
  -> DakotaDelegationBeacon
  -> DakotaDelegation
```

The dispatcher is immutable and stateless. Normal delegation upgrades use
`DakotaDelegationBeacon.upgradeTo(newImplementation)`. ProxyAdmin is reserved
for replacing an individual account's dispatcher if recovery is ever needed.

## Build Gate

Compile the deployment set with Solidity `0.8.34`, Osaka, optimizer enabled,
and `200` runs. Run:

```bash
python Tools/SolcCompiler/check_gas_sponsor.py
```

The gate verifies initial-release naming, `initializer` semantics, ERC-7201
namespace constants, linear storage, removed prototype selectors, proxy
selector collisions, the stateless dispatcher ABI, and runtime size.

Archive the exact compiler Standard JSON input used for deployment. Verify
contracts from that input rather than flattened source.

## Deployment Variables

Record these values before broadcasting:

```text
ROOT
PLATFORM_ADMIN
VOUCHER_SIGNER
RELAYER
DAKOTA_DELEGATION_IMPLEMENTATION
DAKOTA_DELEGATION_BEACON
DAKOTA_DELEGATION_DISPATCHER
GAS_SPONSOR_IMPLEMENTATION
```

The root may temporarily be the platform admin during a dev canary. Use a
separate voucher signer and relayer in production.

## Contract Deployment Order

1. Deploy `DakotaDelegation()`.
2. Deploy `DakotaDelegationBeacon(delegationImplementation, ROOT)`.
3. Deploy `DakotaDelegationBeaconDispatcher(beacon)`.
4. Deploy `GasSponsor()`.
5. Verify all four deployments with their exact Standard JSON input.

Confirm:

- Beacon `owner() == ROOT`.
- Beacon `implementation() == delegationImplementation`.
- Dispatcher construction succeeds against that beacon.
- Direct calls to `DakotaDelegation.executeSponsored(...)` revert.
- Direct calls to `GasSponsor.initialize(...)` revert.

Do not call `renounceOwnership()` on the beacon.

## First-Link GasSponsor

Encode:

```solidity
GasSponsor.initialize(
    PLATFORM_ADMIN,
    VOUCHER_SIGNER,
    0x00000000000000000000000000000000de1E6A7E,
    100000
)
```

The initial `100000` overhead value is inside the accepted
`50,000-500,000` range. Recalibrate it from measured canary transactions
before setting production limits.

From `ROOT`, call the GasSponsor proxy at `0x...FEeD`:

```solidity
proxy_linkLogicAdmin(
    GAS_SPONSOR_IMPLEMENTATION,
    INITIALIZE_CALLDATA
)
```

This must be the first link. Do not use `ProxyAdmin.upgrade(...)` for the
initial link because that would not set the custom genesis initialization
flag.

Confirm:

- `proxy_getIsInit() == true`
- EIP-1967 implementation equals `GAS_SPONSOR_IMPLEMENTATION`
- `implementationVersion() == "1.0.0"`
- `approvedDelegate() == 0x...de1E6A7E`
- `platformAdmin() == PLATFORM_ADMIN`
- `voucherSigner() == VOUCHER_SIGNER`
- `fixedOverheadGas() == 100000`
- `paused() == true`

## User Onboarding

The user signs an EIP-7702 authorization scoped to:

```text
chainId = 112311
contractAddress = 0x00000000000000000000000000000000de1E6A7E
nonce = current user account nonce
executor = omitted because another account submits the transaction
```

`ROOT` submits the type-4 transaction with the authorization list. The
transaction destination is the user account and its calldata is:

```solidity
proxy_linkLogicAdmin(DAKOTA_DELEGATION_DISPATCHER, hex"")
```

Do not request or transmit the user's private key. Only the signed
authorization is provided to the submitting service.

Confirm:

- Account code is `0xef0100 || 0x...de1E6A7E`.
- `proxy_getIsInit() == true`.
- Account EIP-1967 implementation equals the dispatcher.
- `proxy_isOverlord(ROOT) == true`.
- `proxy_isGuardian(ROOT) == true`.
- `proxy_isRootOverlordRevoked() == false`.
- `delegationProtocolId()` matches the initial protocol ID.
- `implementationVersion() == "1.0.0"`.
- `GasSponsor.isDelegationReady(account) == true`.

An accepted EIP-7702 authorization can remain applied even if transaction
execution reverts. Inspect the account code, implementation slot, proxy
initialization flag, and nonce before asking for another authorization.

## Sponsor Configuration

Use a stable tenant-owned address, normally its tenant registry, as
`SPONSOR`. Use `keccak256(bytes(canonicalTenantId))` consistently for the
`bytes32` tenant ID.

Platform admin:

```solidity
configureSponsor(
    SPONSOR,
    TENANT_ID_HASH,
    TENANT_MANAGER,
    ADMIN_MAX_COST_PER_OPERATION,
    ADMIN_DAILY_LIMIT,
    true
)

setRelayer(RELAYER, true)
depositFor{value: AMOUNT}(SPONSOR)
```

Tenant manager:

```solidity
setTenantLimits(
    SPONSOR,
    TENANT_MAX_COST_PER_OPERATION,
    TENANT_DAILY_LIMIT
)
setTenantEnabled(SPONSOR, true)
```

Keep global sponsorship paused during setup and off-chain simulation.

## Sponsored Execution

The user signs `SponsoredExecutionRequest` using:

```text
EIP-712 name = DakotaDelegation
EIP-712 version = 1
chainId = 112311
verifyingContract = user account
executor = 0x...FEeD
nonce = DakotaDelegation.getNonce()
```

Encode the signed request as:

```solidity
DakotaDelegation.executeSponsored(request, ownerSignature)
```

That complete calldata is `executionData`.

The platform signs `SponsorshipVoucher` using:

```text
EIP-712 name = DakotaGasSponsor
EIP-712 version = 1
chainId = 112311
verifyingContract = 0x...FEeD
delegate = 0x...de1E6A7E
executionHash = keccak256(executionData)
relayer = RELAYER
```

The gas envelope must satisfy:

```text
callGasLimit >= request.executionGasLimit + 100000
maxCost = (callGasLimit + fixedOverheadGas) * maxFeePerGas
```

The relayer calls:

```solidity
GasSponsor.executeSponsored(
    voucher,
    executionData,
    voucherSignature
)
```

## Funded Canary

1. Use one allowlisted relayer.
2. Use one low-balance sponsor.
3. Use one known delegated dev account.
4. Use one harmless target call.
5. Simulate the exact relayer transaction.
6. Call `setPaused(false)` immediately before submission.
7. Submit the transaction.
8. Verify operation events, reimbursement, sponsor balance, daily spend,
   user nonce, return-data hash, and target state.
9. Call `setPaused(true)` immediately if any assertion fails.

Failed user execution still reimburses the relayer within the signed cap and
consumes the operation ID. Never reuse an operation ID.

## Upgrade Procedures

Delegation:

1. Call `GasSponsor.setPaused(true)`.
2. Deploy and verify the compatible new delegation implementation.
3. Confirm the ERC-7201 namespace, signature domain, and selector gates.
4. `ROOT` calls `DakotaDelegationBeacon.upgradeTo(newImplementation)`.
5. Smoke an existing delegated account and confirm nonce preservation.
6. Call `GasSponsor.setPaused(false)` only after verification.

GasSponsor:

1. Keep sponsorship paused.
2. Deploy and verify a storage-compatible implementation.
3. With no migration, `ROOT` calls
   `ProxyAdmin.upgrade(GAS_SPONSOR_PROXY, newImplementation)`.
4. With a later reinitializer, `ROOT` calls
   `ProxyAdmin.upgradeAndCall(GAS_SPONSOR_PROXY, newImplementation, data)`.

The first deployed implementation uses `initialize(...)`. Only a future
implementation that adds migration state should introduce a numbered
reinitializer.

## Abort Conditions

Stop before broadcasting if:

- Either genesis proxy is already initialized or has a nonzero implementation.
- The validator registry no longer identifies `ROOT` as root overlord.
- Either proxy reports `ROOT` is not an overlord or guardian.
- The root-revoked flag is true.
- Deployment bytecode differs from the archived compiler artifact.
- Beacon owner or implementation is incorrect.
- Any post-link getter differs from its encoded initialization value.
- `isDelegationReady(account)` is false.
- A canary simulation differs from the transaction that will be submitted.
