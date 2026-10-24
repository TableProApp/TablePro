from pathlib import Path
import fcntl
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ci-cache.py'


class CiCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.cache = self.directory / 'target'
        self.cache.mkdir()
        self.lock = self.directory / 'cache.lock'
        self.lock.touch()
        self.command = [sys.executable, str(SCRIPT), '--root', str(self.cache), '--lock', str(self.lock)]

    def target(self, name, age_days):
        target = self.cache / name
        (target / 'debug/deps').mkdir(parents=True)
        (target / 'debug/.cargo-lock').touch()
        (target / 'debug/deps/artifact').write_text('compiled bytes')
        marker = target / '.bookie-last-used'
        marker.touch()
        timestamp = time.time() - age_days * 86400
        os.utime(marker, (timestamp, timestamp))
        return target

    def cleanup(self, reserve=0):
        return subprocess.run(self.command + ['cleanup', '--min-free-gib', str(reserve)], capture_output=True, text=True)

    def test_old_generated_artifacts_removed_but_siblings_preserved(self):
        target = self.target('sandbox', 6)
        for profile in ('release', 'ci'):
            (target / profile / 'deps').mkdir(parents=True)
            (target / profile / '.cargo-lock').touch()
            (target / profile / 'deps/artifact').write_text('compiled bytes')
        (target / 'evidence.txt').write_text('keep')
        result = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((target / 'debug').exists())
        self.assertFalse((target / 'release').exists())
        self.assertFalse((target / 'ci').exists())
        self.assertEqual((target / 'evidence.txt').read_text(), 'keep')

    def test_recent_nightly_cache_and_unmarked_legacy_cache_survive(self):
        target = self.target('nightly-values', 0)
        old = time.time() - 10 * 86400
        os.utime(target, (old, old))
        legacy = self.target('legacy', 10)
        (legacy / '.bookie-last-used').unlink()
        result = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((target / 'debug/deps/artifact').exists())
        self.assertTrue((legacy / 'debug/deps/artifact').exists())

    def test_pressure_cleanup_evicts_the_least_recent_marked_cache_to_recover_reserve(self):
        oldest = self.target('oldest', 0.5)
        newest = self.target('newest', 0.1)
        spec = importlib.util.spec_from_file_location('ci_cache', SCRIPT)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)

        def disk_usage(_):
            recovered = not (oldest / 'debug').exists()
            return SimpleNamespace(free=100 if recovered else 0)

        with patch.object(helper.shutil, 'disk_usage', side_effect=disk_usage):
            result = helper.cleanup(self.cache, 50)

        self.assertEqual(result, 0)
        self.assertFalse((oldest / 'debug').exists())
        self.assertTrue((newest / 'debug/deps/artifact').exists())

    def test_pressure_cleanup_reports_unrecovered_reserve_after_evicting_marked_caches(self):
        idle = self.target('unit', 2)
        recent = self.target('sandbox', 0)
        legacy = self.target('legacy', 0)
        (legacy / '.bookie-last-used').unlink()
        result = self.cleanup(10**9)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse((idle / 'debug').exists())
        self.assertFalse((recent / 'debug').exists())
        self.assertTrue((legacy / 'debug/deps/artifact').exists())
        self.assertIn('reserve', result.stderr)

    def test_pressure_cleanup_stops_after_recovering_the_reserve(self):
        first = self.target('a-idle', 2)
        second = self.target('b-idle', 2)
        spec = importlib.util.spec_from_file_location('ci_cache', SCRIPT)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        readings = [SimpleNamespace(free=value) for value in (0, 0, 0, 100, 100, 100)]
        with patch.object(helper.shutil, 'disk_usage', side_effect=readings):
            result = helper.cleanup(self.cache, 50)
        self.assertTrue((second / 'debug/deps/artifact').exists())
        self.assertFalse((first / 'debug').exists())
        self.assertEqual(result, 0)

    def test_checkout_refuses_to_run_when_cleanup_cannot_restore_the_reserve(self):
        self.target('unit', 0)
        shell = self.directory / 'checkout.sh'
        shell.write_text('touch "$SENTINEL"\n')
        sentinel = self.directory / 'sentinel'
        env = dict(os.environ, SENTINEL=str(sentinel))
        result = subprocess.run(
            self.command + ['checkout', '--min-free-gib', '100000', str(shell)],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertIn('reserve', result.stderr)

    def test_checkout_holds_the_shared_cache_lock_for_the_workspace_script(self):
        shell = self.directory / 'checkout.sh'
        sentinel = self.directory / 'sentinel'
        shell.write_text(
            '"$PYTHON" "$HELPER" --root "$CACHE" --lock "$LOCK" cleanup --min-free-gib 0 > "$SENTINEL"\n'
        )
        env = dict(
            os.environ,
            CACHE=str(self.cache),
            HELPER=str(SCRIPT),
            LOCK=str(self.lock),
            PYTHON=sys.executable,
            SENTINEL=str(sentinel),
            CARGO_TARGET_DIR=str(self.cache / 'unit'),
        )
        with self.lock.open('r+') as active_job:
            fcntl.flock(active_job, fcntl.LOCK_SH)
            result = subprocess.run(
                self.command + ['checkout', '--min-free-gib', '0', str(shell)],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('cache busy; cleanup skipped', sentinel.read_text())
        self.assertTrue((self.cache / 'unit/.bookie-last-used').is_file())

    def test_shared_build_lock_prevents_cleanup(self):
        target = self.target('unit', 10)
        with self.lock.open('r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
            result = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((target / 'debug/deps/artifact').exists())
        self.assertIn('busy', result.stdout)

    def test_symlink_targets_profiles_and_markers_do_not_delete_external_data(self):
        outside = self.directory / 'outside'
        (outside / 'deps').mkdir(parents=True)
        (outside / '.cargo-lock').touch()
        (outside / 'deps/valuable').write_text('keep')
        (self.cache / 'linked-job').symlink_to(outside, target_is_directory=True)
        target = self.target('linked-profile', 10)
        (target / 'debug').rename(target / 'saved')
        (target / 'debug').symlink_to(outside, target_is_directory=True)
        (target / 'ci').symlink_to(outside, target_is_directory=True)
        marked = self.target('linked-marker', 10)
        (marked / '.bookie-last-used').unlink()
        (marked / '.bookie-last-used').symlink_to(outside / '.cargo-lock')
        result = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((outside / 'deps/valuable').read_text(), 'keep')
        self.assertTrue((marked / 'debug/deps/artifact').exists())

    def test_non_cargo_directory_survives(self):
        target = self.target('unit', 10)
        (target / 'debug/.cargo-lock').unlink()
        result = self.cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((target / 'debug/deps/artifact').exists())

    def test_shell_keeps_shared_lock_until_child_finishes_and_updates_usage(self):
        target = self.target('unit', 10)
        ready = self.directory / 'ready'
        release = self.directory / 'release'
        shell = self.directory / 'step.sh'
        shell.write_text('touch "$READY"\nwhile [ ! -e "$RELEASE" ]; do sleep 0.02; done\nexit 7\n')
        env = dict(os.environ, CARGO_TARGET_DIR=str(target), READY=str(ready), RELEASE=str(release))
        child = subprocess.Popen(self.command + ['run', str(shell)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), 'wrapped shell did not start')
            with self.lock.open('r+') as lock:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertGreater((target / '.bookie-last-used').stat().st_mtime, time.time() - 30)
            result = self.cleanup()
            self.assertIn('busy', result.stdout)
        finally:
            release.touch()
            try:
                stdout, stderr = child.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.communicate()
                raise
        self.assertEqual(child.returncode, 7, stderr)
        self.assertTrue((target / 'debug/deps/artifact').exists())
        with self.lock.open('r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_background_descendant_does_not_keep_shared_lock_after_shell_exits(self):
        child_pid = self.directory / 'child.pid'
        shell = self.directory / 'step.sh'
        shell.write_text(
            '$PYTHON -c "import os, pathlib, time; pid=os.fork(); '
            'pathlib.Path(os.environ[\'CHILD_PID\']).write_text(str(pid)) if pid else None; '
            '(os.close(1), os.close(2), time.sleep(30)) if pid == 0 else None"\n'
        )
        env = dict(os.environ, CARGO_TARGET_DIR=str(self.cache / 'unit'), PYTHON=sys.executable, CHILD_PID=str(child_pid))
        try:
            result = subprocess.run(self.command + ['run', str(shell)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            with self.lock.open('r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            if child_pid.exists():
                os.kill(int(child_pid.read_text()), 15)

    def test_termination_reaches_the_shell_and_releases_the_shared_lock(self):
        child_pid = self.directory / 'child.pid'
        shell = self.directory / 'step.sh'
        shell.write_text('echo "$$" > "$CHILD_PID"\nexec sleep 30\n')
        env = dict(os.environ, CARGO_TARGET_DIR=str(self.cache / 'unit'), CHILD_PID=str(child_pid))
        process = subprocess.Popen(self.command + ['run', str(shell)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not child_pid.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(child_pid.exists(), 'wrapped shell did not start')
            process.send_signal(signal.SIGTERM)
            _stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, stderr.decode())
            with self.lock.open('r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            if child_pid.exists():
                try:
                    os.killpg(int(child_pid.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_shell_rejects_target_outside_cache_and_enforces_pipefail(self):
        shell = self.directory / 'step.sh'
        shell.write_text('false | true\ntouch "$SENTINEL"\n')
        sentinel = self.directory / 'sentinel'
        env = dict(os.environ, CARGO_TARGET_DIR=str(self.directory / 'outside'), SENTINEL=str(sentinel))
        result = subprocess.run(self.command + ['run', str(shell)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(sentinel.exists())
        env['CARGO_TARGET_DIR'] = str(self.cache / 'unit')
        result = subprocess.run(self.command + ['run', str(shell)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertTrue((self.cache / 'unit/.bookie-last-used').is_file())

    def test_workflows_wrap_all_shell_steps_with_the_cache_lock(self):
        for filename in ('ci.yml', 'nightly.yml'):
            workflow = (ROOT / '.forgejo/workflows' / filename).read_text()
            self.assertIn('defaults:\n  run:\n    shell: /usr/local/libexec/bookie-ci-cache run {0}\n', workflow)
            self.assertEqual(workflow.count('shell: /usr/local/libexec/bookie-ci-cache run {0}'), 1)
            for step in workflow.split('      - name: ')[1:]:
                if 'uses:' in step:
                    self.assertRegex(step, r'(?m)^          path: (gtk|floor)-artifact/$')
                    self.assertNotIn('path: /var/cache/', step)
                    self.assertNotIn('path: ${{ env.CARGO_TARGET_DIR }}', step)

    def test_every_forgejo_checkout_recovers_cache_before_writing_workspace(self):
        for filename in ('ci.yml', 'nightly.yml'):
            workflow = (ROOT / '.forgejo/workflows' / filename).read_text()
            checkout_steps = workflow.split('      - name: Check out\n')[1:]
            self.assertTrue(checkout_steps, filename)
            for block in checkout_steps:
                step = block.split('\n      - name:', 1)[0]
                self.assertIn('shell: /usr/local/libexec/bookie-ci-cache checkout {0}', step, filename)
                self.assertLess(step.index('shell:'), step.index('run:'), filename)

    def test_missing_or_symlink_lock_fails_closed(self):
        self.lock.unlink()
        for symlink in (False, True):
            if symlink:
                self.lock.symlink_to(self.directory / 'unrelated')
            result = self.cleanup()
            self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse((self.directory / 'unrelated').exists())


if __name__ == '__main__':
    unittest.main()
