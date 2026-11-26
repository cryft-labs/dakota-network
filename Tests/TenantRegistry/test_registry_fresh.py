"""Tenant registry 1.8.0 on a fresh chain, in an isolated EVM (eth_tester / py-evm): no RPC, no live keys.

Deployed as the kit's fresh-chain release does (Tools/TenantRegistry/build.py): the registry implementation with
RENAME_TARGET = address(0), the factory implementation behind a ManagedApplicationProxy owned by a ManagedProxyAdmin
(Ownable2Step), the factory-owned UpgradeableBeacon, and tenant cryft.cards created directly. Then every audit fix:
two-step hand-overs (X-69), backup removal needs the backup (X-28), origin and batch caps (X-71), admin-only foreign
retire (X-70), role-0 operators refused (X-I20), renames disabled at zero (X-72), and locked initializers.

    python -m pytest Tests/TenantRegistry/test_registry_fresh.py -q
"""
import importlib.util
import json
from pathlib import Path

import pytest
import solcx
from eth_tester import EthereumTester, PyEVMBackend
from eth_utils import keccak
from web3 import EthereumTesterProvider, Web3

REPO = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("tenant_registry_build", REPO / "Tools/TenantRegistry/build.py")
build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build)

TENANT = "cryft.cards"
ORIGIN = "https://cryft.app"
NAME, SYMBOL = "Kota Tenant User Access", "KTUA"
ZERO = "0x" + "00" * 20
ROLE_TENANT, ROLE_SYSTEM = 1, 3
TIER = 1

