"""Actual-EVM worker accounting, rollback and concurrent-reservation checks.

GasSponsor 1.5.2: the engine is THIS source's WorkerGasSponsor linked fresh at 0x…FEeD (the verified 1.3.0 upgrade was the old
chain's path); adds X-19 (a reservation is an operation) and X-57 (redirectWorkerRevenue).
"""
import importlib.util
from pathlib import Path
import pytest
from web3 import Web3
from web3.logs import DISCARD
from test_native_sponsorship import builds, chain, setup, tx, fails, paid, at
from test_governance import ADMIN

REPO=Path(__file__).resolve().parents[2]

def compiled(relative,name):
    spec=importlib.util.spec_from_file_location('worker_compiler',REPO/'Tools/SolcCompiler/compile.py')
    compiler=importlib.util.module_from_spec(spec);spec.loader.exec_module(compiler)
    out=compiler.compile_contract(REPO/relative,solc_version='0.8.37',evm_version='osaka')
    return next(v for k,v in out.items() if k.rsplit(':',1)[-1]==name)

@pytest.fixture(scope='session')
def policy_build():
    return compiled('Contracts/Templates/TenantAllowancePolicy.sol','TenantAllowancePolicy')

def create(c,a,*args):
    receipt=tx(c,c['w3'].eth.contract(abi=a['abi'],bytecode=a['creation_bytecode']).constructor(*args))
    return c['w3'].eth.contract(address=receipt.contractAddress,abi=a['abi'])

@pytest.fixture(scope='session')
def worker_build():
    return compiled('Contracts/Genesis/7702/WorkerGasSponsor.sol','WorkerGasSponsor')

@pytest.fixture
def ready(chain, worker_build, policy_build):
    c=chain; _,s,_,_=setup(c,worker_build);a=c['accounts']
    assert s.functions.implementationVersion().call()=='1.5.3'
    p=create(c,policy_build,s.address,a[4],a[5],'0x'+'0'*40,10**15,2*10**15,[])
    tx(c,s.functions.setSponsorPolicy(a[4],p.address),a[5])
    tx(c,s.functions.configureWorker(a[2],a[8]))
    tx(c,s.functions.setTenantWorker(a[4],a[2],True),a[5])
    return c,s,p

def reserve(ready,tag,wallet=None,maximum=10**15,sender=None):
    c,s,p=ready;a=c['accounts'];key=Web3.keccak(text=tag)
    return key,s.functions.reserveWorker(a[4],wallet or a[3],key,Web3.keccak(text='request:'+tag),maximum),sender or a[2]

def test_parallel_reservations_share_user_and_account_limits(ready):
    c,s,p=ready;a=c['accounts']
    one,call,sender=reserve(ready,'first');tx(c,call,sender)
    two,call,sender=reserve(ready,'second');tx(c,call,sender)
    assert p.functions.allowance(a[3]).call()[3:6]==[0,0,2*10**15]
    _,call,sender=reserve(ready,'overdraft');fails(c,call,sender)
    _,call,sender=reserve(ready,'another-user',wallet=a[6]);tx(c,call,sender)
    assert s.functions.pendingWorkerCost(a[4]).call()==3*10**15
    # The manager cannot change policy while an operation holds its allowance.
    fails(c,s.functions.setSponsorPolicy(a[4],'0x'+'0'*40),a[5])
    before=s.functions.getSponsorAccount(a[4]).call()[2]
    result=tx(c,s.functions.settleWorker(one,123,Web3.keccak(text='receipt')),a[2])
    cost=s.events.WorkerSettled().process_receipt(result,errors=DISCARD)[0]['args']['cost']
    assert 123<=cost<=10**15 and p.functions.allowance(a[3]).call()[4:6]==[cost,10**15]
    assert s.functions.getSponsorAccount(a[4]).call()[2]==before-cost
    fails(c,s.functions.settleWorker(one,123,Web3.keccak(text='replay')),a[2])
    _,call,sender=reserve(ready,'first');fails(c,call,sender)

