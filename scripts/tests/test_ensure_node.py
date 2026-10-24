import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "scripts/ensure-node.sh"


class EnsureNodeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.stubs = self.root / "bin"
        self.stubs.mkdir()
        body = SOURCE.read_text()
        self.version = re.search(r'VERSION="([^"]+)"', body)[1]
        binary = b"#!/bin/sh\necho fixture-node\n"
        self.archive = self.root / "node.tar.xz"
        with tarfile.open(self.archive, "w:xz") as archive:
            member = tarfile.TarInfo(f"node-v{self.version}-linux-x64/bin/node")
            member.size = len(binary)
            member.mode = 0o755
            archive.addfile(member, io.BytesIO(binary))
        body = re.sub(r'(?m)^SHA256="[a-f0-9]+"',
                      f'SHA256="{hashlib.sha256(self.archive.read_bytes()).hexdigest()}"', body)
        body = re.sub(r'(?m)^BINARY_SHA256="[a-f0-9]+"',
                      f'BINARY_SHA256="{hashlib.sha256(binary).hexdigest()}"', body)
        self.script = self.root / "ensure-node.sh"
        self.script.write_text(body)
        curl = self.stubs / "curl"
        curl.write_text('#!/bin/sh\nprintf called >> "$CALLS"\nwhile [ "$1" != "-o" ]; do shift; done\ncp "$ARCHIVE" "$2"\n')
        curl.chmod(0o755)
        self.environment = {
            **os.environ, "PATH": f"{self.stubs}:{os.environ['PATH']}",
            "TABLEPRO_TOOL_DIR": str(self.root / "tools"), "ARCHIVE": str(self.archive),
            "CALLS": str(self.root / "calls"),
        }

    def run_installer(self):
        return subprocess.run(["bash", str(self.script)], env=self.environment, text=True, capture_output=True)

    def test_a_verified_runtime_is_reused_without_downloading(self):
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.run_installer()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((self.root / "calls").read_text(), "called")
        self.assertEqual(subprocess.check_output([str(Path(second.stdout.strip()) / "node")], text=True), "fixture-node\n")

    def test_changed_cached_bytes_are_replaced_by_verified_bytes(self):
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stderr)
        (Path(first.stdout.strip()) / "node").write_bytes(b"changed")
        second = self.run_installer()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((self.root / "calls").read_text(), "calledcalled")

    def test_an_invalid_download_is_not_installed(self):
        self.archive.write_bytes(b"corrupt")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list((self.root / "tools").rglob("node")), [])

    def test_an_unverified_cached_symlink_does_not_overwrite_its_target(self):
        original = self.root / "unrelated"
        original.write_text("preserve this file")
        cached = self.root / "tools" / f"node-{self.version}" / "node"
        cached.parent.mkdir(parents=True)
        cached.symlink_to(original)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(cached.is_symlink())
        self.assertEqual(original.read_text(), "preserve this file")

    def test_an_unpinned_architecture_is_refused_before_download(self):
        uname = self.stubs / "uname"
        uname.write_text("#!/bin/sh\necho aarch64\n")
        uname.chmod(0o755)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "calls").exists())


if __name__ == "__main__":
    unittest.main()
