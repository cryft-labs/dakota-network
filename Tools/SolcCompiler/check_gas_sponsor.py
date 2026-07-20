#!/usr/bin/env python3
# Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
# Licensed under the Apache License, Version 2.0.

"""Compile and verify the initial native EIP-7702 contract boundary."""

import json

from compile import (
    CONTRACTS_DIR,
    DEFAULT_EVM_VERSION,
    DEFAULT_SOLC_VERSION,
    IMPORT_CACHE_DIR,
    install_solc,
    prepare_source,
)

import solcx


SPONSOR = CONTRACTS_DIR / "Genesis" / "7702" / "GasSponsor.sol"
DELEGATE = CONTRACTS_DIR / "Genesis" / "7702" / "DakotaDelegation.sol"
BEACON = (
    CONTRACTS_DIR
    / "Genesis"
    / "7702"
    / "DakotaDelegationBeacon.sol"
)
DISPATCHER = (
    CONTRACTS_DIR
    / "Genesis"
    / "7702"
    / "DakotaDelegationBeaconDispatcher.sol"
)
REGISTRY = (
    CONTRACTS_DIR
    / "Genesis"
    / "7702"
    / "DakotaDelegationRegistry.sol"
)
CAPABILITIES = (
    CONTRACTS_DIR
    / "Genesis"
    / "7702"
    / "Libraries"
    / "DakotaDelegationCapabilities.sol"
)
GENESIS_PROXY = (
    CONTRACTS_DIR
    / "Genesis"
    / "Upgradeable"
    / "Proxy"
    / "Transparent"
    / "TransparentUpgradeableProxy.sol"
)

EXPECTED_SPONSOR_NAMESPACE = (
    "0x1517881409dbca238e515328317c78f643c8aa79fdd0217b0d2dee62cd1df100"
)
EXPECTED_DELEGATE_NAMESPACE = (
    "0x2d5df833376e6c9531b3cb92f5745ecf8ad8197730684ec3db99cc12d4e93d00"
)
EXPECTED_REGISTRY_NAMESPACE = (
    "0xab4cfcf4b885f9dbbc02cc8800e34faa6a47500834aa5c49ef09aafea9c84000"
)

RETIRED_SPONSOR_FUNCTIONS = {
    "initializeV2",
    "deposit",
    "withdraw",
    "authorizeRelayer",
    "revokeRelayer",
    "setMaxClaimPerTx",
    "setDailyLimit",
    "addAllowedTarget",
    "removeAllowedTarget",
    "disableTargetAllowlist",
    "topOff",
    "claim",
    "sponsoredCall",
    "getSponsorInfo",
    "isAuthorizedRelayer",
    "isAllowedTarget",
}

RETIRED_DELEGATE_FUNCTIONS = {
    "initialize",
    "execute",
    "executeBatch",
    "addSessionKey",
    "removeSessionKey",
    "isValidSessionKey",
}

REQUIRED_SPONSOR_FUNCTIONS = {
    "initialize",
    "executeSponsored",
    "isDelegationReady",
    "configureSponsor",
    "setRelayer",
    "setPaused",
    "sponsorStorageLocation",
    "implementationVersion",
}

REQUIRED_DELEGATE_FUNCTIONS = {
    "executeSponsored",
    "getNonce",
    "getExecutionDigest",
    "delegationStorageLocation",
    "delegationProtocolId",
    "delegationCapabilities",
    "supportsInterface",
    "implementationVersion",
}

REQUIRED_REGISTRY_FUNCTIONS = {
    "acceptAdmin",
    "accountStatus",
    "cancelAdminTransfer",
    "currentRelease",
    "currentSnapshot",
    "getAccountDomainSeparator",
    "getAccountExecutionDigest",
    "getAccountNonce",
    "genesisProxyAdmin",
    "initialize",
    "isAccountReady",
    "pendingRegistryAdmin",
    "proposeAdmin",
    "recordCurrentImplementation",
    "registryAdmin",
    "registryImplementation",
    "registryStorageLocation",
    "registryVersion",
    "releaseAt",
    "releaseCount",
    "supportsCurrentCapability",
    "transferBeaconOwnership",
    "upgradeDelegation",
    "validatorRootRegistry",
}