def test_revocation_and_day_boundary_do_not_strand_inflight_work(ready):
    c,s,p=ready;a=c['accounts'];key,call,sender=reserve(ready,'yesterday');tx(c,call,sender)
    tx(c,s.functions.configureWorker(a[2],'0x'+'0'*40))
    tx(c,s.functions.setTenantWorker(a[4],a[2],False),a[5])
    _,call,sender=reserve(ready,'revoked');fails(c,call,sender)
    c['tester'].time_travel((c['w3'].eth.get_block('latest').timestamp//86400+1)*86400+1);c['tester'].mine_blocks(1)
    assert p.functions.allowance(a[3]).call()[5]==10**15
    before=c['w3'].eth.get_balance(a[8])
    tx(c,s.functions.settleWorker(key,123,Web3.keccak(text='old-receipt')),a[2])
    assert p.functions.pendingReservations().call()==0
    assert c['w3'].eth.get_balance(a[8])>before
    assert s.functions.pendingWorkerCost(a[4]).call()==0

def test_untrusted_users_cannot_attest_spend_or_unlock_reserved_funds(ready):
    c,s,p=ready;a=c['accounts'];key,call,_=reserve(ready,'protected')
    fails(c,call,a[6]);tx(c,call,a[2])
    fails(c,s.functions.settleWorker(key,1,Web3.keccak(text='forgery')),a[6])
    fails(c,s.functions.settleWorker(key,10**15+1,Web3.keccak(text='too-much')),a[2])
    # A lost signer can be reconciled by existing platform governance.
    tx(c,s.functions.settleWorker(key,0,Web3.keccak(text='reviewed-cancel')))
    assert p.functions.pendingReservations().call()==0

def test_reserved_funds_cannot_be_withdrawn_or_recovered(ready):
    c,s,p=ready;a=c['accounts'];balance=s.functions.getSponsorAccount(a[4]).call()[2]
    key,call,sender=reserve(ready,'funded');tx(c,call,sender)
    fails(c,s.functions.withdrawSponsor(a[4],a[5],balance),a[5])
    paid(c,s.functions.depositGasCredit(a[4]),1000)
    # Restricted deposits remain unavailable to a tenant, even after settlement.
    refundable,_=s.functions.getSponsorFunding(a[4]).call()
    fails(c,s.functions.withdrawSponsor(a[4],a[5],refundable+1),a[5])

def test_policy_migration_is_owner_only_monotonic_and_closes_at_first_reservation(ready):
    c,s,p=ready;a=c['accounts'];day=c['w3'].eth.get_block('latest').timestamp//86400;zero=bytes(32)
    call=lambda amount:p.functions.seedUsageForMigration(day,[a[3]],[zero],[amount],[0])
    fails(c,call(100),a[3]);tx(c,call(100),a[5]);tx(c,call(50),a[5])
    assert p.functions.allowance(a[3]).call()[4]==100
    fails(c,p.functions.seedUsageForMigration(day-1,[a[3]],[zero],[200],[0]),a[5])
    _,operation,sender=reserve(ready,'migration');tx(c,operation,sender)
    fails(c,call(200),a[5])
    assert p.functions.allowance(a[3]).call()[4]==100

def test_rejecting_treasury_defers_revenue_without_locking_user_allowance(ready):
    import solcx
    c,s,p=ready;a=c['accounts']
    source='''pragma solidity ^0.8.20;
      interface I { function claimWorkerRevenue(address payable to,uint amount) external; }
      contract RejectingTreasury {
        address immutable owner=msg.sender;
        receive() external payable { revert(); }
        function claim(address engine,address payable to,uint amount) external { require(msg.sender==owner); I(engine).claimWorkerRevenue(to,amount); }
      }'''
    # Select the concrete treasury, not its interface.
    output=solcx.compile_source(source,output_values=['abi','bin'],solc_version='0.8.37')
    artifact=output['<stdin>:RejectingTreasury']
    receipt=tx(c,c['w3'].eth.contract(abi=artifact['abi'],bytecode=artifact['bin']).constructor())
    treasury=c['w3'].eth.contract(address=receipt.contractAddress,abi=artifact['abi'])
    tx(c,s.functions.configureWorker(a[2],treasury.address))
    key,call,sender=reserve(ready,'rejecting-treasury');tx(c,call,sender)
    tx(c,s.functions.settleWorker(key,123,Web3.keccak(text='receipt')),a[2])
    owed=s.functions.unpaidWorkerRevenue(treasury.address).call()
    assert owed>=123 and p.functions.pendingReservations().call()==0 and s.functions.pendingWorkerCost(a[4]).call()==0
    fails(c,s.functions.claimWorkerRevenue(a[6],owed),a[6])
    before=c['w3'].eth.get_balance(a[8]);tx(c,treasury.functions.claim(s.address,a[8],owed))
    assert c['w3'].eth.get_balance(a[8])==before+owed and s.functions.unpaidWorkerRevenue(treasury.address).call()==0


def test_a_reservation_counts_as_an_operation(ready):
    # X-19 (1.5.2): before, a worker could reserve without limit but the wei caps; now each reservation is one of the day's ops.
    c,s,p=ready;a=c['accounts']
    tx(c,s.functions.setSponsorOpsPerDay(a[4],1))
    _,call,sender=reserve(ready,'only-one');tx(c,call,sender)
    assert s.functions.sponsorOps(a[4]).call()==[1,1]
    _,call,sender=reserve(ready,'second-today',wallet=a[6]);fails(c,call,sender)
    c['tester'].time_travel((c['w3'].eth.get_block('latest').timestamp//86400+1)*86400+1);c['tester'].mine_blocks(1)
    assert s.functions.sponsorOps(a[4]).call()==[1,0]
    _,call,sender=reserve(ready,'tomorrow',wallet=a[6]);tx(c,call,sender)


def test_unreachable_revenue_is_redirected_by_the_platform_admin_only(ready):
    # X-57 (1.5.2): a treasury that rejects coin AND cannot call claimWorkerRevenue used to strand its revenue forever.
    import solcx
    c,s,p=ready;a=c['accounts']
    source='pragma solidity ^0.8.20; contract Sink { receive() external payable { revert(); } }'
    art=solcx.compile_source(source,output_values=['abi','bin'],solc_version='0.8.37')['<stdin>:Sink']
    sink=tx(c,c['w3'].eth.contract(abi=art['abi'],bytecode=art['bin']).constructor()).contractAddress
    tx(c,s.functions.configureWorker(a[2],sink))
    key,call,sender=reserve(ready,'stranded');tx(c,call,sender)
    tx(c,s.functions.settleWorker(key,123,Web3.keccak(text='receipt')),a[2])
    owed=s.functions.unpaidWorkerRevenue(sink).call();assert owed>=123
    fails(c,s.functions.redirectWorkerRevenue(sink,a[7]),a[5])                   # not the manager
    fails(c,s.functions.redirectWorkerRevenue(sink,a[7]),a[7])                   # nor the claimant
    fails(c,s.functions.redirectWorkerRevenue(sink,sink))                        # nor to itself
    fails(c,s.functions.redirectWorkerRevenue(a[9],a[7]))                        # nothing owed: nothing to move
    r=tx(c,s.functions.redirectWorkerRevenue(sink,a[7]))
    assert s.events.WorkerRevenueRedirected().process_receipt(r,errors=DISCARD)[0]['args']['amount']==owed
    assert s.functions.unpaidWorkerRevenue(sink).call()==0 and s.functions.unpaidWorkerRevenue(a[7]).call()==owed
    before=c['w3'].eth.get_balance(a[9]);tx(c,s.functions.claimWorkerRevenue(a[9],owed),a[7])
    assert c['w3'].eth.get_balance(a[9])==before+owed
