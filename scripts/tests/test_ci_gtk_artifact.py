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
FEATURES = {"defaults_enabled": True, "enabled_defaults": ["kerberos"]}
TOOLKIT = {
    "gtk4": "4.24.1",
    "glib-2.0": "2.88.1",
    "libadwaita-1": "1.10.0",
    "gtksourceview-5": "5.22.0",
}


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
        build_job = jobs["gtk-build"]
        self.assertIn("cargo build --profile ci --locked -p tablepro-app --bin tablepro-app", build_job)
        self.assertNotIn("--no-default-features", build_job)
        self.assertNotRegex(build_job, r"cargo build[^\n]*--features")
        self.assertEqual(len(re.findall(r"ci-gtk-artifact\.py create (?!--package)", workflow)), 1)
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

    def test_distro_floor_package_uses_the_default_app_feature_set(self):
        package_workflow = (ROOT / "scripts/distro-floor-package.sh").read_text()
        builder = (ROOT / "scripts/build-deb.sh").read_text()

        self.assertIn("build-deb.sh", package_workflow)
        self.assertRegex(builder, r"cargo build[^\n]*-p tablepro-app[^\n]*--locked")
        self.assertNotIn("--no-default-features", builder)
        self.assertNotRegex(builder, r"cargo build[^\n]*--features")


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
        with (
            patch.object(artifact, "source_identity", return_value=SHA),
            patch.object(artifact, "feature_identity", return_value=FEATURES),
            patch.object(artifact, "toolkit_identity", return_value=TOOLKIT),
        ):
            artifact.create(self.binary, self.output, SHA)

    def verify(self, expected_sha=SHA, *, package=False, features=FEATURES, toolkit=TOOLKIT):
        with (
            patch.object(artifact, "feature_identity", return_value=features),
            patch.object(artifact, "toolkit_identity", return_value=toolkit),
        ):
            return artifact.verify(self.output, expected_sha, package=package)

    def test_manifest_records_default_features_and_toolkit_runtime(self):
        self.create()

        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["features"], FEATURES)
        self.assertEqual(manifest["toolkit_runtime"], TOOLKIT)

    def test_feature_identity_reads_default_features_from_the_app_manifest(self):
        self.assertEqual(artifact.feature_identity(), FEATURES)

    def test_feature_identity_refuses_a_malformed_default_feature_list(self):
        with patch.object(artifact.tomllib, "load", return_value={"features": {"default": [1]}}):
            with self.assertRaisesRegex(ValueError, "default Cargo features"):
                artifact.feature_identity()

    def test_toolkit_identity_records_each_pkg_config_version(self):
        with patch.object(artifact.subprocess, "check_output", side_effect=["4.24.1\n", "2.88.1\n", "1.10.0\n", "5.22.0\n"]):
            self.assertEqual(artifact.toolkit_identity(), TOOLKIT)

    def test_toolkit_identity_refuses_an_empty_pkg_config_version(self):
        with patch.object(artifact.subprocess, "check_output", return_value="\n"):
            with self.assertRaisesRegex(ValueError, "gtk4 version"):
                artifact.toolkit_identity()

    def test_toolkit_versions_require_numeric_components_and_matching_major(self):
        with self.assertRaisesRegex(ValueError, "version is invalid"):
            artifact.version_parts("4.24.1-1")
        self.assertFalse(artifact.version_is_compatible("5.0", "4.99"))

    def test_toolkit_identity_refuses_missing_runtime_data(self):
        with self.assertRaisesRegex(ValueError, "runtime identity is incomplete"):
            artifact.verify_toolkit_runtime({}, TOOLKIT)
        with self.assertRaisesRegex(ValueError, "runtime identity is unavailable"):
            artifact.verify_toolkit_runtime(TOOLKIT, {})

    def test_package_manifest_refuses_a_native_toolkit_runtime_claim(self):
        with patch.object(artifact, "source_identity", return_value=SHA):
            artifact.create(self.binary, self.output, SHA, package=True)
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["toolkit_runtime"] = TOOLKIT
        manifest_path.write_text(json.dumps(manifest))

        with self.assertRaisesRegex(ValueError, "cannot claim a native GTK runtime"):
            self.verify(package=True)

    def test_an_unsupported_manifest_schema_is_refused(self):
        self.create()
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["schema_version"] = 1
        manifest_path.write_text(json.dumps(manifest))

        with self.assertRaisesRegex(ValueError, "manifest version"):
            self.verify()

    def test_an_artifact_with_changed_default_features_is_refused(self):
        self.create()

        with self.assertRaisesRegex(ValueError, "feature"):
            self.verify(features={"defaults_enabled": True, "enabled_defaults": []})

    def test_an_incomplete_toolkit_runtime_identity_is_refused(self):
        self.create()
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        del manifest["toolkit_runtime"]["libadwaita-1"]
        manifest_path.write_text(json.dumps(manifest))

        with self.assertRaisesRegex(ValueError, "toolkit runtime"):
            self.verify()

    def test_an_older_toolkit_runtime_is_refused(self):
        self.create()
        older_toolkit = {**TOOLKIT, "gtk4": "4.22.0"}

        with self.assertRaisesRegex(ValueError, "toolkit runtime"):
            self.verify(toolkit=older_toolkit)

    def test_a_newer_abi_compatible_toolkit_runtime_is_accepted(self):
        self.create()
        newer_toolkit = {
            "gtk4": "4.26.0",
            "glib-2.0": "2.90.0",
            "libadwaita-1": "1.12.0",
            "gtksourceview-5": "5.24.0",
        }

        self.assertEqual(self.verify(toolkit=newer_toolkit).read_bytes(), self.binary.read_bytes())

    def test_transferred_binary_is_complete_and_permissions_are_restored_after_verification(self):
        self.create()
        transferred = self.output / "bookie"
        transferred.chmod(0o644)
        result = self.verify()
        self.assertEqual(result.read_bytes(), self.binary.read_bytes())
        self.assertTrue(result.stat().st_mode & 0o111)

    def test_a_binary_from_another_source_is_refused(self):
        self.create()
        with self.assertRaisesRegex(ValueError, "source"):
            self.verify("b" * 40)

    def test_tampered_bytes_are_refused_before_becoming_executable(self):
        self.create()
        binary = self.output / "bookie"
        binary.chmod(0o644)
        binary.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "digest"):
            self.verify()
        self.assertFalse(binary.stat().st_mode & 0o111)

    def test_a_symlink_cannot_substitute_for_the_binary(self):
        self.create()
        binary = self.output / "bookie"
        binary.unlink()
        binary.symlink_to(self.binary)
        with self.assertRaisesRegex(ValueError, "regular"):
            self.verify()

    def test_an_incompatible_architecture_is_refused(self):
        self.create()
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["architecture"] = "different-machine"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "architecture"):
            self.verify()

    def test_an_unrecognized_build_profile_is_refused(self):
        self.create()
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["profile"] = "release"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "profile"):
            self.verify()

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
        self.assertEqual(self.verify().read_bytes(), b"rebuilt")
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
            self.verify()

    def test_package_transfer_preserves_bytes_and_cannot_substitute_for_a_native_binary(self):
        with patch.object(artifact, "source_identity", return_value=SHA):
            artifact.create(self.binary, self.output, SHA, package=True)
        package = self.verify(package=True)
        self.assertEqual(package.name, "bookie.deb")
        self.assertEqual(package.read_bytes(), self.binary.read_bytes())
        self.assertFalse(package.stat().st_mode & 0o111)
        with self.assertRaises(ValueError):
            self.verify()

    def test_packages_reject_wrong_source_corruption_and_native_binary_packets(self):
        self.create()
        with self.assertRaises(ValueError):
            self.verify(package=True)
        self.output.joinpath("bookie").unlink()
        self.output.joinpath("manifest.json").unlink()
        with patch.object(artifact, "source_identity", return_value=SHA):
            artifact.create(self.binary, self.output, SHA, package=True)
        with self.assertRaises(ValueError):
            self.verify("b" * 40, package=True)
        self.output.joinpath("bookie.deb").write_bytes(b"corrupted")
        with self.assertRaises(ValueError):
            self.verify(package=True)


if __name__ == "__main__":
    unittest.main()
