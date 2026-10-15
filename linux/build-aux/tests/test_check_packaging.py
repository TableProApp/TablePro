import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packaging"))

import check_packaging  # noqa: E402

METAINFO = """<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>@app-id@</id>
  <releases>
    {releases}
  </releases>
</component>
"""

SPEC = """Name:           tablepro
Version:        {version}
Release:        1%{{?dist}}
{find_lang}
%changelog
* Wed Oct 14 2026 TablePro Authors <hello@tablepro.app> - {changelog}-1
- First package
"""


CARGO = """[workspace.package]
edition = "2024"
rust-version = "{rust_version}"
"""

CONTROL = """Source: tablepro
Build-Depends:
 debhelper-compat (= 13),
 {toolchain}
 meson (>= 1.4),

Package: tablepro
Depends:
 openssh-client (>= 1:8.7),
"""

RULES = """export PATH := {rust_bin}:$(PATH)
"""

NOTES = """# Changelog

## [Unreleased]

### Added

- Something not yet released.

## [1.2.0] - 2026-10-14

### Added

- Packages for Ubuntu and Fedora.

## [1.1.0] - 2026-09-01

- Older notes.
"""


class ProblemsTests(unittest.TestCase):
    def tree(
        self,
        releases='<release version="1.2.0" date="2026-10-14"/>',
        version="1.2.0",
        changelog="1.2.0",
        find_lang="",
        linguas="# comment\n",
        notes=NOTES,
        rust_version="1.97",
        toolchain="cargo-1.97,\n rustc-1.97,",
        rust_bin="/usr/lib/rust-1.97/bin",
    ):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        root = Path(workdir.name)
        for path, content in (
            (check_packaging.METAINFO, METAINFO.format(releases=releases)),
            (check_packaging.SPEC, SPEC.format(version=version, changelog=changelog, find_lang=find_lang)),
            (check_packaging.LINGUAS, linguas),
            (check_packaging.CHANGELOG, notes),
            (check_packaging.CARGO, CARGO.format(rust_version=rust_version)),
            (check_packaging.CONTROL, CONTROL.format(toolchain=toolchain)),
            (check_packaging.RULES, RULES.format(rust_bin=rust_bin)),
        ):
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(content, encoding="utf-8")
        return root

    def test_agreeing_metadata_passes(self):
        self.assertEqual(check_packaging.problems(self.tree(), "1.2.0"), [])

    def test_the_release_gate_passes_for_its_own_tag_and_date(self):
        found = check_packaging.problems(self.tree(), "1.2.0", "linux-v1.2.0", "2026-10-14")

        self.assertEqual(found, [])

    def test_a_tag_for_another_version_fails(self):
        found = check_packaging.problems(self.tree(), "1.2.0", "linux-v1.2.1", "2026-10-14")

        self.assertEqual(len(found), 1)
        self.assertIn("linux-v1.2.1", found[0])

    def test_the_newest_release_must_be_the_built_version(self):
        releases = '<release version="1.1.0" date="2026-09-01"/><release version="1.2.0" date="2026-10-14"/>'

        found = check_packaging.problems(self.tree(releases=releases), "1.2.0")

        self.assertEqual(len(found), 1)
        self.assertIn("is 1.1.0, not 1.2.0", found[0])

    def test_an_undated_release_fails(self):
        found = check_packaging.problems(self.tree(releases='<release version="1.2.0"/>'), "1.2.0")

        self.assertEqual(len(found), 1)
        self.assertIn("no YYYY-MM-DD date", found[0])

    def test_a_release_dated_before_the_tag_fails(self):
        releases = '<release version="1.2.0" date="2026-10-01"/>'

        found = check_packaging.problems(self.tree(releases=releases), "1.2.0", "linux-v1.2.0", "2026-10-14")

        self.assertEqual(len(found), 1)
        self.assertIn("dated 2026-10-01", found[0])

    def test_a_metainfo_without_releases_fails(self):
        found = check_packaging.problems(self.tree(releases=""), "1.2.0")

        self.assertEqual(len(found), 1)
        self.assertIn("no <release>", found[0])

    def test_the_spec_must_package_the_built_version(self):
        found = check_packaging.problems(self.tree(version="1.1.0"), "1.2.0")

        self.assertEqual(len(found), 1)
        self.assertIn("packages version 1.1.0", found[0])

    def test_the_spec_changelog_must_open_with_the_built_version(self):
        found = check_packaging.problems(self.tree(changelog="1.1.0"), "1.2.0")

        self.assertEqual(len(found), 1)
        self.assertIn("%changelog", found[0])

    def test_find_lang_follows_linguas(self):
        cases = [
            ("", "# none yet\n", 0),
            ("%find_lang %{name}\n", "de\nfr # French\n", 0),
            ("", "de\n", 1),
            ("%find_lang %{name}\n", "\n", 1),
        ]
        for find_lang, linguas, expected in cases:
            with self.subTest(find_lang=find_lang, linguas=linguas):
                found = check_packaging.problems(self.tree(find_lang=find_lang, linguas=linguas), "1.2.0")

                self.assertEqual(len(found), expected)

    def test_a_version_rpm_or_git_cannot_carry_fails(self):
        for version in ("1.2", "1.2.0~rc1", "1.2.0-rc-1", "1.2.0-", "1.2.0-rc..1"):
            with self.subTest(version=version):
                found = check_packaging.problems(self.tree(), version)

                self.assertTrue(any("is neither X.Y.Z nor a pre-release" in problem for problem in found))

    def test_a_pre_release_packages_with_a_tilde(self):
        self.assertEqual(check_packaging.package_version("1.2.0-rc.1"), "1.2.0~rc.1")
        self.assertEqual(check_packaging.package_version("1.2.0"), "1.2.0")

    def test_a_pre_release_tag_passes_when_the_spec_packages_the_tilde_version(self):
        root = self.tree(
            releases='<release version="1.2.0-rc.1" date="2026-10-14"/>',
            version="1.2.0~rc.1",
            changelog="1.2.0~rc.1",
            notes=NOTES.replace("## [1.2.0]", "## [1.2.0-rc.1]"),
        )

        self.assertEqual(check_packaging.problems(root, "1.2.0-rc.1", "linux-v1.2.0-rc.1", "2026-10-14"), [])

    def test_a_spec_with_the_upstream_pre_release_fails(self):
        root = self.tree(
            releases='<release version="1.2.0-rc.1" date="2026-10-14"/>',
            version="1.2.0-rc.1",
            changelog="1.2.0~rc.1",
        )

        found = check_packaging.problems(root, "1.2.0-rc.1")

        self.assertEqual(len(found), 1)
        self.assertIn("packages version 1.2.0-rc.1, not 1.2.0~rc.1", found[0])

    def test_the_debian_package_builds_with_the_workspace_rust_version(self):
        cases = [
            ({"rust_version": "1.98"}, 2),
            ({"toolchain": "cargo-1.97,\n rustc-1.96,"}, 1),
            ({"toolchain": "cargo,\n rustc,"}, 1),
            ({"rust_bin": "/usr/lib/rust-1.96/bin"}, 1),
            ({"rust_bin": "/usr/bin"}, 1),
        ]
        for changes, expected in cases:
            with self.subTest(changes=changes):
                found = check_packaging.problems(self.tree(**changes), "1.2.0")

                self.assertEqual(len(found), expected, found)

    def test_a_workspace_without_a_rust_version_fails(self):
        root = self.tree()
        (root / check_packaging.CARGO).write_text("[workspace]\n", encoding="utf-8")

        found = check_packaging.problems(root, "1.2.0")

        self.assertEqual(found, ["Cargo.toml names no workspace rust-version"])

    def test_a_release_needs_its_changelog_notes(self):
        for notes in (NOTES.replace("## [1.2.0] - 2026-10-14", "## [1.2.1]"), "## [1.2.0]\n\n## [1.1.0]\n- x\n"):
            with self.subTest(notes=notes):
                found = check_packaging.problems(self.tree(notes=notes), "1.2.0", "linux-v1.2.0", "2026-10-14")

                self.assertEqual(len(found), 1)
                self.assertIn("no notes under ## [1.2.0]", found[0])

    def test_the_changelog_is_only_required_for_a_release(self):
        self.assertEqual(check_packaging.problems(self.tree(notes="# Changelog\n"), "1.2.0"), [])

    def test_main_writes_the_release_notes(self):
        root = self.tree()
        notes = root / "notes.md"

        status = check_packaging.main(
            ["--source-root", str(root), "--version", "1.2.0", "--tag", "linux-v1.2.0", "--notes", str(notes)]
        )

        self.assertEqual(status, 0)
        self.assertEqual(notes.read_text(encoding="utf-8"), "### Added\n\n- Packages for Ubuntu and Fedora.\n")

    def test_main_reports_on_stderr_and_exits_1(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            failed = check_packaging.main(["--source-root", str(self.tree(version="1.1.0")), "--version", "1.1.0"])
            passed = check_packaging.main(["--source-root", str(self.tree()), "--version", "1.2.0"])

        self.assertEqual((failed, passed), (1, 0))
        self.assertIn("check_packaging.py: the newest release", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
