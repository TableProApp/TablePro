import importlib.util
import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
