import importlib.util
import hashlib
import io
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("vendor_patches", ROOT / "scripts/vendor-patches.py")
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)


def write(root, files):
    for name, text in files.items():
        path = Path(root) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


class VendorPatchTests(unittest.TestCase):
    def test_a_patch_made_from_a_vendored_tree_rebuilds_it_from_the_pristine_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root / "pristine", {"src/lib.rs": "one\ntwo\nthree\n", "Cargo.toml": 'version = "1.0.0"\n'})
            write(root / "vendored", {"src/lib.rs": "one\nTWO\nthree\n", "Cargo.toml": 'version = "1.0.0"\n', "src/extra.rs": "new\n"})
            work = root / "work"
            work.mkdir()
            patch_file = root / "crate.patch"
            patch_file.write_text(tool.make_patch(root / "pristine", root / "vendored", work))
            tool.apply_patch(patch_file, root / "pristine")
            self.assertEqual(tool.differences(root / "pristine", root / "vendored"), [])

    def test_an_edit_outside_the_patch_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root / "expected", {"src/lib.rs": "one\n", "src/gone.rs": "x\n"})
            write(root / "actual", {"src/lib.rs": "edited\n", "src/new.rs": "y\n"})
            self.assertEqual(
                tool.differences(root / "expected", root / "actual"),
                ["src/gone.rs: missing", "src/new.rs: not in upstream plus patch", "src/lib.rs: differs"],
            )

    def test_every_vendored_crate_has_a_patch_file(self):
        for name in tool.crates():
            self.assertTrue((tool.PATCHES / f"{name}.patch").is_file(), name)

    def test_the_trimmed_directories_stay_out_of_the_pristine_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, {"benches/b.rs": "x\n", "src/lib.rs": "y\n"})
            tool.prune(root, tool.TRIMMED["redis"])
            self.assertEqual(tool.files(root), ["src/lib.rs"])

    def test_crate_version_requires_a_manifest_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "Cargo.toml"
            manifest.write_text("[package]\nname = 'crate'\n")
            with self.assertRaises(SystemExit):
                tool.crate_version(manifest.parent)

    def test_prune_removes_a_named_file_as_well_as_a_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "CHANGELOG.md").write_text("old")
            tool.prune(root, ["CHANGELOG.md", "missing"])
            self.assertEqual(tool.files(root), [])

    def test_pristine_rejects_an_archive_with_the_wrong_registry_checksum(self):
        with tempfile.TemporaryDirectory() as tmp:
            response = mock.MagicMock()
            response.__enter__.return_value.read.return_value = b"not a crate"
            with (
                mock.patch.object(tool, "fetch_json", return_value={"version": {"checksum": "0" * 64}}),
                mock.patch.object(tool.urllib.request, "urlopen", return_value=response),
                self.assertRaises(SystemExit),
            ):
                tool.pristine("crate", "1.0.0", Path(tmp))
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_pristine_extracts_an_archive_matching_the_registry_checksum(self):
        stream = io.BytesIO()
        contents = b'version = "1.0.0"\n'
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            entry = tarfile.TarInfo("crate-1.0.0/Cargo.toml")
            entry.size = len(contents)
            archive.addfile(entry, io.BytesIO(contents))
        data = stream.getvalue()
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = data
        with tempfile.TemporaryDirectory() as tmp:
            with (
                mock.patch.object(
                    tool, "fetch_json", return_value={"version": {"checksum": hashlib.sha256(data).hexdigest()}}
                ),
                mock.patch.object(tool.urllib.request, "urlopen", return_value=response),
            ):
                result = tool.pristine("crate", "1.0.0", Path(tmp))
            self.assertEqual((result / "Cargo.toml").read_bytes(), contents)

    def test_pristine_rejects_an_archive_member_outside_its_destination(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            entry = tarfile.TarInfo("../escaped.txt")
            entry.size = 1
            archive.addfile(entry, io.BytesIO(b"x"))
        data = stream.getvalue()
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = data
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "download"
            destination.mkdir()
            with (
                mock.patch.object(tool, "fetch_json", return_value={"version": {"checksum": hashlib.sha256(data).hexdigest()}}),
                mock.patch.object(tool.urllib.request, "urlopen", return_value=response),
                self.assertRaises(tarfile.FilterError),
            ):
                tool.pristine("crate", "1.0.0", destination)
            self.assertFalse((Path(tmp) / "escaped.txt").exists())

    def test_check_rebuilds_a_vendored_tree_and_reports_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vendor = root / "vendor"
            patches = vendor / "patches"
            expected = root / "expected"
            write(vendor / "crate", {"Cargo.toml": 'version = "1.0.0"\n', "src/lib.rs": "right\n"})
            write(expected, {"Cargo.toml": 'version = "1.0.0"\n', "src/lib.rs": "right\n"})
            patches.mkdir(parents=True)
            (patches / "crate.patch").write_text("")
            with (
                mock.patch.object(tool, "VENDOR", vendor),
                mock.patch.object(tool, "PATCHES", patches),
                mock.patch.object(tool, "prepared", return_value=expected),
            ):
                self.assertEqual(tool.check([]), 0)
                (vendor / "crate/src/lib.rs").write_text("wrong\n")
                self.assertEqual(tool.check([]), 1)

    def test_generate_writes_a_patch_for_the_vendored_difference(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vendor = root / "vendor"
            patches = vendor / "patches"
            base = root / "base"
            write(vendor / "crate", {"Cargo.toml": 'version = "1.0.0"\n', "src/lib.rs": "one plus local patch\n"})
            write(base, {"Cargo.toml": 'version = "1.0.0"\n', "src/lib.rs": "one\n"})
            with (
                mock.patch.object(tool, "VENDOR", vendor),
                mock.patch.object(tool, "PATCHES", patches),
                mock.patch.object(tool, "prepared", return_value=base),
            ):
                self.assertEqual(tool.generate(["crate"]), 0)
            tool.apply_patch(patches / "crate.patch", base)
            self.assertEqual((base / "src/lib.rs").read_text(), "one plus local patch\n")

    def test_refresh_replaces_the_vendored_tree_with_upstream_plus_patch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vendor = root / "vendor"
            patches = vendor / "patches"
            base = root / "base"
            write(vendor / "crate", {"Cargo.toml": 'version = "0.9.0"\n', "src/lib.rs": "stale\n"})
            write(base, {"Cargo.toml": 'version = "1.0.0"\n', "src/lib.rs": "upstream\n"})
            patches.mkdir(parents=True)
            work = root / "work"
            work.mkdir()
            patched = root / "patched"
            write(patched, {"Cargo.toml": 'version = "1.0.0"\n', "src/lib.rs": "upstream plus patch\n"})
            (patches / "crate.patch").write_text(tool.make_patch(base, patched, work))
            with (
                mock.patch.object(tool, "VENDOR", vendor),
                mock.patch.object(tool, "PATCHES", patches),
                mock.patch.object(tool, "prepared", return_value=base),
            ):
                self.assertEqual(tool.refresh(["crate", "1.0.0"]), 0)
            self.assertEqual((vendor / "crate/src/lib.rs").read_text(), "upstream plus patch\n")
            self.assertEqual(tool.crate_version(vendor / "crate"), "1.0.0")


if __name__ == "__main__":
    unittest.main()
