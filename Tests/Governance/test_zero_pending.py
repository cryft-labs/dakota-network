"""Two-step handovers refuse an accept while nothing is pending, even from the zero address.

With no transfer pending, the pending address is zero; a check of `msg.sender == pending` alone lets a zero caller
match it. No real transaction can come from address(0), but a simulation can, and the rule must not depend on that.
Registry 3.0.1 acceptAdmin, GasSponsor 1.5.3 acceptPlatformAdmin, TenantAllowancePolicy acceptOwnership.
"""
import importlib.util

from test_governance import REPO, chain, tx, fails, deploy, linked  # noqa: F401 (chain is a fixture)
from test_delegation_upgrade import builds, stack  # noqa: F401 (builds is a fixture)

import pytest
from eth_tester.exceptions import TransactionFailed

ZERO = '0x' + '0' * 40


def zero_fails(function):
    """A simulated call from address(0) must revert (modest gas: the zero address holds little coin in the tester)."""
    with pytest.raises((TransactionFailed, ValueError)):
        function.call({'from': ZERO, 'gas': 300000})


def compiled(relative, name):
    spec = importlib.util.spec_from_file_location('zp_compiler', REPO / 'Tools/SolcCompiler/compile.py')
    compiler = importlib.util.module_from_spec(spec); spec.loader.exec_module(compiler)
    out = compiler.compile_contract(REPO / relative, solc_version='0.8.37', evm_version='osaka')
    return next(v for k, v in out.items() if k.rsplit(':', 1)[-1] == name)


def test_registry_accept_admin_refuses_zero_and_strangers(chain):
    a, b, stranger = chain['accounts'][:3]
    registry, *_ = stack(chain, delay=0, admin=a)
    zero_fails(registry.functions.acceptAdmin())          # nothing pending: zero may not match zero
    fails(chain, registry.functions.acceptAdmin(), stranger)
    tx(chain, registry.functions.proposeAdmin(b), a)
    zero_fails(registry.functions.acceptAdmin())
    fails(chain, registry.functions.acceptAdmin(), stranger)
    tx(chain, registry.functions.acceptAdmin(), b)
    assert registry.functions.registryAdmin().call() == b
    zero_fails(registry.functions.acceptAdmin())          # the slot is clear again


def test_gas_sponsor_accept_platform_admin_refuses_zero_and_strangers(chain):
    a, b, stranger = chain['accounts'][:3]
    logic = deploy(chain, 'CryftDelegation'); beacon = deploy(chain, 'CryftDelegationBeacon', logic.address)
    dispatcher = deploy(chain, 'CryftBeaconDispatcher', beacon.address)
    chain['builds']['GasSponsor'] = compiled('Contracts/Genesis/7702/GasSponsor.sol', 'GasSponsor')
    sponsor = linked(chain, 'GasSponsor', args=(a, a, dispatcher.address, 100000))
    assert sponsor.functions.implementationVersion().call() == '1.5.3'
    zero_fails(sponsor.functions.acceptPlatformAdmin())
    fails(chain, sponsor.functions.acceptPlatformAdmin(), stranger)
    tx(chain, sponsor.functions.proposePlatformAdmin(b), a)
    zero_fails(sponsor.functions.acceptPlatformAdmin())
    tx(chain, sponsor.functions.acceptPlatformAdmin(), b)
    assert sponsor.functions.platformAdmin().call() == b
    zero_fails(sponsor.functions.acceptPlatformAdmin())


def test_tenant_allowance_policy_accept_ownership_refuses_zero(chain):
    chain['builds']['TenantAllowancePolicy'] = compiled('Contracts/Templates/TenantAllowancePolicy.sol', 'TenantAllowancePolicy')
    a, b, tenant = chain['accounts'][:3]
    code_holder = deploy(chain, 'CryftDelegation')                 # any contract stands in for the sponsor
    policy = deploy(chain, 'TenantAllowancePolicy', code_holder.address, tenant, a, ZERO, 0, 0, [])
    zero_fails(policy.functions.acceptOwnership())
    tx(chain, policy.functions.proposeOwner(b), a)
    zero_fails(policy.functions.acceptOwnership())
    tx(chain, policy.functions.acceptOwnership(), b)
    assert policy.functions.owner().call() == b
    zero_fails(policy.functions.acceptOwnership())
