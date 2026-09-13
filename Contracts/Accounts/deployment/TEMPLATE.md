# ERC-6551 deployment records — TEMPLATE

Status: **not deployed**. Do not copy these as live addresses.

Chain: `112311`
Genesis: `0x1285cc146ec6c166bcda2882220ea4b27f6997e4fa28b932f0cdc426a49003f8`
Card NFT proxy: `0x9e8C1107e04378b9ebab4e2fB3c5b97DCf84a410`

## Missing canonical infrastructure

| Name | Expected address | On-chain bytecode |
| --- | --- | --- |
| Nick's CREATE2 factory | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | none |
| ERC-6551 registry v0.3.1 | `0x000000006551c19487814612e58FE06813775758` | none |

The canonical registry address is `CREATE2(factory, salt, keccak256(canonicalInitCode))`.
The factory is itself missing. Compiling `ERC6551Registry.sol` with Solidity
0.8.37 / Osaka produces a **different** metadata suffix than the historical
solc 0.8.17 canonical bytecode, so that review build cannot occupy the
canonical address even after the factory exists.

## Owner choice

1. **Canonical registry** (optional, only if the factory transaction is accepted)
   1. Fund `0x3fab184622dc19b6109349b94811493bf2a45362` with at least `0.01` native
      (factory deployment uses gas price `100 gwei` and gas limit `100000`).
   2. Broadcast the Nick's factory raw transaction in `TEMPLATE.json`
      (`create2_factory.signed_transaction`).
   3. Confirm code at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
   4. Call the factory with `canonical_registry.factory_calldata`
      (salt `0x0000000000000000000000000000000000000000fd8eb4e1dca713016c518e31`
      concatenated with the **original** ERC-6551 v0.3.1 init code, not the
      0.8.37 review bytecode).
   5. Confirm code at `0x000000006551c19487814612e58FE06813775758`.
   6. Deploy `MomentCardAccount` with the 0.8.37 Osaka review bytecode.
   7. Record both addresses. Bind the app to this registry plus the deployed
      implementation and salt `keccak256("moment.cards:tba:v1")`.

2. **Non-canonical registry** (required if step 1 fails or is declined)
   1. Deploy the reviewed `ERC6551Registry` (0.8.37 / Osaka) with a normal
      CREATE, or CREATE2 through any factory the owner accepts.
   2. Deploy `MomentCardAccount`.
   3. Record the actual addresses after review. The canonical registry address
      must not be published as live.
   4. Bind the app to the recorded registry, implementation, and application salt.

Dakota genesis enables EIP-155 from block 0. Nick's factory uses a pre-EIP-155
signed transaction. If Besu rejects it, the canonical factory and therefore the
canonical registry are unreachable. Accept option 2.

Do not reset genesis and do not replace existing contracts to install these.

## After deployment (fill, do not invent)

Copy `TEMPLATE.json` to a dated receipt only after a successful broadcast.
Record:

- registry address and whether it is canonical
- account implementation address
- runtime keccak256 of each
- create/factory transaction hashes and blocks
- compiler `0.8.37` / `osaka` for the review account (and registry if
  non-canonical)
- application salt `keccak256("moment.cards:tba:v1")`

The application must store the first resolved account per card and must not
switch accounts if a later implementation is deployed.
