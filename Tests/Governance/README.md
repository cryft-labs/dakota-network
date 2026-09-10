# Local governance regression tests

These tests compile the actual contracts and execute transactions in an isolated Python EVM with ephemeral test accounts. They do not contact a running Dakota chain, use real keys, publish IPFS files, or deploy to servers.

Create an isolated Python environment, install `requirements.txt`, and install the two pinned compilers:

```sh
python -m pip install -r Tests/Governance/requirements.txt
python -c "import solcx; solcx.install_solc('0.8.19'); solcx.install_solc('0.8.34')"
python -m pytest Tests/Governance/test_governance.py -q
python Tools/SolcCompiler/check_gas_sponsor.py
```

The first compile may fetch pinned OpenZeppelin imports through the repository compiler. Later runs reuse its ignored import cache. Validator compilation explicitly selects Solidity 0.8.19 and London; other public contracts select 0.8.34 and Osaka, with optimization at 200 runs. No IPFS endpoint is needed for these library-level compilation calls.

The suite covers membership-ballot completion, frozen quorum/expiry, duplicate members, provider outages and malformed responses, bounded sets, atomic handovers, validator minimums, raw Besu-compatible validator-list encoding, root rotation, management revocation, proxy/application storage separation, dynamic proxy upgrade authorization, initialization, beacon/admin handover cancellation, and funding after voter rotation. Runtime-size checks use Dakota's documented **32,768-byte** limit.

`runtime-sizes.json` is written under pytest's temporary session directory. Use `--basetemp PATH` and `--junitxml PATH` to archive evidence; choose a dedicated temporary path because pytest replaces it on the next run. Runtime sizes/hashes describe that run's compiler inputs and settings.

PyEVM tests do not prove that a live Besu deployment accepts Osaka or uses the intended size override. The current tested public builds also fit PyEVM's ordinary deployment limit. Before release, verify the pinned Besu binary, `config.contractSizeLimit`, actual QBFT registry reads and block production, final genesis storage, and complete service integration. See [the maintenance guide](../../Contracts/Genesis/GOVERNANCE.md) for known exceptions and operational steps.
