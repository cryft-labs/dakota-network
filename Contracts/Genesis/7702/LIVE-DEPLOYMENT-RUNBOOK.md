# Dakota Native Sponsorship Live Deployment Runbook

Live chain: Dakota Network (`112311`)

Snapshot date: 2026-07-21

This runbook covers the fixed Dakota EIP-7702 delegation entry and native gas
sponsorship control plane. It does not replace the tenant-access factory
runbook. The `DakotaDelegationRegistry` below is not a tenant user registry.

## Stop Gate

Do not first-link `0x00000000000000000000000000000000de1E6A7E` yet.

The deployed beacon currently points to `DakotaDelegation` version `1.0.0` at
`0xEfbFba9c9e9A38b5E15030511Ad15139356F39f7`. The current registry requires
the `delegationCapabilities()` and `supportsInterface()` surfaces added by
`DakotaDelegation` version `1.1.0`.

A read-only simulation of the current registry first-link reverts with:

```text
0x78e0c307 = InvalidImplementationMetadata(address)
implementation = 0xEfbFba9c9e9A38b5E15030511Ad15139356F39f7
```

Deploy and activate the current `1.1.0` implementation before first-linking
the registry.

## Authorities And Fixed Addresses

| Name | Address | Live status |
| --- | --- | --- |
| Root overlord | `0x2B7361056b31D2bf201E6764e7825fd31c0D223A` | Active root, implicit overlord, and implicit guardian |
| Validator/root registry | `0x0000000000000000000000000000000000001111` | Verified |
| Genesis ProxyAdmin | `0x0000000000000000000000000000000000FacAdE` | Verified custom Dakota `ProxyAdmin` |
| Delegation registry proxy | `0x00000000000000000000000000000000de1E6A7E` | Unlinked; implementation slot is zero; `proxy_getIsInit() == false` |
| GasSponsor proxy | `0x000000000000000000000000000000000000FEeD` | Unlinked; implementation slot is zero; `proxy_getIsInit() == false` |
| GasManager proxy | `0x000000000000000000000000000000000000cafE` | Already linked to `0xB2088C9E4350764ed24F0F07d290410fE978D7F8` |
| CodeManager proxy | `0x000000000000000000000000000000000000c0DE` | Already linked to `0x5977A092c8A3230EbE967171EcD80b125c6F0B38` |

Do not upgrade or relink GasManager or CodeManager during the delegation and
GasSponsor first-link steps. Upgrade `0x...caFE` to the verified GasManager
`2.5.0` implementation as a separate operation before using governed sponsor
funding.

## Deployment Ledger

| Component | Address | Decision |
| --- | --- | --- |
| Old `DakotaDelegation` `1.0.0` | `0xEfbFba9c9e9A38b5E15030511Ad15139356F39f7` | Verified, but do not retain as the active release |
| `DakotaDelegation` `1.1.0` | `<DEPLOY_AND_RECORD>` | Mandatory new deployment |
| `DakotaDelegationBeacon` | `0x69E67BF40445448ac342BBAFe6CA2922AAF56eE3` | Verified and usable |
| `DakotaDelegationBeaconDispatcher` | `0x6CfA66d263F84B6b8B9E21621562D624b51a58be` | Verified and usable; constructor beacon is `0x69E67...56eE3` |
| First registry deployment | `0x04f05257ce82cc32F207Dc58bBe7458686a2CBda` | Unused duplicate; never reference it |
| Selected second registry deployment | `0x8e19A0fC3c1E878F053Be9A0E6256a128169b755` | Verified; use as the fixed proxy implementation |
| `GasSponsor` implementation | `0x7c3FB725e4dF120dA7426c96f878aF413d431ab2` | Runtime logic matches the current artifact; Blockscout verification still required |

The two registry deployments have identical executable logic. Selecting the
second address is an operational choice. The first deployment has no proxy
state, is not referenced by the beacon or fixed proxy, and needs no on-chain
retirement transaction.

## Deployment Variables

Record these before broadcasting:

```text
CHAIN_ID=112311
ROOT=0x2B7361056b31D2bf201E6764e7825fd31c0D223A
VALIDATOR_ROOT_REGISTRY=0x0000000000000000000000000000000000001111
PROXY_ADMIN=0x0000000000000000000000000000000000FacAdE
DELEGATION_ENTRY=0x00000000000000000000000000000000de1E6A7E
GAS_SPONSOR_PROXY=0x000000000000000000000000000000000000FEeD
DELEGATION_IMPLEMENTATION_V1_1=<DEPLOY_AND_RECORD>
DELEGATION_BEACON=0x69E67BF40445448ac342BBAFe6CA2922AAF56eE3
DELEGATION_DISPATCHER=0x6CfA66d263F84B6b8B9E21621562D624b51a58be
DELEGATION_REGISTRY_IMPLEMENTATION=0x8e19A0fC3c1E878F053Be9A0E6256a128169b755
GAS_SPONSOR_IMPLEMENTATION=0x7c3FB725e4dF120dA7426c96f878aF413d431ab2
PLATFORM_ADMIN=<ADDRESS>
VOUCHER_SIGNER=<ADDRESS>
RELAYER=<ADDRESS>
```

