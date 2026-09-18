import hashlib
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from ci_artifact import repository_from_origin
from verify_dmg import checksum, provenance


class AutomationTests(unittest.TestCase):
    def test_origin_targets_current_repository(self):
        for url in ['https://github.com/example/memos.git', 'git@github.com:example/memos.git',
                    'ssh://git@github.com/example/memos.git', 'https://github.com/example/memos']:
            self.assertEqual(repository_from_origin(url), 'example/memos')

    def test_unrecognized_origin_is_not_guessed(self):
        for url in ['/local/repo', 'https://other.example/example/memos', 'https://github.com/a/b/c']:
            with self.assertRaises(ValueError):
                repository_from_origin(url)

    def test_pr_head_is_used_instead_of_merge_sha(self):
        provenance({'build_sha': 'merge', 'pr_head_sha': 'head', 'run_id': '12'}, 'head', 12)

    def test_old_commit_and_wrong_run_are_rejected(self):
        for commit, run in [('old', 12), ('head', 13)]:
            with self.assertRaises(ValueError):
                provenance({'pr_head_sha': 'head', 'run_id': '12'}, commit, run)

    def test_push_build_uses_build_sha(self):
        provenance({'build_sha': 'head', 'pr_head_sha': '', 'run_id': '12'}, 'head', 12)

    def test_checksum_detects_tampering(self):
        with tempfile.TemporaryDirectory() as root:
            dmg = pathlib.Path(root) / 'test.dmg'
            dmg.write_bytes(b'fixture')
            digest = hashlib.sha256(b'fixture').hexdigest()
            pathlib.Path(str(dmg) + '.sha256').write_text(f'{digest}  test.dmg\n')
            self.assertEqual(checksum(dmg), digest)
            dmg.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                checksum(dmg)

    def test_checksum_cannot_point_outside_artifact(self):
        with tempfile.TemporaryDirectory() as root:
            dmg = pathlib.Path(root) / 'test.dmg'
            dmg.write_bytes(b'fixture')
            pathlib.Path(str(dmg) + '.sha256').write_text('abcd  ../../some-other-file\n')
            with self.assertRaises(ValueError):
                checksum(dmg)


if __name__ == '__main__':
    unittest.main()
