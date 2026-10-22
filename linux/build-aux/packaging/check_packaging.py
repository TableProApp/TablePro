#!/usr/bin/env python3
# Checks that the version Meson builds is the one the metainfo releases, the
# RPM spec packages and the man page names, that the spec collects
# translations exactly when po/LINGUAS ships one, and that the Debian
# package builds with the Rust the workspace names as its rust-version. The
# release workflow adds the tag and its date, and then CHANGELOG.md must
# carry that version's notes, unless it is a pre-release, and the spec must
# be the version's first package release.
#
# Once CHANGELOG.md has a heading for the version, the release commit has
# set its dates, and the heading, the spec's %changelog entry and the man
# page must carry the metainfo's release date.

import argparse
import re
import sys
import tomllib
import xml.etree.ElementTree as ElementTree
from datetime import date, datetime
from pathlib import Path

METAINFO = Path("data/app.tablepro.TablePro.metainfo.xml.in.in")
SPEC = Path("build-aux/rpm/tablepro.spec")
LINGUAS = Path("po/LINGUAS")
CHANGELOG = Path("CHANGELOG.md")
CARGO = Path("Cargo.toml")
CONTROL = Path("build-aux/debian/control")
RULES = Path("build-aux/debian/rules")
MAN = Path("data/tablepro.1")

# X.Y.Z, or a pre-release such as X.Y.Z-rc.1 with no '-' after the first,
# so the package version below stays a plain substitution.
RELEASE_VERSION = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$")
SPEC_VERSION = re.compile(r"^Version:\s*(\S+)\s*$", re.MULTILINE)
SPEC_CHANGELOG = re.compile(r"^%changelog\s*\n\*[^\n]*\s-\s(\S+)\s*$", re.MULTILINE)
SPEC_RELEASE = re.compile(r"^Release:\s*(\S+)\s*$", re.MULTILINE)
SPEC_ENTRY = re.compile(r"^\*\s+(\w{3}\s+\w{3}\s+\d{1,2}\s+\d{4})\s.*\s-\s(\S+)\s*$", re.MULTILINE)
FIRST_PACKAGE_RELEASE = "1%{?dist}"
MAN_TITLE = re.compile(r'^\.TH\s+\S+\s+\S+\s+"?([^"\s]*)"?\s+"TablePro ([^"]*)"', re.MULTILINE)
FIND_LANG = re.compile(r"^%find_lang\b", re.MULTILINE)
FILES_LANG = re.compile(r"^%files\s+-f\s+%\{name\}\.lang\s*$", re.MULTILINE)
CONTROL_TOOLCHAIN = re.compile(r"\b(cargo|rustc)-(\d+\.\d+)\b")
RULES_TOOLCHAIN = re.compile(r"/usr/lib/rust-(\d+\.\d+)/bin\b")


def package_version(version):
    # RPM forbids '-' in Version and git forbids '~' in a tag. Debian and
    # Fedora both sort X.Y.Z~rc.1 below X.Y.Z.
    return version.replace("-", "~", 1)


def newest_release(metainfo):
    releases = ElementTree.parse(metainfo).getroot().find("releases")
    if releases is None:
        return None
    return releases.find("release")


def linguas(path):
    languages = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        languages.extend(line.split())
    return languages


def release_notes(changelog, version):
    notes = []
    heading = f"## [{version}]"
    inside = False
    for line in changelog.read_text(encoding="utf-8").splitlines():
        if line.startswith("## ["):
            inside = line.startswith(heading)
        elif inside:
            notes.append(line)
    return "\n".join(notes).strip()


def release_heading_date(changelog, version):
    """The date on the version's heading: None without a heading, "" when it has no date."""
    # towncrier links the version to its GitHub release.
    heading = re.compile(
        rf"^## \[{re.escape(version)}\](?:\([^)\s]*\))?(?: - (\d{{4}}-\d{{2}}-\d{{2}}))?\s*$"
    )
    for line in changelog.read_text(encoding="utf-8").splitlines():
        match = heading.match(line)
        if match:
            return match.group(1) or ""
    return None


def spec_entry_date(spec, release):
    """The date of the %changelog entry for release, None without one, "" when the date is bogus."""
    _, _, log = spec.partition("\n%changelog")
    for match in SPEC_ENTRY.finditer(log):
        if match.group(2) != release:
            continue
        written = " ".join(match.group(1).split())
        try:
            parsed = datetime.strptime(written, "%a %b %d %Y").date()
        except ValueError:
            return ""
        # rpmbuild warns about a weekday that does not match the date,
        # and strptime ignores it.
        if parsed.strftime("%a") != written.split()[0]:
            return ""
        return parsed.isoformat()
    return None


def man_title(root):
    """The date and version on the man page's .TH line, or None without one."""
    match = MAN_TITLE.search((root / MAN).read_text(encoding="utf-8"))
    return (match.group(1), match.group(2)) if match else None