REQUIRED_BEACON_FUNCTIONS = {
    "implementation",
    "upgradeTo",
    "owner",
    "transferOwnership",
}

EXPECTED_SPONSOR_LINEAR_STORAGE = [
    {"label": "_initialized", "slot": "0", "offset": 0},
    {"label": "_initializing", "slot": "0", "offset": 1},
    {"label": "_status", "slot": "1", "offset": 0},
    {"label": "__gap", "slot": "2", "offset": 0},
]

EXPECTED_REGISTRY_LINEAR_STORAGE = [
    {"label": "_initialized", "slot": "0", "offset": 0},
    {"label": "_initializing", "slot": "0", "offset": 1},
    {"label": "__gap", "slot": "1", "offset": 0},
]


def _find_contract(compiled: dict, contract_name: str) -> dict:
    suffix = f":{contract_name}"
    matches = [
        artifact
        for key, artifact in compiled.items()
        if key.endswith(suffix)
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one {contract_name} artifact, found {len(matches)}"
        )
    return matches[0]


def _function_names(artifact: dict) -> set[str]:
    return {
        entry["name"]
        for entry in artifact["abi"]
        if entry.get("type") == "function"
    }


def _selector_map(artifact: dict) -> dict[str, str]:
    return {
        signature: selector.lower()
        for signature, selector in artifact.get("hashes", {}).items()
    }


def _selector_collisions(
    implementation: dict,
    proxy: dict,
) -> dict[str, dict[str, str]]:
    proxy_selectors = {
        selector: signature
        for signature, selector in _selector_map(proxy).items()
    }
    return {
        signature: {
            "selector": selector,
            "proxy_signature": proxy_selectors[selector],
        }
        for signature, selector in _selector_map(implementation).items()
        if selector in proxy_selectors
    }


def _assert_source_contract() -> None:
    sponsor_source = SPONSOR.read_text(encoding="utf-8")
    delegate_source = DELEGATE.read_text(encoding="utf-8")
    registry_source = REGISTRY.read_text(encoding="utf-8")
    capabilities_source = CAPABILITIES.read_text(encoding="utf-8")

    required_sponsor_fragments = (
        "function initialize(",
        ") external override initializer {",
        "_disableInitializers();",
        "erc7201:dakota.storage.GasSponsor",
        EXPECTED_SPONSOR_NAMESPACE,
        'keccak256("1")',
        'return "1.0.0";',
    )
    required_delegate_fragments = (
        "erc7201:dakota.storage.DakotaDelegation",
        EXPECTED_DELEGATE_NAMESPACE,
        "dakota.delegation.sponsored-execution.v1",
        'keccak256("1")',
        'return "1.1.0";',
        "function delegationCapabilities()",
        "function supportsInterface(",
    )
    required_registry_fragments = (
        "UPGRADEABLE CONTROL PLANE",
        "function initialize(",
        ") external override initializer {",
        "_disableInitializers();",
        "erc7201:dakota.storage.DakotaDelegationRegistry",
        EXPECTED_REGISTRY_NAMESPACE,
        "address(this) != _DELEGATION_ENTRY",
        "0x00000000000000000000000000000000de1E6A7E",
        "state.registryAdmin = msg.sender;",
        ").isRootOverlord(caller)",
        "error EmptyCodeHash();",
        "function upgradeDelegation(",
        "expectedCodeHash == bytes32(0)",
        "beaconControl.upgradeTo(newImplementation);",
        "_recordRelease(newImplementation, metadata);",
        "DakotaDelegationCapabilities.REQUIRED_V1",
    )
    required_capability_fragments = (
        "library DakotaDelegationCapabilities",
        "SPONSORED_EXECUTION = 1 << 0",
        "BATCHED_CALLS = 1 << 1",
        "EIP1271 = 1 << 2",
        "NATIVE_RECEIVE = 1 << 3",
        "ERC721_RECEIVE = 1 << 4",
        "ERC1155_RECEIVE = 1 << 5",
        "TYPED_DATA_HELPERS = 1 << 6",
        "REPLAY_PROTECTION = 1 << 7",
    )
    for fragment in required_sponsor_fragments:
        if fragment not in sponsor_source:
            raise RuntimeError(
                f"GasSponsor source contract missing: {fragment}"
            )
    for fragment in required_delegate_fragments:
        if fragment not in delegate_source:
            raise RuntimeError(
                f"DakotaDelegation source contract missing: {fragment}"
            )
    for fragment in required_registry_fragments:
        if fragment not in registry_source:
            raise RuntimeError(
                f"DakotaDelegationRegistry source missing: {fragment}"
            )
    for fragment in required_capability_fragments:
        if fragment not in capabilities_source:
            raise RuntimeError(
                f"Delegation capability source missing: {fragment}"
            )
    if "delegatecall(" in registry_source:
        raise RuntimeError(
            "Delegation registry must not execute through delegatecall"
        )
    if "reinitializer(" in registry_source:
        raise RuntimeError(
            "Initial delegation registry release must not use reinitializer"
        )
    if "reinitializer(" in sponsor_source:
        raise RuntimeError(
            "Initial GasSponsor release must not use reinitializer"
        )
    if "GasSponsorV2" in sponsor_source:
        raise RuntimeError("GasSponsor source retains V2 naming")
    if "DakotaDelegationV2" in delegate_source:
        raise RuntimeError("DakotaDelegation source retains V2 naming")


