# Token-bound account and inventory tests

Local PyEVM tests for `Contracts/Accounts`. They compile the sources with the
repository SolcCompiler (0.8.37 / Osaka) and run against ephemeral keys. They
contact no network and deploy nothing.

```sh
python -m pip install -r Tests/Governance/requirements.txt
python -m pytest Tests/Accounts -q
```
