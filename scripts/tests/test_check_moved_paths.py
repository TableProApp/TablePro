import importlib.util
import tempfile
import unittest
import warnings
from pathlib import Path

spec = importlib.util.spec_from_file_location("moved", Path(__file__).resolve().parents[1] / "check-moved-paths.py")
moved = importlib.util.module_from_spec(spec)
spec.loader.exec_module(moved)


class MovedPathTests(unittest.TestCase):
    def test_bare_cd_into_removed_linux_directory_is_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = Path(tmp, "old.sh")
            old.write_text("  cd linux\n")
            self.assertEqual([hit[0] for hit in moved.stale([str(old)])], [str(old)])

    def test_old_prefix_is_found_and_new_names_are_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp, "a.md"), Path(tmp, "b.md")
            old.write_text("see linux/crates/core\n")
            new.write_text("tag linux-v0.1.5 and com.tablepro.linux and crates/core\n")
            self.assertEqual([hit[0] for hit in moved.stale([str(old), str(new)])], [str(old)])

    def test_scanning_text_and_invalid_utf8_closes_input_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            valid, invalid = Path(tmp, "valid.md"), Path(tmp, "invalid.md")
            valid.write_text("see linux/crates/core\n", encoding="utf-8")
            invalid.write_bytes(b"\xff")
            with warnings.catch_warnings(record=True) as captured:
                warnings.simplefilter("always", ResourceWarning)
                found = moved.stale([str(valid), str(invalid)])
            self.assertEqual([hit[0] for hit in found], [str(valid)])
            self.assertEqual([item for item in captured if issubclass(item.category, ResourceWarning)], [])

    def test_the_app_services_crate_is_not_the_old_app_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp, "a.md"), Path(tmp, "b.md")
            old.write_text("see crates/app and crates/app/src\n")
            new.write_text("see crates/app-services and crates/app_core\n")
            self.assertEqual([hit[0] for hit in moved.stale([str(old), str(new)])], [str(old)] * 1)


if __name__ == "__main__":
    unittest.main()