For a dev canary, `PLATFORM_ADMIN` and `VOUCHER_SIGNER` may temporarily equal
`ROOT`. Use separate protected addresses for the voucher signer and relayer in
production.

## 1. Run The Build Gate

From the repository root:

```powershell
python Tools/SolcCompiler/check_gas_sponsor.py
```

Required result:

```text
status = pass
solc = 0.8.34
evm = osaka
GasSponsor runtime = 11734 bytes
DakotaDelegation runtime = 5341 bytes
DakotaDelegationBeacon runtime = 663 bytes
DakotaDelegationBeaconDispatcher runtime = 644 bytes
DakotaDelegationRegistry runtime = 12252 bytes
```

Stop if selector-collision, storage, namespace, runtime-size, or compilation
checks fail.

## 2. Deploy DakotaDelegation 1.1.0

Deploy `Contracts/Genesis/7702/DakotaDelegation.sol` using:

```text
compiler = 0.8.34
EVM = Osaka
optimizer = enabled
runs = 200
constructor arguments = none
value = 0
```

Use this exact verification input:

```text
Tools/SolcCompiler/compiled_output/Genesis/7702/DakotaDelegation/
DakotaDelegation.remix-build-info-6.standard-input.json
```

Record the new address as `DELEGATION_IMPLEMENTATION_V1_1`. Before continuing,
call the implementation directly and confirm:

```text
implementationVersion() == "1.1.0"
delegationCapabilities() == 255
supportsInterface(0x01ffc9a7) == true
supportsInterface(0x7c23f96b) == true
delegationProtocolId() != 0x0
runtime size == 5341 bytes
```

The implementation constructor disables initialization. Do not attempt to
initialize the implementation directly.

## 3. Point The Existing Beacon At 1.1.0

The live beacon currently reports:

```text
owner() = ROOT
implementation() = 0xEfbFba9c9e9A38b5E15030511Ad15139356F39f7
validatorRootRegistry() = 0x0000000000000000000000000000000000001111
```

From `ROOT`, call the beacon directly:

```solidity
DakotaDelegationBeacon(
    0x69E67BF40445448ac342BBAFe6CA2922AAF56eE3
).upgradeTo(DELEGATION_IMPLEMENTATION_V1_1)
```

Use value `0`. Confirm the beacon now returns the new address and that calls
through the dispatcher expose version `1.1.0`, capability bitmap `255`, and
both required interface checks.

Do not transfer beacon ownership yet.

## 4. Simulate And First-Link The Registry

The registry initializer is:

```solidity
DakotaDelegationRegistry.initialize(
    0x6CfA66d263F84B6b8B9E21621562D624b51a58be,
    0x69E67BF40445448ac342BBAFe6CA2922AAF56eE3,
    0x000000000000000000000000000000000000FEeD
)
```

Exact initializer calldata:

```text
0xc0c53b8b0000000000000000000000006cfa66d263f84b6b8b9e21621562d624b51a58be00000000000000000000000069e67bf40445448ac342bbafe6ca2922aaf56ee3000000000000000000000000000000000000000000000000000000000000feed
```

First run an `eth_call` simulation from `ROOT`. It must return successfully.
Then, from `ROOT`, call the fixed proxy itself using the custom Dakota
`TransparentUpgradeableProxy` ABI:

```solidity
proxy_linkLogicAdmin(
    0x8e19A0fC3c1E878F053Be9A0E6256a128169b755,
    REGISTRY_INITIALIZE_CALLDATA
)
```

Target:

```text
0x00000000000000000000000000000000de1E6A7E
```

Use value `0`. Do not call `ProxyAdmin.upgrade()` for this first link. The
custom first-link function atomically writes the implementation, sets the
genesis initialization flag, and initializes the registry. A revert rolls all
three changes back.

Confirm:

