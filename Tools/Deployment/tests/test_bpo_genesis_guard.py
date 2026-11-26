"""stage-genesis.py accepts only the committed Cryft genesis whose hash matches its manifest."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('genesis_stage', Path(__file__).parents[1] / 'stage-genesis.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class GenesisGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.release = Path(self.directory.name)
        (self.release / 'Contracts/Genesis').mkdir(parents=True)
        self.write({'chainId': 113211, 'contractSizeLimit': 32768})

    def tearDown(self):
        self.directory.cleanup()

    def write(self, config, manifest_chain=113211, manifest_hash=None):
        data = json.dumps({'config': config, 'alloc': {}}).encode()
        (self.release / 'Contracts/Genesis/CryftGenesis.json').write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        (self.release / 'Contracts/Genesis/genesis-release.json').write_text(json.dumps(
            {'chainId': manifest_chain, 'genesis_file': 'Contracts/Genesis/CryftGenesis.json',
             'genesis_sha256': manifest_hash or digest}))
        self.digest = digest

    def test_committed_genesis_is_accepted(self):
        stage.verify_release(self.release, self.digest)

    def test_wrong_expected_hash_is_rejected(self):
        with self.assertRaises(AssertionError):
            stage.verify_release(self.release, '0' * 64)

    def test_manifest_hash_mismatch_is_rejected(self):
        self.write({'chainId': 113211, 'contractSizeLimit': 32768}, manifest_hash='1' * 64)
        with self.assertRaises(AssertionError):
            stage.verify_release(self.release, self.digest)

    def test_other_chain_id_is_rejected(self):
        self.write({'chainId': 112311, 'contractSizeLimit': 32768}, manifest_chain=112311)
        with self.assertRaises(AssertionError):
            stage.verify_release(self.release, self.digest)

    def test_size_limit_is_required(self):
        self.write({'chainId': 113211, 'contractSizeLimit': 24576})
        with self.assertRaises(AssertionError):
            stage.verify_release(self.release, self.digest)


if __name__ == '__main__':
    unittest.main()
