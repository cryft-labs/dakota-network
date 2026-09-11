import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'enroll-nebula.py'
CODE = 'test-enrollment-code-never-real-123456789'
OLD, NEW = '100.111.69.101', '100.111.69.1'


class EnrollmentTests(unittest.TestCase):
    def exercise(self, replace=False, failure=False, timeout=False):
        state = {'address': OLD, 'enrolled': False, 'restarted': False}
        def run(args, **kwargs):
            if args[0] == 'ip':
                return subprocess.CompletedProcess(args, 0, json.dumps([
                    {'addr_info': [{'local': state['address']}]}]), '')
            if args[0] == '/usr/bin/dnclient':
                state['enrolled'] = True
                if timeout:
                    raise subprocess.TimeoutExpired(args, 60)
                return subprocess.CompletedProcess(args, int(failure), CODE, '')
            if args == ['systemctl', 'restart', 'dnclient']:
                state.update(address=NEW, restarted=True)
                return subprocess.CompletedProcess(args, 0, '', '')
            raise AssertionError(args)
        payload = {'code': CODE, 'nebula_ip': NEW, 'replace_existing': replace}
        output = io.StringIO()
        with patch('sys.stdin', io.StringIO(json.dumps(payload))), \
                patch('subprocess.run', side_effect=run), \
                contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as exc:
                runpy.run_path(str(SCRIPT), run_name='__main__')
        self.assertNotIn(CODE, output.getvalue())
        return state, json.loads(output.getvalue()), exc.exception.code

    def test_preserves_existing_identity_by_default(self):
        state, result, code = self.exercise()
        self.assertFalse(state['enrolled'])
        self.assertEqual(result['enrollment'], 'already_enrolled')
        self.assertEqual(code, 0)

    def test_explicit_replacement_restarts_and_checks_new_address(self):
        state, result, code = self.exercise(replace=True)
        self.assertTrue(state['restarted'])
        self.assertTrue(result['address_matches'])
        self.assertEqual(code, 0)

    def test_rejected_enrollment_does_not_restart(self):
        state, _, code = self.exercise(replace=True, failure=True)
        self.assertFalse(state['restarted'])
        self.assertNotEqual(code, 0)

    def test_timeout_does_not_expose_secret_or_claim_success(self):
        state, result, code = self.exercise(replace=True, timeout=True)
        self.assertFalse(state['restarted'])
        self.assertEqual(result['enrollment'], 'timeout_outcome_unknown')
        self.assertNotEqual(code, 0)


if __name__ == '__main__':
    unittest.main()
