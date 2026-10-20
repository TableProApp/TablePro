import contextlib
import io
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("release_version", Path(__file__).resolve().parents[1] / "check-release-version.py")
VERSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERSION)


class ReleaseVersionTests(unittest.TestCase):
    def fixture(self, root):
        (root / "Cargo.toml").write_text('[workspace]\nmembers = ["crates/*"]\n[workspace.package]\nversion = "0.2.0"\n')
        crate = root / "crates/core/Cargo.toml"
        crate.parent.mkdir(parents=True)
        crate.write_text('[package]\nname = "fixture"\nversion.workspace = true\n')
        (root / "meson.build").write_text("project('bookie', version: '0.2.0')\n")
        metadata = root / "apps/linux/flatpak/com.tablepro.linux.metainfo.xml"
        metadata.parent.mkdir(parents=True)
        metadata.write_text('<component><releases><release version="0.2.0" type="development"/><release version="0.1.5"/></releases></component>')
        return crate, metadata

    def test_accepts_shared_version_and_preserves_older_releases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            self.assertEqual(VERSION.release_version(root), "0.2.0")
            self.assertEqual(VERSION.problems(root), [])

    def test_rejects_independent_crate_meson_and_appstream_drift(self):
        for target in ("crate", "meson", "appstream"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                crate, metadata = self.fixture(root)
                if target == "crate":
                    crate.write_text('[package]\nversion = "0.1.0"\n')
                elif target == "meson":
                    (root / "meson.build").write_text("project('bookie', version: '0.1.6-dev')\n")
                else:
                    metadata.write_text('<component><releases><release version="0.1.5"/></releases></component>')
                self.assertEqual(len(VERSION.problems(root)), 1)

    def test_cli_prints_the_source_version_and_reports_drift_or_missing_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            with patch.object(VERSION, "ROOT", root):
                for arguments, expected in ((["check", "--print"], 0), (["check"], 0)):
                    with patch("sys.argv", arguments), contextlib.redirect_stdout(io.StringIO()) as output:
                        self.assertEqual(VERSION.main(), expected)
                        self.assertIn("0.2.0", output.getvalue())
                (root / "meson.build").write_text("project('bookie', version: '0.1.0')")
                with patch("sys.argv", ["check"]), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(VERSION.main(), 1)
                (root / "Cargo.toml").unlink()
                with patch("sys.argv", ["check"]), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(VERSION.main(), 1)

    def test_refuses_a_non_release_workspace_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            manifest = root / "Cargo.toml"
            manifest.write_text(manifest.read_text().replace('version = "0.2.0"', 'version = "0.2.0-dev"'))
            self.assertTrue(VERSION.problems(root))