MOCK_ADMIN_REGISTRY = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Test only: the platform access registry's policy ABI (IKotaAdminRegistry) with settable answers.
contract MockAdminRegistry {
    mapping(address => uint8) public roleOf;
    mapping(address => uint32) public tierOf;
    mapping(uint32 => bool) public tierActive;
    mapping(uint32 => uint256) public maxRegistriesOfTier;
    mapping(uint32 => uint256) public maxHoldersOfTier;
    mapping(uint32 => uint256) public tierFeatures;
    function set(address holder, uint8 role, uint32 tier) external { roleOf[holder] = role; tierOf[holder] = tier; }
    function setTier(uint32 tier, bool active, uint256 maxRegistries, uint256 maxHolders, uint256 features) external {
        tierActive[tier] = active; maxRegistriesOfTier[tier] = maxRegistries;
        maxHoldersOfTier[tier] = maxHolders; tierFeatures[tier] = features;
    }
    function tierLimits(uint32 tier) external view returns (uint256, uint256) {
        return (maxRegistriesOfTier[tier], maxHoldersOfTier[tier]);
    }
    function balanceOf(address holder) external view returns (uint256) { return roleOf[holder] == 0 ? 0 : 1; }
    function hasRole(address holder, uint8 minimumRole) external view returns (bool) {
        return roleOf[holder] != 0 && roleOf[holder] >= minimumRole;
    }
}
"""


# ── the build ──
@pytest.fixture(scope="session")
def arts():
    if Path(solcx.get_solcx_install_folder() / f"solc-v{build.SOLC_VERSION}").exists() is False:
        pytest.skip(f"solc {build.SOLC_VERSION} is not installed (never downloaded by the tests)")
    out = {}
    standard = build.registry_input()
    compiled = build.compile_standard(standard)
    for name, unit in build.REGISTRY_TARGETS.items():
        out[name] = build.artifact(compiled, unit, name, standard)
    for name in build.PROXY_TARGETS:
        pinned = json.loads((build.PALADIN_INPUTS / f"{name}.json").read_bytes())
        result = build.compile_standard(pinned)
        unit = next(u for u, cs in result["contracts"].items() if name in cs)
        out[name] = build.artifact(result, unit, name, pinned)
    mock = solcx.compile_source(MOCK_ADMIN_REGISTRY, solc_version=build.SOLC_VERSION, evm_version="osaka",
                                output_values=["abi", "bin"])["<stdin>:MockAdminRegistry"]
    out["MockAdminRegistry"] = {"abi": mock["abi"], "creation_bytecode": "0x" + mock["bin"]}
    return out


class Chain:
    def __init__(self, arts):
        self.arts = arts
        self.tester = EthereumTester(backend=PyEVMBackend(genesis_parameters={"gas_limit": 60_000_000}))
        self.w3 = Web3(EthereumTesterProvider(self.tester))
        a = self.w3.eth.accounts
        (self.admin, self.upgrader, self.deployer, self.operator, self.operator2,
         self.backup, self.system, self.stranger, self.updater, self.backup2) = a[:10]

    def send(self, fn, sender):
        receipt = self.w3.eth.wait_for_transaction_receipt(fn.transact({"from": sender, "gas": 15_000_000}))
        assert receipt.status == 1
        return receipt

    def deploy(self, name, *args, sender=None):
        art = self.arts[name]
        contract = self.w3.eth.contract(abi=art["abi"], bytecode=art["creation_bytecode"])
        receipt = self.send(contract.constructor(*args), sender or self.deployer)
        return self.w3.eth.contract(address=receipt.contractAddress, abi=art["abi"])

    def at(self, name, address):
        return self.w3.eth.contract(address=address, abi=self.arts[name]["abi"])

    def reverts(self, fn, error, sender):
        """The call (as `sender`) reverts with the custom error `error`, e.g. "NotAdmin()"."""
        selector = keccak(text=error)[:4]
        wanted, as_bytes = selector.hex(), repr(selector)[2:-1]
        try:
            fn.call({"from": sender, "gas": 15_000_000})
        except Exception as raised:  # noqa: BLE001
            text = " ".join(str(x) for x in (getattr(raised, "data", ""), raised.args, raised))
            assert wanted in text or as_bytes in text, f"wanted {error} (0x{wanted}), got {text[:300]}"
            return
        raise AssertionError(f"did not revert (wanted {error})")


@pytest.fixture()
def c(arts):
    """The fresh-chain release, steps 1-7 of Tools/TenantRegistry/build.py."""
    c = Chain(arts)
    c.plans = c.deploy("MockAdminRegistry")
    c.send(c.plans.functions.setTier(TIER, True, 2, 0, 3), c.deployer)       # 2 registries, unlimited holders, both features
    for who in (c.operator, c.operator2):
        c.send(c.plans.functions.set(who, ROLE_TENANT, TIER), c.deployer)
    c.send(c.plans.functions.set(c.system, ROLE_SYSTEM, TIER), c.deployer)
    c.sbt_impl = c.deploy("KotaTenantAccessSBT", ZERO)                         # 1
    c.factory_impl = c.deploy("KotaAccessFactory")                              # 2
    c.proxy_admin = c.deploy("ManagedProxyAdmin", c.upgrader)                   # 3
    init = c.factory_impl.functions.initialize(c.admin, c.plans.address)._encode_transaction_data()
    proxy = c.deploy("ManagedApplicationProxy", c.factory_impl.address, c.proxy_admin.address, init)   # 4
    c.factory = c.at("KotaAccessFactory", proxy.address)
    c.send(c.factory.functions.deployTenantRegistryBeacon(c.sbt_impl.address), c.admin)                # 5
    c.beacon = c.at("UpgradeableBeacon", c.factory.functions.tenantRegistryBeacon().call())
    c.send(c.factory.functions.deployTenantRegistry(TENANT, c.operator, NAME, SYMBOL, [ORIGIN]), c.admin)  # 6
    c.registry = c.at("KotaTenantAccessSBT", c.factory.functions.registryAt(TENANT, 0).call())
    c.send(c.registry.functions.setMetadataUpdater(c.updater), c.operator)                            # 7
    return c


# ── deploy shape ──
def test_fresh_deploy_creates_cryft_cards_directly(c):
    r, f = c.registry, c.factory
    assert f.functions.admin().call() == c.admin
    assert f.functions.adminRegistry().call() == c.plans.address
    assert c.beacon.functions.owner().call() == f.address
    assert c.beacon.functions.implementation().call() == c.sbt_impl.address
    assert r.functions.tenantId().call() == TENANT and r.functions.name().call() == NAME
    assert r.functions.factory().call() == f.address and r.functions.operator().call() == c.operator
    assert r.functions.allowedOrigins().call() == [ORIGIN]
    assert r.functions.metadataUpdater().call() == c.updater
    assert f.functions.tenantOperatorOf(TENANT).call() == c.operator
    assert f.functions.tenantIdOf(r.address).call() == TENANT
    assert f.functions.canonicalTenantId(TENANT).call() == TENANT
    assert f.functions.tenantRenamed().call() is False
    assert c.sbt_impl.functions.RENAME_TARGET().call() == ZERO
    proxy = c.at("ManagedApplicationProxy", f.address)
    assert c.proxy_admin.functions.getProxyAdmin(proxy.address).call() == c.proxy_admin.address
    assert c.proxy_admin.functions.getProxyImplementation(proxy.address).call() == c.factory_impl.address


def zero_immutables(code: bytes, refs: dict) -> bytes:
    body = bytearray(code)
    for ranges in refs.values():
        for r in ranges:
            body[r["start"]:r["start"] + r["length"]] = bytes(r["length"])
    return bytes(body)


def test_on_chain_code_matches_build_keccaks(c):
    for name, address in (("KotaAccessFactory", c.factory_impl.address), ("KotaTenantAccessSBT", c.sbt_impl.address),
                          ("UpgradeableBeacon", c.beacon.address), ("BeaconProxy", c.registry.address),
                          ("ManagedProxyAdmin", c.proxy_admin.address), ("ManagedApplicationProxy", c.factory.address)):
        art = c.arts[name]
        code = zero_immutables(bytes(c.w3.eth.get_code(address)), art["immutable_references"])
        assert "0x" + keccak(code).hex() == art["runtime_keccak256"], name


def test_committed_build_is_current():
    assert build.main(["--check"]) == 0


# ── initializer locks ──
def test_initializers_locked_on_implementations_and_proxies(c):
    locked = "InvalidInitialization()"
    c.reverts(c.sbt_impl.functions.initialize("x", "y", "z", c.operator, []), locked, c.stranger)
    c.reverts(c.factory_impl.functions.initialize(c.stranger, c.plans.address), locked, c.stranger)
    c.reverts(c.factory.functions.initialize(c.stranger, c.plans.address), locked, c.stranger)
    c.reverts(c.registry.functions.initialize("x", "y", "z", c.stranger, []), locked, c.stranger)


# ── X-69: two-step hand-overs ──
def test_factory_admin_handover_is_two_step(c):
    f = c.factory
    c.reverts(f.functions.transferAdmin(c.stranger), "NotAdmin()", c.stranger)
    c.send(f.functions.transferAdmin(c.backup2), c.admin)
    assert f.functions.admin().call() == c.admin and f.functions.pendingAdmin().call() == c.backup2
    c.reverts(f.functions.acceptAdmin(), "NotPendingAdmin()", c.stranger)
    c.send(f.functions.transferAdmin(ZERO), c.admin)                       # cancel
    c.reverts(f.functions.acceptAdmin(), "NotPendingAdmin()", c.backup2)
    c.send(f.functions.transferAdmin(c.backup2), c.admin)
    c.send(f.functions.acceptAdmin(), c.backup2)
    assert f.functions.admin().call() == c.backup2 and f.functions.pendingAdmin().call() == ZERO
    c.reverts(f.functions.transferAdmin(c.admin), "NotAdmin()", c.admin)
    c.reverts(f.functions.acceptAdmin(), "NotPendingAdmin()", c.backup2)


def test_factory_proxy_admin_is_ownable2step_and_never_renounced(c):
    pa = c.proxy_admin
    c.send(pa.functions.transferOwnership(c.backup2), c.upgrader)
    assert pa.functions.owner().call() == c.upgrader
    c.send(pa.functions.acceptOwnership(), c.backup2)
    assert pa.functions.owner().call() == c.backup2
    c.reverts(pa.functions.renounceOwnership(), "RenounceDisabled()", c.backup2)


def test_operator_handover_needs_the_new_operators_acceptance(c):
    r, f = c.registry, c.factory
    c.reverts(r.functions.setOperator(c.operator2), "NotOperator()", c.stranger)
    c.send(r.functions.setOperator(c.operator2), c.operator)
    assert r.functions.operator().call() == c.operator and r.functions.pendingOperator().call() == c.operator2
    c.reverts(r.functions.acceptOperatorChange(), "NotPendingOperator()", c.stranger)
    c.send(r.functions.acceptOperatorChange(), c.operator2)
    assert r.functions.operator().call() == c.operator2
    assert f.functions.tenantOperatorOf(TENANT).call() == c.operator2
    assert r.functions.pendingOperator().call() == ZERO
    c.reverts(r.functions.acceptOperatorChange(), "NoPendingOperator()", c.operator2)


def test_operator_handover_with_backup_needs_approval_then_acceptance(c):
    r = c.registry
    c.send(r.functions.setBackupApprover(c.backup), c.operator)
    c.send(r.functions.setOperator(c.operator2), c.operator)
    c.reverts(r.functions.acceptOperatorChange(), "OperatorChangeNotApproved()", c.operator2)
    c.reverts(r.functions.approveOperatorChange(), "NotBackup()", c.stranger)
    c.send(r.functions.approveOperatorChange(), c.backup)
    # a new proposal needs a fresh approval
    c.send(r.functions.setOperator(c.operator2), c.operator)
    c.reverts(r.functions.acceptOperatorChange(), "OperatorChangeNotApproved()", c.operator2)
    c.send(r.functions.approveOperatorChange(), c.backup)
    c.send(r.functions.acceptOperatorChange(), c.operator2)
    assert r.functions.operator().call() == c.operator2


def test_operator_must_hold_a_tenant_role(c):
    # X-I20 on this side: an address with role 0 (no platform credential) can never become an operator.
    c.reverts(c.registry.functions.setOperator(c.stranger), "TenantCredentialRequired()", c.operator)
    c.reverts(c.factory.functions.deployTenantRegistry("other", c.stranger, NAME, SYMBOL, []),
              "TenantCredentialRequired()", c.admin)


# ── X-28: the backup approver ──
def test_backup_removal_needs_the_backups_approval(c):
    r = c.registry
    c.send(r.functions.setBackupApprover(c.backup), c.operator)         # first backup: at once
    assert r.functions.backupApprover().call() == c.backup
    # the stolen-operator path: clear the backup, then rotate alone
    c.send(r.functions.setBackupApprover(ZERO), c.operator)
    assert r.functions.backupApprover().call() == c.backup
    assert r.functions.pendingBackupApproverSet().call() is True
    c.send(r.functions.setOperator(c.operator2), c.operator)
    c.reverts(r.functions.acceptOperatorChange(), "OperatorChangeNotApproved()", c.operator2)
    c.reverts(r.functions.approveBackupApproverChange(), "NotBackup()", c.operator)
    # the backup approves the clear; the pending operator proposal is dropped with it
    c.send(r.functions.approveBackupApproverChange(), c.backup)
    assert r.functions.backupApprover().call() == ZERO
    assert r.functions.pendingOperator().call() == ZERO
    c.reverts(r.functions.approveBackupApproverChange(), "NotBackup()", c.backup)


def test_backup_replacement_needs_the_backups_approval(c):
    r = c.registry
    c.send(r.functions.setBackupApprover(c.backup), c.operator)
    c.reverts(r.functions.approveBackupApproverChange(), "NoPendingBackupChange()", c.backup)
    c.send(r.functions.setBackupApprover(c.backup2), c.operator)
    assert r.functions.backupApprover().call() == c.backup
    c.reverts(r.functions.approveBackupApproverChange(), "NotBackup()", c.backup2)
    c.send(r.functions.approveBackupApproverChange(), c.backup)
    assert r.functions.backupApprover().call() == c.backup2
    assert r.functions.pendingBackupApproverSet().call() is False


def test_platform_recovery_clears_backup_and_pending_changes(c):
    r = c.registry
    c.send(r.functions.setBackupApprover(c.backup), c.operator)
    c.send(r.functions.setBackupApprover(c.backup2), c.operator)
    c.send(r.functions.setOperator(c.operator2), c.operator)
    c.reverts(c.factory.functions.setRegistryOperator(TENANT, c.operator2), "NotAdmin()", c.system)
    c.send(c.factory.functions.setRegistryOperator(TENANT, c.operator2), c.admin)
    assert r.functions.operator().call() == c.operator2
    assert r.functions.backupApprover().call() == ZERO
    assert r.functions.pendingBackupApproverSet().call() is False
    assert r.functions.pendingOperator().call() == ZERO
    assert r.functions.metadataUpdater().call() == ZERO               # epoch bump drops delegated keys


# ── X-71: caps ──
def test_origin_cap_and_length(c):
    r = c.registry
    cap = r.functions.MAX_ORIGINS().call()
    assert cap == 16 and r.functions.MAX_ORIGIN_BYTES().call() == 256
    for i in range(cap - 1):
        c.send(r.functions.addAllowedOrigin(f"https://o{i}.example"), c.operator)
    assert len(r.functions.allowedOrigins().call()) == cap
    c.reverts(r.functions.addAllowedOrigin("https://one-too-many.example"), "TooManyOrigins()", c.operator)
    c.send(r.functions.removeAllowedOrigin(0), c.operator)
    c.reverts(r.functions.addAllowedOrigin(""), "InvalidOrigin()", c.operator)
    c.reverts(r.functions.addAllowedOrigin("h" * 257), "InvalidOrigin()", c.operator)
    c.send(r.functions.addAllowedOrigin("h" * 256), c.operator)
    c.reverts(r.functions.addAllowedOrigin(ORIGIN), "NotOperator()", c.stranger)


def test_origin_cap_at_deploy(c):
    many = [f"https://o{i}.example" for i in range(17)]
    c.reverts(c.factory.functions.deployTenantRegistry("other", c.operator2, NAME, SYMBOL, many), "TooManyOrigins()", c.admin)
    c.reverts(c.factory.functions.deployAdditionalRegistry(TENANT, NAME, SYMBOL, many), "TooManyOrigins()", c.operator)
    c.reverts(c.factory.functions.deployTenantRegistry("other", c.operator2, NAME, SYMBOL, [""]), "InvalidOrigin()", c.admin)
    c.send(c.factory.functions.deployTenantRegistry("other", c.operator2, NAME, SYMBOL, many[:16]), c.admin)


def test_batch_caps(c):
    r = c.registry
    holders = [Web3.to_checksum_address(keccak(text=f"member-{i}")[:20]) for i in range(101)]
    c.reverts(r.functions.grantAccessBatch(holders), "BatchTooLarge()", c.operator)
    c.send(r.functions.grantAccessBatch(holders[:100]), c.operator)
    assert r.functions.activeHolders().call() == 100
    c.send(r.functions.createTier("gold", ""), c.operator)
    c.reverts(r.functions.assignTierBatch(holders, 1), "BatchTooLarge()", c.operator)
    c.reverts(r.functions.assignTierBatch([], 1), "BatchTooLarge()", c.operator)
    c.send(r.functions.assignTierBatch(holders[:100], 1), c.operator)
    assert r.functions.tierOf(holders[99]).call() == 1


# ── X-70: foreign retire ──
def test_only_admin_retires_another_tenants_registry(c):
    f = c.factory
    c.send(f.functions.deployAdditionalRegistry(TENANT, NAME, SYMBOL, [ORIGIN]), c.operator)
    assert f.functions.activeRegistryCount(TENANT).call() == 2
    c.reverts(f.functions.retireRegistry(TENANT, 1), "NotTenantOperator()", c.system)
    c.reverts(f.functions.retireRegistry(TENANT, 1), "NotTenantOperator()", c.stranger)
    c.send(f.functions.retireRegistry(TENANT, 1), c.admin)
    assert f.functions.activeRegistryCount(TENANT).call() == 1
    c.reverts(f.functions.retireRegistry(TENANT, 0), "CannotRetireLastRegistry()", c.admin)
    # the tenant still retires its own
    c.send(f.functions.deployAdditionalRegistry(TENANT, NAME, SYMBOL, []), c.operator)
    c.send(f.functions.retireRegistry(TENANT, 2), c.operator)
    assert f.functions.activeRegistryCount(TENANT).call() == 1


def test_system_keeps_its_other_powers(c):
    c.send(c.factory.functions.deployTenantRegistry("other", c.operator2, NAME, SYMBOL, []), c.system)
    registry = c.factory.functions.registryAt("other", 0).call()
    c.send(c.factory.functions.setRegistryMaxHoldersOverride(registry, 5), c.system)


# ── X-72: renames disabled at zero ──
def test_rename_is_disabled_when_rename_target_is_zero(c):
    f, r = c.factory, c.registry
    c.reverts(f.functions.renameTenant(TENANT, "renamed.cards", r.address, "N", "S"), "RenameDisabled()", c.admin)
    c.reverts(f.functions.renameTenant(TENANT, "renamed.cards", ZERO, "N", "S"), "RenameDisabled()", c.admin)
    c.reverts(f.functions.renameTenant(TENANT, "renamed.cards", r.address, "N", "S"), "NotAdmin()", c.stranger)
    c.reverts(r.functions.renameRegistry(TENANT, "renamed.cards", "N", "S"), "NotFactory()", c.admin)
    assert f.functions.tenantRenamed().call() is False and r.functions.registryRenamed().call() is False
    assert r.functions.tenantId().call() == TENANT
    assert f.functions.renamedTenantOf(TENANT).call() == ""


def test_beacon_upgrade_to_an_armed_implementation_is_admin_only(c):
    # Renames can only come back through an admin beacon upgrade to an implementation built with a target.
    armed = c.deploy("KotaTenantAccessSBT", c.registry.address)
    c.reverts(c.factory.functions.upgradeTenantRegistryBeaconImplementation(armed.address), "NotAdmin()", c.system)
