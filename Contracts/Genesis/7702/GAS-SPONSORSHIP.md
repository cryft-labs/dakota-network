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

`DakotaDelegationRegistry` and `GasSponsor` therefore use `initialize(...)`
with the `initializer` guard. There is no prior implementation state to
migrate and no reinitializer to call. Both implementation constructors
disable initialization on the logic contracts themselves.

Proxy state is still collision-sensitive. The custom genesis proxy stores its
governance state in namespaced slots and its implementation in the EIP-1967
slot. `DakotaDelegationRegistry` keeps the fixed entry's directory and
release state under `erc7201:dakota.storage.DakotaDelegationRegistry`,
`GasSponsor` keeps sponsorship state under
`erc7201:dakota.storage.GasSponsor`, and `DakotaDelegation` keeps each user's
nonce and reentrancy state under
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

The dispatcher is immutable and stateless. At its own address, the fixed
`0x...de1E6A7E` genesis proxy is first-linked to
`DakotaDelegationRegistry`. Direct calls to the fixed address therefore expose
the shared control plane: current components, verified release history,
capabilities, and delegated-account readiness.

The fixed entry owns the beacon after deployment. Registry calls validate the
implementation code hash, protocol ID, required capabilities, and interfaces,
then update the beacon and record the release atomically. ProxyAdmin upgrades
the registry implementation itself. Each authorized user account has separate
proxy storage and independently links `DakotaDelegationBeaconDispatcher`, so
linking the fixed entry to the registry does not route user execution through
the registry.

## Build Gate

Compile the deployment set with Solidity `0.8.34`, Osaka, optimizer enabled,
and `200` runs. Run:

```bash
python Tools/SolcCompiler/check_gas_sponsor.py
```

The gate verifies initial-release naming, both fixed-proxy initializers,
ERC-7201 namespace constants, linear storage, removed prototype selectors,
proxy selector collisions, delegation introspection, the registry surface,
the stateless dispatcher ABI, and runtime size.

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
DAKOTA_DELEGATION_REGISTRY_IMPLEMENTATION
GAS_SPONSOR_IMPLEMENTATION
```

The root may temporarily be the platform admin during a dev canary. Use a
separate voucher signer and relayer in production.

## Contract Deployment Order

1. Deploy `DakotaDelegation()` version `1.1.0`.
2. From `ROOT`, deploy
   `DakotaDelegationBeacon(delegationImplementation)`. The constructor
   resolves deployment authority from the validator/root registry at
   `0x...1111`; there is no caller-supplied owner argument.
3. Deploy `DakotaDelegationBeaconDispatcher(beacon)`.
4. Deploy `DakotaDelegationRegistry()`.
5. Deploy `GasSponsor()`.
6. Verify all five deployments with their exact Standard JSON input.

Confirm:

- Beacon `implementation() == delegationImplementation`.
- Beacon `owner() == ROOT`.
- Beacon `validatorRootRegistry() == 0x...1111`.
- Dispatcher construction succeeds against that beacon.
- Direct calls to `DakotaDelegation.executeSponsored(...)` revert.
- Direct calls to `DakotaDelegationRegistry.initialize(...)` revert.
- Direct calls to `GasSponsor.initialize(...)` revert.

## First-Link Delegation Control Plane

Encode:

```solidity
DakotaDelegationRegistry.initialize(
    DAKOTA_DELEGATION_DISPATCHER,
    DAKOTA_DELEGATION_BEACON,
    0x000000000000000000000000000000000000FEeD
)
```

From `ROOT`, call the fixed delegation proxy at `0x...de1E6A7E`:

```solidity
proxy_linkLogicAdmin(
    DAKOTA_DELEGATION_REGISTRY_IMPLEMENTATION,
    REGISTRY_INITIALIZE_CALLDATA
)
```

`ROOT` is not encoded in the initializer. The fixed proxy and registry both
resolve the authorized caller from the validator/root registry at `0x...1111`.

This must be the fixed entry's first link. Do not use
`ProxyAdmin.upgrade(...)` for the initial link because that would not set the
custom genesis initialization flag.

After the first link, transfer the beacon to the fixed entry:

```solidity
DakotaDelegationBeacon.transferOwnership(
    0x00000000000000000000000000000000de1E6A7E
)
```

Confirm by calling the registry ABI at `0x...de1E6A7E`:

- `proxy_getIsInit() == true`
- EIP-1967 implementation equals
  `DAKOTA_DELEGATION_REGISTRY_IMPLEMENTATION`
- `registryVersion() == "1.0.0"`
- `registryAdmin() == ROOT`
- `validatorRootRegistry() == 0x...1111`
- `delegationEntry() == 0x...de1E6A7E`
- `beacon() == DAKOTA_DELEGATION_BEACON`
- `dispatcher() == DAKOTA_DELEGATION_DISPATCHER`
- Beacon `owner() == 0x...de1E6A7E`
- `releaseCount() == 1`
- `currentRelease().implementation == DAKOTA_DELEGATION_IMPLEMENTATION`
- `currentSnapshot().implementationCompatible == true`
- `currentSnapshot().registryControlsBeacon == true`

Do not call the beacon's `upgradeTo(...)` directly after ownership transfer.
All normal delegation upgrades must call `upgradeDelegation(...)` at
`0x...de1E6A7E`.

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
- `implementationVersion() == "1.1.0"`.
- `delegationCapabilities()` contains every required capability bit.
- `supportsInterface(type(IDakotaDelegation).interfaceId) == true`.
- `GasSponsor.isDelegationReady(account) == true`.
- `IDakotaDelegationRegistry(0x...de1E6A7E).isAccountReady(account) ==
  true`.

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
```

