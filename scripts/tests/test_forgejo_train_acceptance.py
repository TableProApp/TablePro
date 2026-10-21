import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('train_acceptance', ROOT / 'scripts/check-forgejo-train.py')
TRAIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRAIN)


class TrainAcceptanceTests(unittest.TestCase):
    def test_manifest_refuses_missing_duplicate_and_invalid_pins(self):
        members = [{'number': 7, 'sha': 'a' * 40}, {'number': 8, 'sha': 'b' * 40}]
        manifest = {'version': 1, 'base': 'c' * 40, 'members': members}
        self.assertEqual(TRAIN.manifest_members(manifest), members)
        invalid = [[], {}, {**manifest, 'base': 'linux'}, {**manifest, 'members': members[:1]},
                   {**manifest, 'members': [members[0], members[0]]},
                   {**manifest, 'members': [{'number': 7, 'sha': '--bad'}, members[1]]}]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                TRAIN.manifest_members(value)

    def test_reference_failure_cannot_hide_a_missing_or_failed_required_check(self):
        checks = [{'name': name, 'state': 'SUCCESS', 'workflow': ''} for name in TRAIN.REQUIRED_CHECKS]
        checks.append({'name': 'SonarCloud Code Analysis', 'state': 'FAILURE', 'workflow': ''})
        TRAIN.check_results(checks)
        for state in ('FAILURE', 'PENDING', 'CANCELLED', 'SKIPPED'):
            changed = [dict(c) for c in checks]
            changed[0]['state'] = state
            with self.subTest(state=state), self.assertRaises(ValueError):
                TRAIN.check_results(changed)
        with self.assertRaises(ValueError):
            TRAIN.check_results(checks[1:])

    def test_only_the_successful_merge_workflow_at_the_exact_head_is_accepted(self):
        run = {'id': 42, 'commit_sha': 'a' * 40, 'workflow_id': 'ci.yml', 'status': 'success'}
        TRAIN.check_gate(run, 42, 'a' * 40)
        for field, value in [('id', 41), ('commit_sha', 'b' * 40), ('workflow_id', 'nightly.yml'),
                             ('status', 'running'), ('status', 'failure'), ('status', 'cancelled')]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                TRAIN.check_gate({**run, field: value}, 42, 'a' * 40)


class TrainIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git('init', '--quiet', '--initial-branch=linux')
        self.git('config', 'user.name', 'Train Test')
        self.git('config', 'user.email', 'train@example.invalid')
        self.base = self.commit('base')
        self.git('checkout', '--quiet', '-b', 'a')
        self.a = self.commit('a')
        self.git('checkout', '--quiet', '-b', 'b', self.base)
        self.b = self.commit('b')
        self.git('checkout', '--quiet', '-b', 'train', self.base)
        for sha in (self.a, self.b):
            self.git('merge', '--quiet', '--no-ff', '-m', 'include', sha)
        self.head = self.git('rev-parse', 'HEAD')
        self.members = [{'number': 7, 'sha': self.a}, {'number': 8, 'sha': self.b}]
        self.patcher = patch.object(TRAIN, 'command', self.command)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def command(self, *args):
        return subprocess.check_output(args, cwd=self.repo, text=True).strip()

    def git(self, *args):
        return self.command('git', *args)

    def commit(self, name):
        (self.repo / name).write_text(name)
        self.git('add', name)
        self.git('commit', '--quiet', '-m', name)
        return self.git('rev-parse', 'HEAD')

    def test_real_merge_history_accepts_only_the_pinned_order_and_heads(self):
        TRAIN.check_integration(self.base, self.head, self.members)
        for members in (list(reversed(self.members)), self.members[:1],
                        [self.members[0], {'number': 8, 'sha': self.base}]):
            with self.subTest(members=members), self.assertRaises(ValueError):
                TRAIN.check_integration(self.base, self.head, members)

    def test_a_new_linux_tip_requires_a_new_train_base(self):
        self.git('checkout', '--quiet', 'linux')
        new_base = self.commit('later')
        self.git('checkout', '--quiet', 'train')
        self.git('merge', '--quiet', '--no-ff', '-m', 'late base', new_base)
        head = self.git('rev-parse', 'HEAD')
        with self.assertRaises(ValueError):
            TRAIN.check_integration(new_base, head, self.members)

    def test_squash_commit_may_change_identity_but_must_preserve_the_tested_tree(self):
        self.git('commit', '--quiet', '--allow-empty', '-m', 'different commit identity')
        identical_tree = self.git('rev-parse', 'HEAD')
        TRAIN.check_merged_tree(identical_tree, self.head)
        changed = self.commit('unexpected')
        with self.assertRaises(ValueError):
            TRAIN.check_merged_tree(changed, self.head)

    def test_fetch_refuses_a_head_that_changed_after_the_api_snapshot(self):
        self.git('remote', 'add', 'origin', str(self.repo))
        self.git('update-ref', 'refs/pull/9/head', self.head)
        TRAIN.fetch_head('origin', {'number': 9, 'headRefOid': self.head})
        self.git('update-ref', 'refs/pull/9/head', self.a)
        with self.assertRaises(ValueError):
            TRAIN.fetch_head('origin', {'number': 9, 'headRefOid': self.head})

    def test_pre_merge_check_rejects_a_moving_constituent_or_base(self):
        (self.repo / 'ci').mkdir()
        manifest = {'version': 1, 'base': self.base, 'members': self.members}
        (self.repo / TRAIN.MANIFEST).write_text(json.dumps(manifest))
        self.git('add', TRAIN.MANIFEST)
        self.git('commit', '--quiet', '-m', 'record manifest')
        head = self.git('rev-parse', 'HEAD')
        states = {
            number: {'number': number, 'headRefOid': sha, 'baseRefName': 'linux', 'state': 'OPEN',
                     'isDraft': False, 'reviewDecision': '', 'mergeable': 'MERGEABLE'}
            for number, sha in [(9, head), (7, self.a), (8, self.b)]
        }
        checks = [{'name': n, 'state': 'SUCCESS', 'workflow': ''} for n in TRAIN.REQUIRED_CHECKS]
        gate = {'id': 42, 'commit_sha': head, 'workflow_id': 'ci.yml', 'status': 'success'}
        self.git('remote', 'add', 'origin', str(self.repo))
        with patch('sys.argv', ['check-forgejo-train.py', '9', '--phase', 'merge', '--run', '42']), \
                patch.object(TRAIN, 'pull_request', side_effect=lambda n: dict(states[n])), \
                patch.object(TRAIN, 'fetch_head'), patch.object(TRAIN, 'github_checks', return_value=checks), \
                patch.object(TRAIN, 'forgejo_run', return_value=gate), \
                patch.object(TRAIN, 'linux_head', return_value=self.base):
            TRAIN.main()
            dirty = self.repo / 'untracked'
            dirty.write_text('pending work')
            with self.assertRaises(ValueError):
                TRAIN.main()
            dirty.unlink()
            self.git('checkout', '--quiet', 'a')
            with self.assertRaises(ValueError):
                TRAIN.main()
            self.git('checkout', '--quiet', 'train')
            states[7]['headRefOid'] = self.b
            with self.assertRaises(ValueError):
                TRAIN.main()
            states[7]['headRefOid'] = self.a
            with patch.object(TRAIN, 'linux_head', return_value=self.a), self.assertRaises(ValueError):
                TRAIN.main()
            with patch('sys.argv', ['check-forgejo-train.py', '9', '--phase', 'gate']):
                TRAIN.main()
            states[9].update(state='MERGED', mergeCommit={'oid': head})
            with patch('sys.argv', ['check-forgejo-train.py', '9', '--phase', 'merged', '--run', '42']):
                TRAIN.main()


if __name__ == '__main__':
    unittest.main()
