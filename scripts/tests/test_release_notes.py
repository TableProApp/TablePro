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

    def test_parse_accepts_notes_and_none(self):
        self.assertEqual(release_notes.parse_notes("fix\n\nRelease-Note: Fixed: Export keeps NULLs")[0], [("Fixed", "Export keeps NULLs")])
        self.assertEqual(release_notes.parse_notes("ci\n\nRelease-Note: none"), ([], []))

    def test_parse_rejects_missing_unknown_empty_and_mixed(self):
        for message in ("no trailer", "Release-Note: Fix: x", "Release-Note: Fixed:", "Release-Note: none\nRelease-Note: Added: x"):
            self.assertTrue(release_notes.parse_notes(message)[1], message)

    def test_trailers_pattern_finds_only_note_lines(self):
        body = "## Change\nText\n\nRelease-Note: Fixed: A\nRelease-Note: Added: B\n\n- [ ] Validation"

        self.assertEqual(release_notes.TRAILER.findall(body), ["Fixed: A", "Added: B"])

    def test_assemble_groups_by_category_and_adds_pull_numbers(self):
        commits = [
            ("fix(core): keep NULLs (#12)", "Release-Note: Fixed: Export keeps NULLs"),
            ("feat(app): add pager (#13)", "Release-Note: Added: Pager\nRelease-Note: Changed: Wider footer"),
            ("ci: cache (#14)", "Release-Note: none"),
        ]

        result = release_notes.assemble(commits)

        self.assertEqual(result, "### Added\n\n- Pager (#13)\n\n### Changed\n\n- Wider footer (#13)\n\n### Fixed\n\n- Export keeps NULLs (#12)\n")

    def test_assemble_refuses_a_commit_without_a_note_unless_allowed(self):
        commits = [("fix: x (#1)", "no trailer"), ("fix: y (#2)", "Release-Note: Fixed: y")]

        with self.assertRaises(SystemExit):
            release_notes.assemble(commits)
        self.assertIn("- y (#2)", release_notes.assemble(commits, allow_missing=True))


if __name__ == "__main__":
    unittest.main()
