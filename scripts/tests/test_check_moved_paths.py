import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("moved", Path(__file__).resolve().parents[1] / "check-moved-paths.py")
moved = importlib.util.module_from_spec(spec)
spec.loader.exec_module(moved)


class MovedPathTests(unittest.TestCase):
    def test_old_prefix_is_found_and_new_names_are_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp, "a.md"), Path(tmp, "b.md")
            old.write_text("see linux/crates/core\n")
            new.write_text("tag linux-v0.1.5 and com.tablepro.linux and crates/core\n")
            self.assertEqual([hit[0] for hit in moved.stale([str(old), str(new)])], [str(old)])


if __name__ == "__main__":
    unittest.main()
