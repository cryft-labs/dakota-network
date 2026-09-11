"""Reject any allocation/header change disguised as the approved BPO insertion."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('genesis_stage',Path(__file__).parents[1]/'stage-genesis.py')
stage=importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

class BpoGenesisGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.path=Path(self.directory.name)/'genesis.json'
        self.old=b'{"config": {\n        "bpo2Time": 0,\n"chainId":112311},"alloc":{"account":{"balance":"1"}}}\n'
        self.digest=hashlib.sha256(self.old).hexdigest()
        self.new=self.old.replace(b'"chainId"',stage.BPO_INSERT+b'"chainId"',1)
    def tearDown(self):
        self.directory.cleanup()
    def verify(self,data):
        self.path.write_bytes(data)
        with patch.object(stage,'BPO2_GENESIS_SHA',self.digest):
            stage.verify_bpo_only_change(self.path)
    def test_exact_insertion(self):
        self.verify(self.new)
    def test_allocation_change_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.verify(self.new.replace(b'"balance":"1"',b'"balance":"2"'))
    def test_chain_identity_change_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.verify(self.new.replace(b'112311',b'112312'))
    def test_duplicate_insertions_are_rejected(self):
        with self.assertRaises(AssertionError):
            self.verify(self.new.replace(stage.BPO_INSERT,stage.BPO_INSERT*2))
    def test_insertion_inside_alloc_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.verify(self.old.replace(b'"account"',stage.BPO_INSERT+b'"account"'))

if __name__=='__main__':unittest.main()