```text
proxy_getIsInit() == true
ProxyAdmin.getProxyImplementation(DELEGATION_ENTRY) == 0x8e19A0...b755
registryVersion() == "1.0.0"
registryAdmin() == ROOT
validatorRootRegistry() == 0x0000...1111
delegationEntry() == 0x0000...de1E6A7E
beacon() == 0x69E67B...56eE3
dispatcher() == 0x6CfA66...a58be
gasSponsor() == 0x0000...FEeD
releaseCount() == 1
currentRelease().implementation == DELEGATION_IMPLEMENTATION_V1_1
currentRelease().version == "1.1.0"
currentRelease().capabilities == 255
currentSnapshot().implementationCompatible == true
currentSnapshot().matchesLatestRelease == true
```

## 5. Transfer Beacon Ownership To The Fixed Registry

Only after the registry link succeeds, call from `ROOT`:

```solidity
DakotaDelegationBeacon(
    0x69E67BF40445448ac342BBAFe6CA2922AAF56eE3
).transferOwnership(
    0x00000000000000000000000000000000de1E6A7E
)
```

Confirm:

```text
beacon.owner() == 0x00000000000000000000000000000000de1E6A7E
currentSnapshot().registryControlsBeacon == true
```

After this transfer, do not call `beacon.upgradeTo()` directly. Future
delegation upgrades must use `upgradeDelegation()` on the registry.

## 6. Verify And First-Link GasSponsor

Blockscout did not report `0x7c3FB725e4dF120dA7426c96f878aF413d431ab2`
as verified at the snapshot time. Its deployed executable logic matches the
current 11,734-byte `GasSponsor` artifact, and it reports version `1.0.0`, but
source verification must still be completed before production linking.

Use the exact Remix build information from the deployment. The archived input
under the following path reproduces the executable logic, but its metadata
trailer does not exactly match the live deployment and may not complete an
exact Blockscout verification by itself:

```text
Tools/SolcCompiler/compiled_output/Genesis/7702/GasSponsor/
GasSponsor.remix-build-info-6.standard-input.json
```

Encode:

```solidity
GasSponsor.initialize(
    PLATFORM_ADMIN,
    VOUCHER_SIGNER,
    0x00000000000000000000000000000000de1E6A7E,
    100000
)
```

From `ROOT`, call the fixed GasSponsor proxy:

```solidity
proxy_linkLogicAdmin(
    0x7c3FB725e4dF120dA7426c96f878aF413d431ab2,
    GAS_SPONSOR_INITIALIZE_CALLDATA
)
```

Target:

```text
0x000000000000000000000000000000000000FEeD
```

Use value `0`. A read-only simulation using `ROOT` as the temporary dev
platform admin and voucher signer succeeds against the current chain state.

Confirm:

```text
proxy_getIsInit() == true
ProxyAdmin.getProxyImplementation(GAS_SPONSOR_PROXY) == 0x7c3FB7...431ab2
implementationVersion() == "1.0.0"
approvedDelegate() == 0x0000...de1E6A7E
platformAdmin() == PLATFORM_ADMIN
voucherSigner() == VOUCHER_SIGNER
fixedOverheadGas() == 100000
paused() == true
currentSnapshot().sponsorUsesDelegationEntry == true
```

## 7. Configure A Dev Sponsor

Use a stable tenant-owned address, normally the tenant registry, as `SPONSOR`.
Use `keccak256(bytes(canonicalTenantId))` as the tenant ID.

For the existing dev tenant:

```text
canonical tenant ID = dakota_dev_smoke_001
tenant ID hash = 0xa42d69611844a20600ec302aa0ef712caa99399caca75a4773c3abd675abc295
```

From `PLATFORM_ADMIN`:

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

After the GasManager `2.5.0` upgrade, fund the dev sponsor from `0x...caFE`:

```solidity
(bytes32 fundKey, ) = proposeSponsorFunding(
    "dev-smoke-001",
    SPONSOR,
    DEV_DEPOSIT,
    "Initial governed dev sponsorship allocation"
);

// Each remaining GasManager voter calls:
voteToFundGasV2(fundKey);

// A GasManager guardian or SPONSOR calls after approval:
executeSponsorFunding(fundKey);
```

Confirm the `FEeD` `Deposited` event reports `depositor == 0x...caFE` and that
`getSponsorAccount(SPONSOR).balance` increased by exactly `DEV_DEPOSIT`.

From `TENANT_MANAGER`, optionally reduce limits and confirm the tenant side is
enabled:

```solidity
setTenantLimits(
    SPONSOR,
    TENANT_MAX_COST_PER_OPERATION,
    TENANT_DAILY_LIMIT
)

setTenantEnabled(SPONSOR, true)
```

Keep global sponsorship paused throughout setup and simulation.

## 8. Onboard One Dev Account

The user signs an EIP-7702 authorization only. Never request or transmit the
user's private key.

