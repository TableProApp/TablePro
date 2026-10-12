#!/usr/bin/env python3
"""Fails on the Sparkle configuration invariants nothing else checks.

The framework the app links and the generate_appcast that signs its feed are the same project, and
a release that mixes them is a release nobody can measure. Nothing checked this before: project.yml
declares `majorVersion`, which XcodeGen writes as upToNextMajorVersion, so a resolve can move the
framework on its own while the signing tool stays where it was.

The second invariant is the deployment target. TablePro publishes two items per release and tells
them apart by `sparkle:hardwareRequirements`, which `generate_appcast` emits only while
`LSMinimumSystemVersion` is below 27.0 (ArchiveItem.swift:255-262, unchanged in 2.10.0): at or above
it, `mayNeedHardwareRequirement` is forced false and the element is never written. merge-appcast.py
then refuses the release, about forty minutes in, with both architectures already notarized and the
tag already pushed.

Runs on Repo Hygiene, which has no Xcode. Pure text.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

PROJECT_YML = ROOT / "project.yml"
PACKAGE_RESOLVED = ROOT / "TablePro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SIGN_SCRIPT = ROOT / "scripts/ci/sign-and-appcast.sh"
LICENSES = ROOT / "TablePro/Resources/ThirdPartyLicenses/licenses.yml"


class VersionError(Exception):
    """A disagreement. Every one of these fails the job that raised it."""


def read(path):
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise VersionError(f"{path.relative_to(ROOT)}: {error}") from error


def sole_match(pattern, text, path, what):
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise VersionError(
            f"{path.relative_to(ROOT)}: expected exactly one {what}, found {len(matches)}"
        )
    return matches[0]


HARDWARE_REQUIREMENTS_CEILING = (27, 0)


def deployment_target():
    project = read(PROJECT_YML)
    block = re.search(r"^  deploymentTarget:\n(?:^ {4}.*\n)+", project, re.MULTILINE)
    if block is None:
        raise VersionError("project.yml: no deploymentTarget block")
    return sole_match(r'^ {4}macOS:\s*"?([0-9.]+)"?\s*$', block.group(0), PROJECT_YML, "macOS deployment target")


def check_deployment_target():
    raw = deployment_target()
    parts = tuple(int(part) for part in raw.split(".")[:2])
    padded = parts + (0,) * (2 - len(parts))
    if padded >= HARDWARE_REQUIREMENTS_CEILING:
        raise VersionError(
            f"the macOS deployment target is {raw}, at or above "
            f"{'.'.join(str(n) for n in HARDWARE_REQUIREMENTS_CEILING)}. generate_appcast stops "
            "emitting sparkle:hardwareRequirements there, so the two per-architecture items become "
            "indistinguishable and merge-appcast.py refuses the release after both notarizations. "
            "Move the release to one Universal archive before raising the target"
        )
    return raw


def declared_versions():
    """Every place a Sparkle version is written down, as {label: version}."""
    project = read(PROJECT_YML)
    sparkle_block = re.search(
        r"^  Sparkle:\n(?:^ {4}.*\n)+", project, re.MULTILINE
    )
    if sparkle_block is None:
        raise VersionError("project.yml: no Sparkle package block")

    versions = {
        "project.yml majorVersion": sole_match(
            r"^ {4}majorVersion:\s*(\S+)\s*$", sparkle_block.group(0), PROJECT_YML, "majorVersion"
        ),
        "Package.resolved": sole_match(
            r'"identity"\s*:\s*"sparkle".*?"version"\s*:\s*"([^"]+)"',
            read(PACKAGE_RESOLVED).replace("\n", " "),
            PACKAGE_RESOLVED,
            "sparkle pin",
        ),
        "sign-and-appcast.sh SPARKLE_VERSION": sole_match(
            r'^SPARKLE_VERSION="([^"]+)"\s*$', read(SIGN_SCRIPT), SIGN_SCRIPT, "SPARKLE_VERSION"
        ),
    }

    licenses = read(LICENSES)
    entry = re.search(r"^- id: sparkle\n(?:^(?![-]).*\n)+", licenses, re.MULTILINE)
    if entry is None:
        raise VersionError("licenses.yml: no sparkle entry")
    versions["licenses.yml version"] = sole_match(
        r"^  version:\s*(\S+)\s*$", entry.group(0), LICENSES, "version"
    )
    versions["licenses.yml licenseTextURL"] = sole_match(
        r"licenseTextURL:\s*https://github\.com/sparkle-project/Sparkle/blob/([^/]+)/LICENSE",
        entry.group(0),
        LICENSES,
        "licenseTextURL",
    )
    return versions


def main():
    try:
        target = check_deployment_target()
        versions = declared_versions()
    except VersionError as error:
        print(f"::error::check-sparkle-version: {error}", file=sys.stderr)
        return 1

    distinct = set(versions.values())
    if len(distinct) != 1:
        print("::error::check-sparkle-version: the Sparkle version is not the same everywhere", file=sys.stderr)
        for label, version in versions.items():
            print(f"  {version:<10} {label}", file=sys.stderr)
        return 1

    version = distinct.pop()
    print(f"Sparkle {version} agrees across {len(versions)} declarations")
    print(f"macOS deployment target {target} still emits sparkle:hardwareRequirements")
    return 0


if __name__ == "__main__":
    sys.exit(main())
