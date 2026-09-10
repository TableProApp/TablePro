#!/usr/bin/env python3
"""Regression tests for the notes shared by Sparkle and GitHub releases.

Run: python3 scripts/ci/test_release_notes.py
"""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("extract-release-notes.sh").resolve()


class ReleaseNotesTests(unittest.TestCase):
    def extract(self, changelog, version="1.2.3", stale_notes=None):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
            notes = work / "release_notes.md"
            if stale_notes is not None:
                notes.write_text(stale_notes, encoding="utf-8")
            result = subprocess.run(
                ["bash", str(SCRIPT), version],
                cwd=work,
                capture_output=True,
                text=True,
                timeout=10,
            )
            return result, notes.read_text(encoding="utf-8") if notes.exists() else None

    def test_only_requested_version_is_extracted(self):
        result, notes = self.extract(
            "## [Unreleased]\n- Not released yet\n\n"
            "## [1.2.3] - 2026-09-10\n\n### Fixed\n\n- Current fix\n\n"
            "## [1.2.2]\n- Old fix\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(notes, "### Fixed\n\n- Current fix\n")

    def test_version_is_literal_not_a_regular_expression(self):
        result, notes = self.extract(
            "## [1x2x3]\n- Wrong version\n"
            "## [1.2.3-beta.1]\n- Prerelease\n"
            "## [1.2.3]\n- Stable\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(notes, "- Stable\n")

    def test_prerelease_version_at_end_of_file(self):
        result, notes = self.extract(
            "## [1.2.3-beta.1]\n- Prerelease", version="1.2.3-beta.1"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(notes, "- Prerelease\n")

    def test_preserves_markdown_and_literal_code(self):
        body = (
            "### Fixed\n\n"
            "- `SELECT * FROM users WHERE id < 10` & `<xml>` stay visible.\n"
            "- **Important**: [Details](https://example.com/fix?a=1&b=2).\n"
            "- Phím tắt `Shift+Space`.\n\n"
            "```sql\nSELECT '<tag>';\n```\n"
        )
        result, notes = self.extract("## [1.2.3]\n" + body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(notes, body)

    def test_missing_or_blank_notes_fail_without_a_generic_fallback(self):
        for changelog in (
            "## [1.2.2]\n- Old fix\n",
            "## [1.2.3]\n\n## [1.2.2]\n- Old fix\n",
            "## [1.2.3]\n \t\n\n",
        ):
            with self.subTest(changelog=changelog):
                result, notes = self.extract(changelog)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No release notes found for version 1.2.3", result.stderr)
                self.assertIsNone(notes)

    def test_existing_notes_do_not_override_the_current_changelog(self):
        result, notes = self.extract("## [1.2.3]\n- Current fix\n", stale_notes="- Old fix\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(notes, "- Current fix\n")

    def test_large_release_is_not_truncated(self):
        body = "- A detailed release note with `code` and a fix.\n" * 4000
        result, notes = self.extract("## [1.2.3]\n" + body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(notes, body)

    def test_features_precede_fixes_without_dropping_other_sections(self):
        intro = "All changes in this release."
        fixed = "### Fixed\n\n- Fix one\n- Fix two"
        security = "### Security\n\n- Security fix"
        features = "### Added\n\n- Feature one\n  - Nested detail\n- Feature two"
        changed = "### Changed\n\n- Improvement"
        removed = "### Removed\n\n- Removed behavior"
        result, notes = self.extract(
            "## [1.2.3]\n\n" + "\n\n".join([intro, fixed, security, features, changed, removed])
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(notes, "\n\n".join([intro, features, changed, fixed, security, removed]) + "\n")

    def test_features_heading_aliases_are_first(self):
        for heading in ("Features", "New Features"):
            with self.subTest(heading=heading):
                result, notes = self.extract(f"## [1.2.3]\n### Fixed\n- Fix\n\n### {heading}\n- Feature\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(notes, f"### {heading}\n- Feature\n\n### Fixed\n- Fix\n")

    def test_headings_inside_code_are_not_release_or_section_boundaries(self):
        for fence in ("```", "~~~~"):
            with self.subTest(fence=fence):
                fixed = f"### Fixed\n\n- Example:\n\n{fence}markdown\n## [1.2.2]\n### Added\n{fence}\n"
                result, notes = self.extract("## [1.2.3]\n" + fixed + "\n### Added\n\n- Actual feature\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(notes, "### Added\n\n- Actual feature\n\n" + fixed)

    def test_latest_real_release_keeps_every_change(self):
        changelog = (SCRIPT.parents[2] / "CHANGELOG.md").read_text(encoding="utf-8")
        releases = list(re.finditer(r"^## \[([^]]+)\].*$", changelog, re.MULTILINE))
        index = next(index for index, release in enumerate(releases) if release[1] != "Unreleased")
        release = releases[index]
        end = releases[index + 1].start() if index + 1 < len(releases) else len(changelog)
        body = changelog[release.end():end]
        result, notes = self.extract(changelog, version=release[1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertCountEqual(
            [line for line in notes.splitlines() if line.strip()],
            [line for line in body.splitlines() if line.strip()],
        )
        if "### Added\n" in notes and "### Fixed\n" in notes:
            self.assertLess(notes.index("### Added\n"), notes.index("### Fixed\n"))


if __name__ == "__main__":
    unittest.main()