```text
chainId = 112311
contractAddress = 0x00000000000000000000000000000000de1E6A7E
nonce = current user-account nonce
executor = omitted because ROOT or the onboarding service submits
```

`ROOT` submits the type-4 transaction to the user account with the signed
authorization list and this calldata:

```solidity
proxy_linkLogicAdmin(
    0x6CfA66d263F84B6b8B9E21621562D624b51a58be,
    hex""
)
```

Confirm:

```text
account code == 0xef0100 || DELEGATION_ENTRY
proxy_getIsInit() == true
account EIP-1967 implementation == DELEGATION_DISPATCHER
implementationVersion() == "1.1.0"
delegationCapabilities() == 255
GasSponsor.isDelegationReady(account) == true
DakotaDelegationRegistry.isAccountReady(account) == true
```

An accepted EIP-7702 authorization may remain installed even if the execution
transaction reverts. Inspect code, nonce, initialization state, and the
implementation slot before requesting another authorization.

## 9. Run One Funded Canary

1. Use one allowlisted relayer, one low-balance sponsor, and one known dev
   account.
2. Build a harmless `SponsoredExecutionRequest` with a unique operation ID.
3. Sign the user request for the user account as the EIP-712 verifying contract.
4. Sign the platform `SponsorshipVoucher` with `VOUCHER_SIGNER`; its verifying
   contract is `0x000000000000000000000000000000000000FEeD`.
5. Simulate the exact `executeSponsored(voucher, executionData, signature)`
   transaction from `RELAYER`.
6. Call `setPaused(false)` immediately before the canary.
7. Submit the unchanged simulated transaction.
8. Verify operation events, relayer reimbursement, sponsor balance, daily
   spend, user nonce, return-data hash, and target state.
9. Call `setPaused(true)` immediately if any assertion differs.

Failed delegated execution still consumes the operation ID and may reimburse
the relayer within the signed cap. Never reuse an operation ID.

## Future Upgrade Paths

Delegation implementation:

```solidity
DakotaDelegationRegistry(DELEGATION_ENTRY).upgradeDelegation(
    NEW_IMPLEMENTATION,
    EXPECTED_RUNTIME_CODE_HASH
)
```

Registry implementation without migration:

```solidity
ProxyAdmin(PROXY_ADMIN).upgrade(
    ITransparentUpgradeableProxy(DELEGATION_ENTRY),
    NEW_REGISTRY_IMPLEMENTATION
)
```

GasSponsor implementation without migration:

```solidity
ProxyAdmin(PROXY_ADMIN).upgrade(
    ITransparentUpgradeableProxy(GAS_SPONSOR_PROXY),
    NEW_GAS_SPONSOR_IMPLEMENTATION
)
```

Use `upgradeAndCall()` only when a future implementation introduces a numbered
reinitializer and a reviewed migration. Never call the initial `initialize()`
again. Keep sponsorship paused for every upgrade and smoke an existing account
before unpausing.

## Abort Conditions

Stop before broadcasting if any of these are true:

- Chain ID is not `112311`.
- The connected wallet is not the active root overlord.
- Either fixed proxy becomes initialized or gains an implementation before its
  planned first-link transaction.
- The beacon owner is not `ROOT` before registry linking.
- The beacon does not point to a verified `DakotaDelegation` `1.1.0` release.
- Capability bitmap is not `255` or either required interface check is false.
- The registry first-link simulation reverts.
- GasSponsor source verification is incomplete for production.
- Any deployed bytecode differs from its archived Standard JSON artifact.
- Any post-transaction getter differs from the value encoded in the call.
- The canary simulation differs from the transaction to be broadcast.

## Blockscout Records

- ProxyAdmin: <https://explore.dakota.cards/address/0x0000000000000000000000000000000000FacAdE?tab=contract>
- Old delegation `1.0.0`: <https://explore.dakota.cards/address/0xEfbFba9c9e9A38b5E15030511Ad15139356F39f7?tab=contract>
- Beacon: <https://explore.dakota.cards/address/0x69E67BF40445448ac342BBAFe6CA2922AAF56eE3?tab=contract>
- Dispatcher: <https://explore.dakota.cards/address/0x6CfA66d263F84B6b8B9E21621562D624b51a58be?tab=contract>
- Unused first registry: <https://explore.dakota.cards/address/0x04f05257ce82cc32F207Dc58bBe7458686a2CBda?tab=contract>
- Selected second registry: <https://explore.dakota.cards/address/0x8e19A0fC3c1E878F053Be9A0E6256a128169b755?tab=contract>
- GasSponsor implementation: <https://explore.dakota.cards/address/0x7c3FB725e4dF120dA7426c96f878aF413d431ab2?tab=contract>