def _assert_function_surface(
    artifact: dict,
    required: set[str],
    retired: set[str],
    label: str,
) -> None:
    functions = _function_names(artifact)
    missing = required - functions
    remaining = retired & functions
    if missing:
        raise RuntimeError(
            f"Required {label} functions missing: {sorted(missing)}"
        )
    if remaining:
        raise RuntimeError(
            f"Retired {label} functions remain: {sorted(remaining)}"
        )


def main() -> None:
    _assert_source_contract()
    install_solc(DEFAULT_SOLC_VERSION)
    work_files = [
        prepare_source(str(source), IMPORT_CACHE_DIR)
        for source in (
            SPONSOR,
            DELEGATE,
            BEACON,
            DISPATCHER,
            REGISTRY,
            GENESIS_PROXY,
        )
    ]
    compiled = solcx.compile_files(
        [str(path) for path in work_files],
        output_values=[
            "abi",
            "bin-runtime",
            "storage-layout",
            "hashes",
        ],
        solc_version=DEFAULT_SOLC_VERSION,
        evm_version=DEFAULT_EVM_VERSION,
        optimize=True,
        optimize_runs=200,
        allow_paths=[
            str(IMPORT_CACHE_DIR),
            *[str(path.parent) for path in work_files],
        ],
    )

    sponsor = _find_contract(compiled, "GasSponsor")
    delegate = _find_contract(compiled, "DakotaDelegation")
    beacon = _find_contract(compiled, "DakotaDelegationBeacon")
    registry = _find_contract(compiled, "DakotaDelegationRegistry")
    dispatcher = _find_contract(
        compiled,
        "DakotaDelegationBeaconDispatcher",
    )
    genesis_proxy = _find_contract(
        compiled,
        "TransparentUpgradeableProxy",
    )

    _assert_function_surface(
        sponsor,
        REQUIRED_SPONSOR_FUNCTIONS,
        RETIRED_SPONSOR_FUNCTIONS,
        "sponsor",
    )
    _assert_function_surface(
        delegate,
        REQUIRED_DELEGATE_FUNCTIONS,
        RETIRED_DELEGATE_FUNCTIONS,
        "delegate",
    )
    _assert_function_surface(
        registry,
        REQUIRED_REGISTRY_FUNCTIONS,
        set(),
        "delegation registry",
    )

    beacon_functions = _function_names(beacon)
    missing_beacon = REQUIRED_BEACON_FUNCTIONS - beacon_functions
    if missing_beacon:
        raise RuntimeError(
            f"Required beacon functions missing: {sorted(missing_beacon)}"
        )
    dispatcher_functions = _function_names(dispatcher)
    if dispatcher_functions:
        raise RuntimeError(
            "Dispatcher must expose only fallback behavior; found "
            f"{sorted(dispatcher_functions)}"
        )

    sponsor_linear_storage = [
        {
            key: entry[key]
            for key in ("label", "slot", "offset")
        }
        for entry in sponsor["storage-layout"]["storage"]
    ]
    if sponsor_linear_storage != EXPECTED_SPONSOR_LINEAR_STORAGE:
        raise RuntimeError(
            "Unexpected GasSponsor linear storage; implementation state "
            f"must remain namespaced: {sponsor_linear_storage}"
        )

    registry_linear_storage = [
        {
            key: entry[key]
            for key in ("label", "slot", "offset")
        }
        for entry in registry["storage-layout"]["storage"]
    ]
    if registry_linear_storage != EXPECTED_REGISTRY_LINEAR_STORAGE:
        raise RuntimeError(
            "Unexpected delegation registry linear storage; registry state "
            f"must remain namespaced: {registry_linear_storage}"
        )

    sponsor_collisions = _selector_collisions(
        sponsor,
        genesis_proxy,
    )
    delegate_collisions = _selector_collisions(
        delegate,
        genesis_proxy,
    )
    registry_collisions = _selector_collisions(
        registry,
        genesis_proxy,
    )
    if sponsor_collisions:
        raise RuntimeError(
            "GasSponsor/genesis proxy selector collision: "
            f"{sponsor_collisions}"
        )
    if delegate_collisions:
        raise RuntimeError(
            "Delegation/genesis proxy selector collision: "
            f"{delegate_collisions}"
        )
    if registry_collisions:
        raise RuntimeError(
            "Delegation registry/genesis proxy selector collision: "
            f"{registry_collisions}"
        )

    sizes = {
        "GasSponsor": len(bytes.fromhex(sponsor["bin-runtime"])),
        "DakotaDelegation": len(bytes.fromhex(delegate["bin-runtime"])),
        "DakotaDelegationBeacon": len(
            bytes.fromhex(beacon["bin-runtime"])
        ),
        "DakotaDelegationBeaconDispatcher": len(
            bytes.fromhex(dispatcher["bin-runtime"])
        ),
        "DakotaDelegationRegistry": len(
            bytes.fromhex(registry["bin-runtime"])
        ),
    }
    oversized = {
        name: size for name, size in sizes.items() if size > 24_576
    }
    if oversized:
        raise RuntimeError(f"EIP-170 runtime limit exceeded: {oversized}")

    print(
        json.dumps(
            {
                "status": "pass",
                "release": "initial",
                "solc": DEFAULT_SOLC_VERSION,
                "evm": DEFAULT_EVM_VERSION,
                "runtime_bytes": sizes,
                "sponsor_linear_storage": sponsor_linear_storage,
                "registry_linear_storage": registry_linear_storage,
                "sponsor_namespace": EXPECTED_SPONSOR_NAMESPACE,
                "delegate_namespace": EXPECTED_DELEGATE_NAMESPACE,
                "registry_namespace": EXPECTED_REGISTRY_NAMESPACE,
                "retired_sponsor_functions": sorted(
                    RETIRED_SPONSOR_FUNCTIONS
                ),
                "retired_delegate_functions": sorted(
                    RETIRED_DELEGATE_FUNCTIONS
                ),
                "sponsor_proxy_selector_collisions": {},
                "delegate_proxy_selector_collisions": {},
                "registry_proxy_selector_collisions": {},
                "dispatcher_functions": [],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
