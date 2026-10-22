import ast
import builtins
import glob
import io
import importlib.util
import os
import select
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gtk_process_owned_tests", ROOT / "apps/linux/app/tests/gtk_process.py")
gtk_process = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gtk_process)


def ux_function(name, ui):
    source = ROOT / "apps/linux/app/tests/gtk_ux.py"
    tree = ast.parse(source.read_text())
    scenarios = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "scenarios")
    function = next(node for node in scenarios.body if isinstance(node, ast.FunctionDef) and node.name == name)
    namespace = dict(ui=ui, os=os, subprocess=subprocess)
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"), namespace)
    return namespace[name]


class GtkOwnedBoundaryTests(unittest.TestCase):
    def fake_file(self, path, mode="r", *args, **kwargs):
        pid = str(path).split("/")[2]
        if str(path).endswith("environ"):
            return io.BytesIO(b"FIXTURE=desktop\0" if pid == "101" else b"FIXTURE=owned\0")
        memory = "111" if pid == "101" else "222"
        return io.StringIO(f"VmRSS: {memory} kB\nVmHWM: 333 kB\n")

    def test_memory_uses_the_owned_fixture_with_two_matching_processes(self):
        owner = SimpleNamespace(memory_kb=lambda: (222, 333))
        function = ux_function("app_memory_kb", SimpleNamespace(owned_application=lambda: owner))
        for statuses in (["/proc/101/status", "/proc/202/status"], ["/proc/202/status", "/proc/101/status"]):
            with self.subTest(statuses=statuses):
                with patch.object(glob, "glob", return_value=statuses), patch.object(os, "readlink", return_value="/usr/bin/bookie"):
                    with patch.object(builtins, "open", side_effect=self.fake_file):
                        self.assertEqual(function(), (222, 333))

    def test_second_launch_uses_the_fixture_environment(self):
        environment = {"FIXTURE": "owned"}
        owner = SimpleNamespace(launch_again=lambda: subprocess.run(["/usr/bin/bookie"], env=environment, capture_output=True, text=True, timeout=30))
        ui = SimpleNamespace(owned_application=lambda: owner, wait_for_frame_containing=lambda text: None)
        function = ux_function("a_second_launch_raises_the_window_and_exits_cleanly", ui)
        result = subprocess.CompletedProcess([], 0, "", "asked it to show its window")
        with patch.object(glob, "glob", return_value=["/proc/101/status", "/proc/202/status"]):
            with patch.object(os, "readlink", return_value="/usr/bin/bookie"), patch.object(builtins, "open", side_effect=self.fake_file):
                with patch.object(subprocess, "run", return_value=result) as run:
                    function(None, None)
        self.assertEqual(run.call_args.kwargs["env"], environment)


class OwnedApplicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.binary = self.root / "bookie"
        self.binary.touch()
        self.code = None
        self.process = SimpleNamespace(pid=202, poll=lambda: self.code)
        self.make_process(101, 111)
        self.make_process(202, 222)
        self.environment = {"FIXTURE": "owned"}
        self.owner = gtk_process.OwnedApplication(self.process, self.binary, self.environment, self.root)

    def make_process(self, pid, memory, started=17):
        root = self.root / str(pid)
        root.mkdir(exist_ok=True)
        (root / "stat").write_text(f"{pid} (BookiE ) name) S " + "0 " * 18 + str(started))
        (root / "status").write_text(f"VmRSS: {memory} kB\nVmHWM: 333 kB\n")
        if not (root / "exe").exists():
            (root / "exe").symlink_to(self.binary)
        (root / "environ").write_text("UNRELATED_ENVIRONMENT_MUST_NOT_BE_READ")

    def test_only_the_owned_process_files_are_read(self):
        read_text = Path.read_text
        paths = []

        def record(path, *args, **kwargs):
            paths.append(path)
            return read_text(path, *args, **kwargs)

        with patch.object(Path, "read_text", record):
            self.assertEqual(self.owner.memory_kb(), (222, 333))
        self.assertEqual(set(paths), {self.root / "202/stat", self.root / "202/status"})

    def test_profile_metadata_identifies_the_owned_process_lifetime(self):
        self.assertEqual(self.owner.identity(), {"application_pid": 202, "application_start_ticks": 17})

    def test_an_exited_process_is_refused(self):
        self.code = 0
        with self.assertRaises(AssertionError):
            self.owner.memory_kb()

    def test_reusing_the_owned_pid_is_refused(self):
        self.make_process(202, 999, started=18)
        with self.assertRaises(AssertionError):
            self.owner.memory_kb()

    def test_a_different_executable_is_refused(self):
        other = self.root / "other"
        other.touch()
        (self.root / "202/exe").unlink()
        (self.root / "202/exe").symlink_to(other)
        with self.assertRaises(AssertionError):
            self.owner.memory_kb()

    def test_replacing_the_executable_at_the_same_path_is_refused(self):
        self.binary.rename(self.root / "previous-bookie")
        self.binary.touch()
        with self.assertRaises(AssertionError):
            self.owner.memory_kb()
        with patch.object(gtk_process.subprocess, "run") as run:
            with self.assertRaises(AssertionError):
                self.owner.launch_again()
        run.assert_not_called()

    def test_disappearing_identity_is_refused_without_falling_back(self):
        (self.root / "202/stat").unlink()
        with self.assertRaises(AssertionError):
            self.owner.memory_kb()

    def test_memory_is_rejected_if_the_process_exits_during_the_read(self):
        read_text = Path.read_text

        def finish(path, *args, **kwargs):
            text = read_text(path, *args, **kwargs)
            if path == self.root / "202/status":
                self.code = 0
            return text

        with patch.object(Path, "read_text", finish):
            with self.assertRaises(AssertionError):
                self.owner.memory_kb()

    def test_second_launch_reuses_a_copy_of_the_supplied_environment(self):
        self.environment["FIXTURE"] = "changed later"
        result = subprocess.CompletedProcess([], 0)
        with patch.object(gtk_process.subprocess, "run", return_value=result) as run:
            self.assertIs(self.owner.launch_again(), result)
        self.assertEqual(run.call_args.args[0], [str(self.binary)])
        self.assertEqual(run.call_args.kwargs["env"], {"FIXTURE": "owned"})

    def test_a_second_launch_is_refused_after_the_owner_exits(self):
        self.code = 0
        with patch.object(gtk_process.subprocess, "run") as run:
            with self.assertRaises(AssertionError):
                self.owner.launch_again()
        run.assert_not_called()

    def test_owner_exit_during_a_second_launch_is_not_reported_as_success(self):
        def finish(*args, **kwargs):
            self.code = 0
            return subprocess.CompletedProcess([], 0)

        with patch.object(gtk_process.subprocess, "run", side_effect=finish):
            with self.assertRaises(AssertionError):
                self.owner.launch_again()

    def test_memory_can_be_read_from_a_real_owned_child(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; print('ready', flush=True); time.sleep(30)"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        try:
            self.assertTrue(select.select([process.stdout], [], [], 5)[0])
            self.assertEqual(process.stdout.readline(), "ready\n")
            owner = gtk_process.OwnedApplication(process, sys.executable, {})
            resident, peak = owner.memory_kb()
            self.assertGreater(resident, 0)
            self.assertGreaterEqual(peak, resident)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            process.stdout.close()


if __name__ == "__main__":
    unittest.main()
