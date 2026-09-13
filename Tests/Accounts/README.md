# Token-bound account tests

Local PyEVM tests for the ERC-6551 review package. They compile
`Contracts/Accounts` with the repository SolcCompiler (0.8.37 / Osaka) and run
against ephemeral keys. They do not contact chain 112311 or deploy.

```sh
python -m pip install -r Tests/Governance/requirements.txt
python -m pytest Tests/Accounts/test_tba.py -q
```
