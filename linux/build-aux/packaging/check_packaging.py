#!/usr/bin/env python3
# Checks that the version Meson builds is the one the metainfo releases and
# the RPM spec package, that the spec collects translations exactly when
# po/LINGUAS ships one, and that the Debian package builds with the Rust
# the workspace names as its rust-version. The release workflow adds the
# tag and its date, and then CHANGELOG.md must carry that version's notes.

import argparse
import re
import sys
import tomllib
import xml.etree.ElementTree as ElementTree
from datetime import date
from pathlib import Path

METAINFO = Path("data/app.tablepro.TablePro.metainfo.xml.in.in")
SPEC = Path("build-aux/rpm/tablepro.spec")
LINGUAS = Path("po/LINGUAS")
CHANGELOG = Path("CHANGELOG.md")
CARGO = Path("Cargo.toml")
CONTROL = Path("build-aux/debian/control")
RULES = Path("build-aux/debian/rules")

# X.Y.Z, or a pre-release such as X.Y.Z-rc.1 with no '-' after the first,
# so the package version below stays a plain substitution.
RELEASE_VERSION = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$")
SPEC_VERSION = re.compile(r"^Version:\s*(\S+)\s*$", re.MULTILINE)
SPEC_CHANGELOG = re.compile(r"^%changelog\s*\n\*[^\n]*\s-\s(\S+)\s*$", re.MULTILINE)
FIND_LANG = re.compile(r"^%find_lang\b", re.MULTILINE)
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

    packaged = package_version(version)
    spec = (root / SPEC).read_text(encoding="utf-8")
    versions = SPEC_VERSION.findall(spec)
    if versions != [packaged]:
        found.append(f"{SPEC} packages version {', '.join(versions) or 'nothing'}, not {packaged}")
    changelog = SPEC_CHANGELOG.search(spec)
    if changelog is None or not changelog.group(1).startswith(f"{packaged}-"):
        found.append(f"the first %changelog entry in {SPEC} is not for {packaged}")

    if bool(linguas(root / LINGUAS)) != bool(FIND_LANG.search(spec)):
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
