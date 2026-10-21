from pathlib import Path
import os
import re
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ensure-cargo-about.sh"

CURL_STUB = """#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$STUB_ARCHIVE" "$output"
"""

UNAME_STUB = """#!/usr/bin/env bash
echo "$STUB_MACHINE"
"""


def fake_archive(path):
    version = re.search(r'VERSION="([^"]+)"', SCRIPT.read_text()).group(1)
    name = f"cargo-about-{version}-x86_64-unknown-linux-musl"
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "cargo-about"
        binary.write_text("#!/bin/sh\necho not the real cargo-about\n")
        binary.chmod(0o755)
        with tarfile.open(path, "w:gz") as archive:
            archive.add(binary, arcname=f"{name}/cargo-about")


class EnsureCargoAboutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.tools = self.root / "tools"
        self.stubs = self.root / "bin"
        self.stubs.mkdir()
        for name, body in (("curl", CURL_STUB), ("uname", UNAME_STUB)):
            stub = self.stubs / name
            stub.write_text(body)
            stub.chmod(0o755)
        self.log = self.root / "log"
        self.log.write_text("")
        self.archive = self.root / "served.tar.gz"
        fake_archive(self.archive)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, machine="x86_64"):
        env = {
            **os.environ,
            "PATH": f"{self.stubs}:{os.environ['PATH']}",
            "TABLEPRO_TOOL_DIR": str(self.tools),
            "STUB_LOG": str(self.log),
            "STUB_ARCHIVE": str(self.archive),
            "STUB_MACHINE": machine,
        }
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)

    def downloads(self):
        return [line for line in self.log.read_text().splitlines() if line.startswith("curl ")]

    def test_a_cached_binary_that_does_not_match_the_pin_is_not_used(self):
        version = re.search(r'VERSION="([^"]+)"', SCRIPT.read_text()).group(1)
        cached = self.tools / f"cargo-about-{version}" / "cargo-about"
        cached.parent.mkdir(parents=True)
        cached.write_text("#!/bin/sh\n")
        cached.chmod(0o755)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.downloads()), 1)
        self.assertFalse(cached.exists())

    def test_a_download_that_fails_the_checksum_is_refused_and_not_cached(self):
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.downloads()), 1)
        self.assertEqual(list(self.tools.rglob("cargo-about")), [])

    def test_a_download_comes_only_from_the_pinned_github_release_over_https(self):
        self.run_script()
        call = self.downloads()[0]
        self.assertIn("--proto =https", call)
        self.assertRegex(call, r"https://github\.com/EmbarkStudios/cargo-about/releases/download/[0-9.]+/")

    def test_a_machine_without_a_pinned_build_is_told_to_set_cargo_about(self):
        result = self.run_script(machine="aarch64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CARGO_ABOUT", result.stderr)
        self.assertEqual(self.downloads(), [])

    def test_the_pin_is_a_full_sha256(self):
        self.assertRegex(SCRIPT.read_text(), r'SHA256="[0-9a-f]{64}"')
        self.assertRegex(SCRIPT.read_text(), r'BINARY_SHA256="[0-9a-f]{64}"')


if __name__ == "__main__":
    unittest.main()
