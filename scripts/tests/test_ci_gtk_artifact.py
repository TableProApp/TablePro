import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_gtk_artifact", ROOT / "scripts/ci-gtk-artifact.py")
artifact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifact)
SHA = "a" * 40


class GtkArtifactWorkflowTests(unittest.TestCase):
    def test_native_scenario_jobs_consume_the_single_verified_build(self):
        workflow = (ROOT / ".forgejo/workflows/ci.yml").read_text()
        headings = list(re.finditer(r"(?m)^  ([a-z0-9-]+):\n", workflow.split("jobs:\n", 1)[1]))
        content = workflow.split("jobs:\n", 1)[1]
        jobs = {
            heading[1]: content[heading.start():headings[index + 1].start() if index + 1 < len(headings) else len(content)]
            for index, heading in enumerate(headings)
        }
        self.assertIn("gtk-build", list(jobs))
        self.assertEqual(workflow.count("ci-gtk-artifact.py create"), 1)
        for name in ("e2e", "gtk", "gtk-server"):
            job = jobs[name]
            self.assertRegex(job, r"needs: \[[^\]]*gtk-build[^\]]*\]")
            self.assertIn("ci-gtk-artifact.py verify", job)
            self.assertIn("TABLEPRO_GTK_BINARY=", job)
            self.assertIn("CARGO_TARGET_DIR: /var/cache/ci/target/gtk-build\n", job)
            self.assertIn('"${{ github.sha }}"', job)
            self.assertIn("name: gtk-ci-${{ github.run_id }}-${{ github.sha }}", job)
            self.assertNotIn("cargo build", job)
            self.assertLess(job.index("ensure-node.sh"), job.index("uses:"))


class GtkArtifactTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.binary = self.root / "original"
        self.binary.write_bytes(b"binary-content\x00\xff")
        self.binary.chmod(0o755)
        self.output = self.root / "artifact"

    def create(self):
        with patch.object(artifact, "source_identity", return_value=SHA):
            artifact.create(self.binary, self.output, SHA)

    def test_transferred_binary_is_complete_and_permissions_are_restored_after_verification(self):
        self.create()
        transferred = self.output / "bookie"
        transferred.chmod(0o644)
        result = artifact.verify(self.output, SHA)
        self.assertEqual(result.read_bytes(), self.binary.read_bytes())
        self.assertTrue(result.stat().st_mode & 0o111)

    def test_a_binary_from_another_source_is_refused(self):
        self.create()
        with self.assertRaisesRegex(ValueError, "source"):
            artifact.verify(self.output, "b" * 40)

    def test_tampered_bytes_are_refused_before_becoming_executable(self):
        self.create()
        binary = self.output / "bookie"
        binary.chmod(0o644)
        binary.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "digest"):
            artifact.verify(self.output, SHA)
        self.assertFalse(binary.stat().st_mode & 0o111)

    def test_a_symlink_cannot_substitute_for_the_binary(self):
        self.create()
        binary = self.output / "bookie"
        binary.unlink()
        binary.symlink_to(self.binary)
        with self.assertRaisesRegex(ValueError, "regular"):
            artifact.verify(self.output, SHA)

    def test_an_incompatible_architecture_is_refused(self):
        self.create()
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["architecture"] = "different-machine"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "architecture"):
            artifact.verify(self.output, SHA)

    def test_an_unrecognized_build_profile_is_refused(self):
        self.create()
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["profile"] = "release"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "profile"):
            artifact.verify(self.output, SHA)

    def test_the_publisher_refuses_a_different_checkout(self):
        with patch.object(artifact, "source_identity", return_value="b" * 40):
            with self.assertRaisesRegex(ValueError, "source"):
                artifact.create(self.binary, self.output, SHA)
        self.assertFalse(self.output.exists())

    def test_dirty_source_is_refused_before_build_identity_is_claimed(self):
        with patch.object(artifact.subprocess, "check_output", return_value="?? untracked-source.rs\n"):
            with self.assertRaisesRegex(ValueError, "clean source"):
                artifact.source_identity()

    def test_a_retried_build_replaces_only_its_own_output_files(self):
        self.create()
        self.binary.write_bytes(b"rebuilt")
        self.create()
        self.assertEqual(artifact.verify(self.output, SHA).read_bytes(), b"rebuilt")
        unrelated = self.output / "unrelated"
        unrelated.write_text("preserve")
        with self.assertRaisesRegex(ValueError, "unexpected"):
            self.create()
        self.assertEqual(unrelated.read_text(), "preserve")

    def test_a_manifest_symlink_is_refused(self):
        self.create()
        manifest = self.output / "manifest.json"
        original = self.root / "original-manifest.json"
        manifest.rename(original)
        manifest.symlink_to(original)
        with self.assertRaisesRegex(ValueError, "regular manifest"):
            artifact.verify(self.output, SHA)


if __name__ == "__main__":
    unittest.main()