def release_date_problems(root, version, spec, released, spec_opens_with_version):
    found = []
    title = man_title(root)
    if title is not None and title[0] != released:
        found.append(f"{MAN} is dated {title[0] or 'nothing'}, the metainfo {released}")
    heading = release_heading_date(root / CHANGELOG, version)
    if heading == "":
        found.append(f"{CHANGELOG} has no YYYY-MM-DD date on ## [{version}]")
    elif heading is not None and heading != released:
        found.append(f"{CHANGELOG} dates {version} {heading}, the metainfo {released}")

    # A spec whose %changelog does not open with the version is reported
    # once, by the version check.
    if not spec_opens_with_version:
        return found
    first = f"{package_version(version)}-1"
    entry = spec_entry_date(spec, first)
    if entry is None:
        found.append(f"{SPEC} has no %changelog entry for {first}")
    elif entry == "":
        found.append(f"the %changelog entry for {first} in {SPEC} has no valid date")
    elif entry != released:
        found.append(f"the %changelog entry for {first} in {SPEC} is dated {entry}, the metainfo {released}")
    return found


def toolchain_problems(root):
    package = tomllib.loads((root / CARGO).read_text(encoding="utf-8")).get("workspace", {}).get("package", {})
    rust_version = package.get("rust-version")
    if rust_version is None:
        return [f"{CARGO} names no workspace rust-version"]
    found = []
    expected = [("cargo", rust_version), ("rustc", rust_version)]
    named = sorted(set(CONTROL_TOOLCHAIN.findall((root / CONTROL).read_text(encoding="utf-8"))))
    if named != expected:
        names = ", ".join(f"{name}-{number}" for name, number in named) or "no versioned rustc or cargo"
        found.append(
            f"{CONTROL} build-depends on {names}, not cargo-{rust_version} and rustc-{rust_version}, "
            f"the rust-version in {CARGO}"
        )
    paths = sorted(set(RULES_TOOLCHAIN.findall((root / RULES).read_text(encoding="utf-8"))))
    if paths != [rust_version]:
        found.append(f"{RULES} must put /usr/lib/rust-{rust_version}/bin on PATH, and only that toolchain")
    return found


def problems(root, version, tag=None, tag_date=None):
    found = []
    if not RELEASE_VERSION.match(version):
        found.append(f"version {version} is neither X.Y.Z nor a pre-release such as X.Y.Z-rc.1")
    if tag is not None:
        if tag != f"linux-v{version}":
            found.append(f"tag {tag} does not name version {version}; expected linux-v{version}")
        # A pre-release keeps the fragments; its notes are a towncrier draft of them.
        if "-" not in version and not release_notes(root / CHANGELOG, version):
            found.append(f"{CHANGELOG} has no notes under ## [{version}]")

    packaged = package_version(version)
    spec = (root / SPEC).read_text(encoding="utf-8")
    changelog = SPEC_CHANGELOG.search(spec)
    spec_opens_with_version = changelog is not None and changelog.group(1).startswith(f"{packaged}-")
    release = newest_release(root / METAINFO)
    if release is None:
        found.append(f"{METAINFO} has no <release>")
    else:
        if release.get("version") != version:
            found.append(
                f"the newest release in {METAINFO} is {release.get('version')}, not {version}"
            )
        released = release.get("date", "")
        dated = True
        try:
            date.fromisoformat(released)
        except ValueError:
            dated = False
            found.append(f"the newest release in {METAINFO} has no YYYY-MM-DD date")
        if tag_date is not None and released != tag_date:
            found.append(
                f"the newest release in {METAINFO} is dated {released or 'nothing'}, "
                f"the tagged commit {tag_date}"
            )
        released_at_commit = tag is not None or release_heading_date(root / CHANGELOG, version) is not None
        if dated and release.get("version") == version and released_at_commit:
            found.extend(release_date_problems(root, version, spec, released, spec_opens_with_version))

    versions = SPEC_VERSION.findall(spec)
    if versions != [packaged]:
        found.append(f"{SPEC} packages version {', '.join(versions) or 'nothing'}, not {packaged}")
    if not spec_opens_with_version:
        found.append(f"the first %changelog entry in {SPEC} is not for {packaged}")
    # A packaging fix after the release raises Release on the branch; a
    # new version starts again from 1.
    if tag is not None:
        releases = SPEC_RELEASE.findall(spec)
        if releases != [FIRST_PACKAGE_RELEASE]:
            found.append(
                f"{SPEC} has Release {', '.join(releases) or 'nothing'}, not {FIRST_PACKAGE_RELEASE} "
                f"for a new version"
            )

    title = man_title(root)
    if title is None:
        found.append(f'{MAN} has no .TH line naming "TablePro X.Y.Z"')
    elif title[1] != version:
        found.append(f"{MAN} names version {title[1] or 'nothing'}, not {version}")

    languages = bool(linguas(root / LINGUAS))
    if any(languages != bool(pattern.search(spec)) for pattern in (FIND_LANG, FILES_LANG)):
        found.append(
            f"{SPEC} must run %find_lang and list %{{name}}.lang exactly when {LINGUAS} names a language"
        )
    found.extend(toolchain_problems(root))
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check that the release metadata agree with the version Meson builds."
    )
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag")
    parser.add_argument("--tag-date")
    parser.add_argument("--notes", type=Path, help="write the version's CHANGELOG.md notes here")
    args = parser.parse_args(argv)

    try:
        found = problems(args.source_root, args.version, args.tag, args.tag_date)
        if args.notes is not None and not found:
            args.notes.write_text(
                release_notes(args.source_root / CHANGELOG, args.version) + "\n", encoding="utf-8"
            )
    except (OSError, ElementTree.ParseError, tomllib.TOMLDecodeError) as error:
        found = [str(error)]
    for problem in found:
        print(f"check_packaging.py: {problem}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
