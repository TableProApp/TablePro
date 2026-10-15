#!/usr/bin/env python3
# Checks that the version Meson builds is the one the metainfo releases and
# the RPM spec package, and that the spec collects translations exactly
# when po/LINGUAS ships one. The release workflow adds the tag and its
# date, and then CHANGELOG.md must carry that version's notes.

import argparse
import re
import sys
import xml.etree.ElementTree as ElementTree
from datetime import date
from pathlib import Path

METAINFO = Path("data/app.tablepro.TablePro.metainfo.xml.in.in")
SPEC = Path("build-aux/rpm/tablepro.spec")
LINGUAS = Path("po/LINGUAS")
CHANGELOG = Path("CHANGELOG.md")

# RPM forbids '-' in Version and git forbids '~' in a tag, so a release
# version is plain X.Y.Z.
RELEASE_VERSION = re.compile(r"^\d+\.\d+\.\d+$")
SPEC_VERSION = re.compile(r"^Version:\s*(\S+)\s*$", re.MULTILINE)
SPEC_CHANGELOG = re.compile(r"^%changelog\s*\n\*[^\n]*\s-\s(\S+)\s*$", re.MULTILINE)
FIND_LANG = re.compile(r"^%find_lang\b", re.MULTILINE)


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


def problems(root, version, tag=None, tag_date=None):
    found = []
    if not RELEASE_VERSION.match(version):
        found.append(f"version {version} is not X.Y.Z")
    if tag is not None:
        if tag != f"linux-v{version}":
            found.append(f"tag {tag} does not name version {version}; expected linux-v{version}")
        if not release_notes(root / CHANGELOG, version):
            found.append(f"{CHANGELOG} has no notes under ## [{version}]")

    release = newest_release(root / METAINFO)
    if release is None:
        found.append(f"{METAINFO} has no <release>")
    else:
        if release.get("version") != version:
            found.append(
                f"the newest release in {METAINFO} is {release.get('version')}, not {version}"
            )
        released = release.get("date", "")
        try:
            date.fromisoformat(released)
        except ValueError:
            found.append(f"the newest release in {METAINFO} has no YYYY-MM-DD date")
        if tag_date is not None and released != tag_date:
            found.append(
                f"the newest release in {METAINFO} is dated {released or 'nothing'}, "
                f"the tagged commit {tag_date}"
            )

    spec = (root / SPEC).read_text(encoding="utf-8")
    versions = SPEC_VERSION.findall(spec)
    if versions != [version]:
        found.append(f"{SPEC} packages version {', '.join(versions) or 'nothing'}, not {version}")
    changelog = SPEC_CHANGELOG.search(spec)
    if changelog is None or not changelog.group(1).startswith(f"{version}-"):
        found.append(f"the first %changelog entry in {SPEC} is not for {version}")

    if bool(linguas(root / LINGUAS)) != bool(FIND_LANG.search(spec)):
        found.append(
            f"{SPEC} must run %find_lang and list %{{name}}.lang exactly when {LINGUAS} names a language"
        )
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
    except (OSError, ElementTree.ParseError) as error:
        found = [str(error)]
    for problem in found:
        print(f"check_packaging.py: {problem}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
