import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_notes", ROOT / "scripts/release-notes.py")
release_notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_notes)


class ReleaseNotesTests(unittest.TestCase):
    def test_cut_adds_a_link_for_the_new_release(self):
        text = "## [Unreleased]\n\n## [0.2.0] - 2026-10-01\n\n- Existing change\n\n[Unreleased]: old\n"

        result = release_notes.cut(text, "0.3.0", "2026-10-21")

        self.assertIn("[0.3.0]: https://github.com/cozyGarage/BookiE/releases/tag/linux-v0.3.0", result)


if __name__ == "__main__":
    unittest.main()
