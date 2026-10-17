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
Release:        {release}
{find_lang}
%changelog
{later}* {spec_date} TablePro Authors <hello@tablepro.app> - {changelog}-1
- First package
"""

PACKAGING_FIX = """* Mon Oct 19 2026 TablePro Authors <hello@tablepro.app> - 1.2.0-2
- Recommend a keyring

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

MAN = """.TH TABLEPRO 1 {man_date} "TablePro {man_version}" "User Commands"
.SH NAME
tablepro \\- work with your databases
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
        release="1%{?dist}",
        spec_date="Wed Oct 14 2026",
        later="",
        man_date="2026-10-14",
        man_version="1.2.0",
    ):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        root = Path(workdir.name)
        for path, content in (
            (check_packaging.METAINFO, METAINFO.format(releases=releases)),
            (
                check_packaging.SPEC,
                SPEC.format(
                    version=version,
                    changelog=changelog,
                    find_lang=find_lang,
                    release=release,
                    spec_date=spec_date,
                    later=later,
                ),
            ),
            (check_packaging.LINGUAS, linguas),
            (check_packaging.CHANGELOG, notes),
            (check_packaging.CARGO, CARGO.format(rust_version=rust_version)),
            (check_packaging.CONTROL, CONTROL.format(toolchain=toolchain)),
            (check_packaging.RULES, RULES.format(rust_bin=rust_bin)),
            (check_packaging.MAN, MAN.format(man_date=man_date, man_version=man_version)),
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
        root = self.tree(
            releases='<release version="1.2.0" date="2026-10-01"/>',
            notes=NOTES.replace("## [1.2.0] - 2026-10-14", "## [1.2.0] - 2026-10-01"),
            spec_date="Thu Oct 01 2026",
            man_date="2026-10-01",
        )

        found = check_packaging.problems(root, "1.2.0", "linux-v1.2.0", "2026-10-14")

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
            man_version="1.2.0-rc.1",
        )

        self.assertEqual(check_packaging.problems(root, "1.2.0-rc.1", "linux-v1.2.0-rc.1", "2026-10-14"), [])

    def test_a_spec_with_the_upstream_pre_release_fails(self):
        root = self.tree(
            releases='<release version="1.2.0-rc.1" date="2026-10-14"/>',
            version="1.2.0-rc.1",
            changelog="1.2.0~rc.1",
            man_version="1.2.0-rc.1",
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
        for notes in (
            NOTES.replace("## [1.2.0] - 2026-10-14", "## [1.2.1]"),
            "## [1.2.0] - 2026-10-14\n\n## [1.1.0]\n- x\n",
        ):
            with self.subTest(notes=notes):
                found = check_packaging.problems(self.tree(notes=notes), "1.2.0", "linux-v1.2.0", "2026-10-14")

                self.assertEqual(len(found), 1)
                self.assertIn("no notes under ## [1.2.0]", found[0])

    def test_the_changelog_is_only_required_for_a_release(self):
        self.assertEqual(check_packaging.problems(self.tree(notes="# Changelog\n"), "1.2.0"), [])

    def test_the_changelog_heading_carries_the_release_date(self):
        cases = [
            ("## [1.2.0] - 2026-10-13", "CHANGELOG.md dates 1.2.0 2026-10-13, the metainfo 2026-10-14"),
            ("## [1.2.0]", "CHANGELOG.md has no YYYY-MM-DD date on ## [1.2.0]"),
        ]
        for heading, expected in cases:
            with self.subTest(heading=heading):
                root = self.tree(notes=NOTES.replace("## [1.2.0] - 2026-10-14", heading))

                self.assertEqual(check_packaging.problems(root, "1.2.0"), [expected])

    def test_the_spec_first_package_carries_the_release_date(self):
        cases = [
            ("Tue Oct 13 2026", "is dated 2026-10-13, the metainfo 2026-10-14"),
            ("Thu Oct 14 2026", "has no valid date"),
            ("Wed Oct 32 2026", "has no valid date"),
        ]
        for spec_date, expected in cases:
            with self.subTest(spec_date=spec_date):
                found = check_packaging.problems(self.tree(spec_date=spec_date), "1.2.0")

                self.assertEqual(len(found), 1, found)
                self.assertIn(expected, found[0])

    def test_the_spec_needs_an_entry_for_the_first_package(self):
        found = check_packaging.problems(self.tree(changelog="1.1.0", later=PACKAGING_FIX), "1.2.0")

        self.assertEqual(found, ["build-aux/rpm/tablepro.spec has no %changelog entry for 1.2.0-1"])

    def test_dates_wait_for_the_release_commit(self):
        notes = "# Changelog\n\n## [Unreleased]\n\n- Something.\n"

        found = check_packaging.problems(self.tree(notes=notes, spec_date="Tue Oct 13 2026"), "1.2.0")

        self.assertEqual(found, [])

    def test_a_packaging_fix_after_the_release_passes(self):
        root = self.tree(release="2%{?dist}", later=PACKAGING_FIX)

        self.assertEqual(check_packaging.problems(root, "1.2.0"), [])

    def test_a_release_tag_needs_the_first_package_release(self):
        root = self.tree(release="2%{?dist}", later=PACKAGING_FIX)

        found = check_packaging.problems(root, "1.2.0", "linux-v1.2.0", "2026-10-14")

        self.assertEqual(len(found), 1, found)
        self.assertIn("has Release 2%{?dist}, not 1%{?dist}", found[0])

    def test_the_man_page_names_the_built_version(self):
        found = check_packaging.problems(self.tree(man_version="1.1.0"), "1.2.0")

        self.assertEqual(found, ["data/tablepro.1 names version 1.1.0, not 1.2.0"])

    def test_a_man_page_without_a_title_line_fails(self):
        root = self.tree()
        (root / check_packaging.MAN).write_text(".SH NAME\n", encoding="utf-8")

        found = check_packaging.problems(root, "1.2.0")

        self.assertEqual(found, ['data/tablepro.1 has no .TH line naming "TablePro X.Y.Z"'])

    def test_the_man_page_carries_the_release_date(self):
        found = check_packaging.problems(self.tree(man_date="2026-09-01"), "1.2.0")

        self.assertEqual(found, ["data/tablepro.1 is dated 2026-09-01, the metainfo 2026-10-14"])

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
