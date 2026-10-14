#!/usr/bin/env python3
"""Check licenses.yml against the libraries the build actually ships.

Every version is checked against its pin in a build script or a Package.resolved, because a bump
can change a license (OpenSSL at 3.0, Redis at 7.4) and that needs a person to re-read it.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

INVENTORY = "TablePro/Resources/ThirdPartyLicenses/licenses.yml"
RESOLVED = (
    "TablePro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "Packages/TableProOracle/Package.resolved",
    "TableProMobile/TableProMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)
ACKNOWLEDGEMENTS = "TableProMobile/TableProMobile/Acknowledgements/Acknowledgements.json"
PROJECTED = ("id", "name", "version", "spdx", "copyrights", "homepageURL", "textFile")
PIN = re.compile(r'^([A-Z0-9_]+_VERSION)="(?:\$\{[^:}]+:-)*(v?[0-9][^"$}]*)\}*"', re.MULTILINE)


def bare(version: str) -> str:
    return version[1:] if version.startswith("v") else version


def shell_pins(root: Path) -> dict[str, set[str]]:
    scripts = root / "scripts"
    files = sorted(scripts.glob("build-*.sh")) + sorted((scripts / "lib").glob("*.sh")) + sorted((scripts / "ios").glob("*.sh"))
    pins: dict[str, set[str]] = {}
    for path in files:
        for name, value in PIN.findall(path.read_text(encoding="utf-8")):
            pins.setdefault(name, set()).add(value)
    return pins


def package_pins(root: Path) -> dict[str, set[str]]:
    pins: dict[str, set[str]] = {}
    for relative in RESOLVED:
        path = root / relative
        if not path.exists():
            continue
        for entry in json.loads(path.read_text(encoding="utf-8")).get("pins", []):
            state = entry.get("state", {})
            version = state.get("version") or (f"rev:{state['revision']}" if "revision" in state else None)
            if version:
                pins.setdefault(entry["identity"], set()).add(version)
    return pins


def problems(root: Path) -> list[str]:
    inventory = root / INVENTORY
    components = yaml.load(inventory.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    found: list[str] = []
    ids = [c["id"] for c in components]
    found += [f"{i} appears more than once" for i in sorted({i for i in ids if ids.count(i) > 1})]

    base = inventory.parent
    referenced = {c["textFile"] for c in components if c.get("textFile")}
    for text in sorted(referenced):
        path = base / text
        if not path.exists() or not path.read_text(encoding="utf-8").strip():
            found.append(f"{text} is missing or empty")
    found += [f"texts/{p.name} ships but no component references it" for p in sorted((base / "texts").iterdir())
              if f"texts/{p.name}" not in referenced and not p.name.startswith(".")]

    shell, packages = shell_pins(root), package_pins(root)
    attributed = set()
    for c in components:
        kind, _, name = c.get("source", "").partition(":")
        recorded = set(c["version"].split(", "))
        if kind == "sh":
            attributed.add(name)
            if name not in shell:
                found.append(f"{c['id']} points at {name}, which no build script defines")
            elif {bare(v) for v in recorded} != {bare(v) for v in shell[name]}:
                found.append(f"{c['id']} is recorded as {c['version']} but {name} pins {', '.join(sorted(shell[name]))}")
        elif kind == "spm":
            if name not in packages:
                found.append(f"{c['id']} points at SwiftPM package {name}, which nothing resolves")
            elif recorded != packages[name]:
                found.append(f"{c['id']} is recorded as {c['version']} but SwiftPM resolves {', '.join(sorted(packages[name]))}")
    found += [f"{v} is built and shipped with no license entry" for v in sorted(set(shell) - attributed)]

    patched_on_disk = {p.name for p in (root / "scripts/patches").iterdir() if not p.name.startswith(".")}
    patched = {c["id"] for c in components if c.get("patched") == "true"}
    found += [f"scripts/patches/{i} exists but {i} is not marked patched" for i in sorted(patched_on_disk - patched)]
    found += [f"{i} is marked patched but scripts/patches/{i} does not exist" for i in sorted(patched - patched_on_disk)]

    expected = sorted(
        ({f: c.get(f) for f in PROJECTED} for c in components if "ios" in c.get("platforms", ["macos"])),
        key=lambda c: (c["name"].lower(), c["id"]),
    )
    if json.loads((root / ACKNOWLEDGEMENTS).read_text(encoding="utf-8")) != expected:
        found.append(f"{ACKNOWLEDGEMENTS} is stale. Run scripts/generate-ios-acknowledgements.py")
    return found


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    found = problems(root)
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
