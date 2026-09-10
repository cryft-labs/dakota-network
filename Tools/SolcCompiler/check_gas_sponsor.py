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
GAS_MANAGER = (
    CONTRACTS_DIR
    / "Genesis"
    / "GasManager"
    / "GasManager.sol"
)
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
EXPECTED_GAS_MANAGER_SPONSOR_FUNDING_NAMESPACE = (
    "0x2a467852670f144839bf1fd02ad0393580187791ab471304d92161a3bee88100"
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
    "proposePlatformAdmin",
    "acceptPlatformAdmin",
    "cancelPlatformAdminTransfer",
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
    "acceptBeaconOwnership",
    "cancelBeaconOwnershipTransfer",
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
    "pendingOwner",
    "acceptOwnership",
    "cancelOwnershipTransfer",
    "implementation",
    "upgradeTo",
    "owner",
    "transferOwnership",
    "validatorRootRegistry",
}

REQUIRED_GAS_MANAGER_FUNCTIONS = {
    "initializeWithVoter",
    "getProposalSnapshot",
    "voteToSetVoterConfiguration",
    "executeFundGasV2",
    "executeSponsorFunding",
    "gasSponsor",
    "getSponsorFundingTarget",
    "implementationVersion",
    "proposeSponsorFunding",
    "sponsorFundingStorageLocation",
    "voteToFundGasV2",
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

EXPECTED_GAS_MANAGER_LINEAR_STORAGE = [
    {"label": "_initialized", "slot": "0", "offset": 0},
    {"label": "_initializing", "slot": "0", "offset": 1},
    {"label": "_status", "slot": "1", "offset": 0},
    {"label": "__gap", "slot": "2", "offset": 0},
    {"label": "voteTallyBlockThreshold", "slot": "51", "offset": 0},
    {"label": "totalGasFunded", "slot": "52", "offset": 0},
    # The old fields remain reserved at their exact slots; callable getters now use snapshots.
    {"label": "__legacyActiveVoteCount", "slot": "53", "offset": 0},
    {"label": "votersArray", "slot": "54", "offset": 0},
    {"label": "otherVoterContracts", "slot": "55", "offset": 0},
    {"label": "guardiansArray", "slot": "56", "offset": 0},
    {"label": "isGuardian", "slot": "57", "offset": 0},
    {"label": "_voteTallies", "slot": "58", "offset": 0},
    {"label": "__legacyHasVoted", "slot": "59", "offset": 0},
    {"label": "approvedBurns", "slot": "60", "offset": 0},
    {"label": "approvedFunds", "slot": "61", "offset": 0},
    {"label": "approvedCoinBurns", "slot": "62", "offset": 0},
    {"label": "_fundProposals", "slot": "63", "offset": 0},
    {"label": "_lastFundingNonceByFundingId", "slot": "64", "offset": 0},
    {"label": "fundApprovalBlockThreshold", "slot": "65", "offset": 0},
    {"label": "fundApprovalBlock", "slot": "66", "offset": 0},
    {
        "label": "fundApprovalThresholdAtApproval",
        "slot": "67",
        "offset": 0,
    },
    {"label": "_activeApprovedFundKeys", "slot": "68", "offset": 0},
    {
        "label": "_activeApprovedFundKeyIndexPlusOne",
        "slot": "69",
        "offset": 0,
    },
    {
        "label": "expiredFundCleanupAuthorized",
        "slot": "70",
        "offset": 0,
    },
    {"label": "expiredFundCleanupCursor", "slot": "71", "offset": 0},
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
    gas_manager_source = GAS_MANAGER.read_text(encoding="utf-8")
    delegate_source = DELEGATE.read_text(encoding="utf-8")
    beacon_source = BEACON.read_text(encoding="utf-8")
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
    required_gas_manager_fragments = (
        "erc7201:dakota.storage.GasManagerSponsorFunding",
        EXPECTED_GAS_MANAGER_SPONSOR_FUNDING_NAMESPACE,
        "0x000000000000000000000000000000000000FEeD",
        "function proposeSponsorFunding(",
        "function executeSponsorFunding(",
        'return "2.5.0";',
        "IGasSponsorDepository(_GAS_SPONSOR).depositFor",
        "revert SponsorFundingExecutorRequired();",
        "gasSponsorBalanceAfter - gasSponsorBalanceBefore != proposal.amount",
    )
    required_beacon_fragments = (
        "ROOT-VALIDATED SHARED UPGRADE BEACON",
        "error NotRootOverlord(address caller);",
        "0x0000000000000000000000000000000000001111",
        "UpgradeableBeacon(implementation_, msg.sender)",
        ").isRootOverlord(caller)",
        "function validatorRootRegistry()",
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
    for fragment in required_gas_manager_fragments:
        if fragment not in gas_manager_source:
            raise RuntimeError(
                f"GasManager sponsor-funding bridge missing: {fragment}"
            )
    for fragment in required_beacon_fragments:
        if fragment not in beacon_source:
            raise RuntimeError(
                f"DakotaDelegationBeacon source contract missing: {fragment}"
            )
    if "initialOwner_" in beacon_source:
        raise RuntimeError(
            "DakotaDelegationBeacon must derive bootstrap ownership from "
            "the validator-approved deployment caller"
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
    namespaces = {
        EXPECTED_SPONSOR_NAMESPACE,
        EXPECTED_DELEGATE_NAMESPACE,
        EXPECTED_REGISTRY_NAMESPACE,
        EXPECTED_GAS_MANAGER_SPONSOR_FUNDING_NAMESPACE,
    }
    if len(namespaces) != 4:
        raise RuntimeError("ERC-7201 storage namespace collision")
    install_solc(DEFAULT_SOLC_VERSION)
    work_files = [
        prepare_source(str(source), IMPORT_CACHE_DIR)
        for source in (
            SPONSOR,
            GAS_MANAGER,
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
    gas_manager = _find_contract(compiled, "GasManager")
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
        gas_manager,
        REQUIRED_GAS_MANAGER_FUNCTIONS,
        set(),
        "gas manager",
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
    beacon_constructor = next(
        entry for entry in beacon["abi"] if entry["type"] == "constructor"
    )
    beacon_constructor_types = [
        item["type"] for item in beacon_constructor["inputs"]
    ]
    if beacon_constructor_types != ["address"]:
        raise RuntimeError(
            "DakotaDelegationBeacon constructor must accept only the "
            f"delegation implementation: {beacon_constructor_types}"
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

    gas_manager_linear_storage = [
        {
            key: entry[key]
            for key in ("label", "slot", "offset")
        }
        for entry in gas_manager["storage-layout"]["storage"]
    ]
    if gas_manager_linear_storage != EXPECTED_GAS_MANAGER_LINEAR_STORAGE:
        raise RuntimeError(
            "Unexpected GasManager linear storage; sponsor funding must use "
            f"its ERC-7201 namespace: {gas_manager_linear_storage}"
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
    gas_manager_collisions = _selector_collisions(
        gas_manager,
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
    if gas_manager_collisions:
        raise RuntimeError(
            "GasManager/genesis proxy selector collision: "
            f"{gas_manager_collisions}"
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
        "GasManager": len(bytes.fromhex(gas_manager["bin-runtime"])),
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
        name: size for name, size in sizes.items() if size > 32_768
    }
    if oversized:
        raise RuntimeError(f"Dakota 32 KiB runtime limit exceeded: {oversized}")

    print(
        json.dumps(
            {
                "status": "pass",
                "release": "initial",
                "solc": DEFAULT_SOLC_VERSION,
                "evm": DEFAULT_EVM_VERSION,
                "runtime_bytes": sizes,
                "runtime_limit_bytes": 32_768,
                "sponsor_linear_storage": sponsor_linear_storage,
                "gas_manager_linear_storage": gas_manager_linear_storage,
                "registry_linear_storage": registry_linear_storage,
                "sponsor_namespace": EXPECTED_SPONSOR_NAMESPACE,
                "gas_manager_sponsor_funding_namespace": (
                    EXPECTED_GAS_MANAGER_SPONSOR_FUNDING_NAMESPACE
                ),
                "delegate_namespace": EXPECTED_DELEGATE_NAMESPACE,
                "registry_namespace": EXPECTED_REGISTRY_NAMESPACE,
                "retired_sponsor_functions": sorted(
                    RETIRED_SPONSOR_FUNCTIONS
                ),
                "retired_delegate_functions": sorted(
                    RETIRED_DELEGATE_FUNCTIONS
                ),
                "sponsor_proxy_selector_collisions": {},
                "gas_manager_proxy_selector_collisions": {},
                "delegate_proxy_selector_collisions": {},
                "registry_proxy_selector_collisions": {},
                "dispatcher_functions": [],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
