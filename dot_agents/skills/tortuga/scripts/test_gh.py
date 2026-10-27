"""Offline checks: python3 scripts/test_gh.py (no credentials/network)."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('tortuga_gh', Path(__file__).with_name('gh.py'))
assert spec is not None and spec.loader is not None
gh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gh)


class TargetTests(unittest.TestCase):
    def test_github_remote_forms(self):
        for remote in ['git@github.com:Owner/Repo.git', 'https://github.com/Owner/Repo.git',
                       'ssh://git@github.com/Owner/Repo.git']:
            self.assertEqual(gh.repo_from_remote(remote), 'Owner/Repo')

    def test_refuses_unsafe_or_non_github_targets(self):
        for remote in ['file:///a/b', 'https://gitlab.com/a/b', 'https://github.com/a/b/extra']:
            with self.assertRaises(ValueError):
                gh.repo_from_remote(remote)
        for value in ['../repo', 'owner/repo;command', 'owner/repo/extra']:
            with self.assertRaises(ValueError):
                gh.validate_repo(value)

    def test_explicit_target_and_ephemeral_auth(self):
        results = [subprocess.CompletedProcess([], 0, 'opaque-fixture\n', ''),
                   subprocess.CompletedProcess([], 0)]
        with patch.object(gh.subprocess, 'run', side_effect=results) as run:
            self.assertEqual(gh.main(['--repo', 'Owner/Repo', 'issue', 'list']), 0)
        self.assertIn('REPO=Owner/Repo', run.call_args_list[0].args[0])
        self.assertEqual(run.call_args_list[1].args[0], ['gh', 'issue', 'list', '--repo', 'Owner/Repo'])
        self.assertEqual(run.call_args_list[1].kwargs['env']['GH_TOKEN'], 'opaque-fixture')

    def test_refuses_second_target_before_token_creation(self):
        with patch.object(gh.subprocess, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gh.main(['--repo', 'Owner/Repo', 'issue', 'list', '--repo', 'Other/Repo']), 1)
            run.assert_not_called()

    def test_refuses_foreign_positional_url_before_token_creation(self):
        for url in ['https://github.com/Owner/Other/issues/1', 'https://github.com/Other/Repo/pull/2',
                    'https://ghe.example.com/Owner/Repo/issues/3']:
            with patch.object(gh.subprocess, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(gh.main(['--repo', 'Owner/Repo', 'issue', 'comment', url, '--body', 'x']), 1)
                run.assert_not_called()

    def test_accepts_matching_positional_url_and_url_body_text(self):
        argv = ['--repo', 'Owner/Repo', 'pr', 'comment', 'https://github.com/owner/repo/pull/2',
                '--body', 'https://github.com/Other/Repo/issues/1']
        results = [subprocess.CompletedProcess([], 0, 'opaque-fixture\n', ''),
                   subprocess.CompletedProcess([], 0)]
        with patch.object(gh.subprocess, 'run', side_effect=results) as run:
            self.assertEqual(gh.main(argv), 0)
        self.assertEqual(run.call_args_list[1].args[0][:5],
                         ['gh', 'pr', 'comment', 'https://github.com/owner/repo/pull/2', '--body'])

    def test_timeouts_are_configurable(self):
        results = [subprocess.CompletedProcess([], 0, 'opaque-fixture\n', ''),
                   subprocess.CompletedProcess([], 0)]
        with patch.dict(gh.os.environ, {'TORTUGA_TOKEN_TIMEOUT': '7'}), \
                patch.object(gh.subprocess, 'run', side_effect=results) as run:
            self.assertEqual(gh.main(['--repo', 'Owner/Repo', 'issue', 'list']), 0)
        self.assertEqual(run.call_args_list[0].kwargs['timeout'], 7)
        with patch.dict(gh.os.environ, {'TORTUGA_TOKEN_TIMEOUT': 'soon'}), \
                patch.object(gh.subprocess, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gh.main(['--repo', 'Owner/Repo', 'issue', 'list']), 1)
            run.assert_not_called()

    def test_malformed_token_is_never_echoed(self):
        result = subprocess.CompletedProcess([], 0, 'opaque-fixture\nsecond-value', '')
        output = io.StringIO()
        with patch.object(gh.subprocess, 'run', return_value=result) as run, contextlib.redirect_stderr(output):
            self.assertEqual(gh.main(['--repo', 'Owner/Repo', 'repo']), 1)
            self.assertEqual(run.call_count, 1)
        self.assertNotIn('opaque-fixture', output.getvalue())


if __name__ == '__main__':
    unittest.main()