Platform allocations come from the voter-governed GasManager at `0x...caFE`:

```solidity
(bytes32 fundKey, ) = proposeSponsorFunding(
    FUNDING_ID,
    SPONSOR,
    AMOUNT,
    NOTE
);

// Each remaining voter calls this with the same fundKey.
voteToFundGasV2(fundKey);

// After approval, a GasManager guardian or SPONSOR executes it.
executeSponsorFunding(fundKey);
```

The proposer casts the first vote automatically. `caFE` binds `SPONSOR` before
voting starts and calls `FEeD.depositFor{value: AMOUNT}(SPONSOR)` only after the
proposal is approved. The generic `executeFundGasV2` path rejects these
sponsor-bound proposals. Tenants may still self-fund an already configured
ledger by calling `FEeD.depositFor{value: AMOUNT}(SPONSOR)` directly.

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
3. Confirm the ERC-7201 namespace, signature domain, selector gates,
   protocol ID, capability bitmap, and ERC-165 interface support.
4. Compute `EXPECTED_RUNTIME_CODE_HASH = extcodehash(newImplementation)` and
   compare it to the archived deployment artifact.
5. `ROOT` calls:

   ```solidity
   IDakotaDelegationRegistry(
       0x00000000000000000000000000000000de1E6A7E
   ).upgradeDelegation(
       newImplementation,
       EXPECTED_RUNTIME_CODE_HASH
   )
   ```

6. Confirm the new release record and registry snapshot.
7. Smoke an existing delegated account and confirm nonce preservation.
8. Call `GasSponsor.setPaused(false)` only after verification.

Delegation control plane:

1. Keep sponsorship paused.
2. Deploy and verify a registry implementation that preserves the
   `Initializable` linear prefix and
   `erc7201:dakota.storage.DakotaDelegationRegistry`.
3. With no migration, the fixed ProxyAdmin calls
   `upgrade(0x...de1E6A7E, newRegistryImplementation)`.
4. If a future release adds state that requires migration, use
   `upgradeAndCall(0x...de1E6A7E, newRegistryImplementation, data)` with a
   numbered reinitializer introduced only in that future implementation.
5. Confirm the registry implementation and version changed while the admin,
   component bindings, release history, and beacon ownership remained intact.

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
- Beacon implementation is incorrect.
- Beacon owner is not `0x...de1E6A7E`.
- Registry snapshot compatibility, control, or release-match flags are false.
- Any post-link getter differs from its encoded initialization value.
- `isDelegationReady(account)` is false.
- A canary simulation differs from the transaction that will be submitted.
