#!/usr/bin/env python3
"""Check docs/feature-parity/features.yml and write the table in README.md from it.

    python3 scripts/parity/render.py          write README.md
    python3 scripts/parity/render.py --check  fail when README.md is not what features.yml renders
"""

import argparse
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / "docs" / "feature-parity"
SOURCE = FOLDER / "features.yml"
TARGET = FOLDER / "README.md"
REPOSITORY = "https://github.com/TableProApp/TablePro"

PLATFORMS = (("macos", "macOS"), ("linux", "Linux"), ("windows", "Windows"))
STATUSES = {
    "yes": "Yes",
    "pending": "In a PR",
    "partial": "Partial",
    "no": "No",
    "na": "n/a",
    "unknown": "Unknown",
}


class ParityError(ValueError):
    pass


def cell_of(value, where):
    """The status, pull request and note a platform's value stands for."""
    # YAML 1.1 reads a bare yes and no as booleans.
    if isinstance(value, bool):
        value = "yes" if value else "no"
    if isinstance(value, str):
        value = {"status": value}
    if not isinstance(value, dict):
        raise ParityError(f"{where}: a platform is a status or a mapping")
    unknown = set(value) - {"status", "pr", "note"}
    if unknown:
        raise ParityError(f"{where}: unknown keys {sorted(unknown)}")
    status = value.get("status")
    if isinstance(status, bool):
        status = "yes" if status else "no"
    if status not in STATUSES:
        raise ParityError(f"{where}: status {status!r} is not one of {sorted(STATUSES)}")
    pr = value.get("pr")
    if pr is not None and (not isinstance(pr, int) or isinstance(pr, bool) or pr <= 0):
        raise ParityError(f"{where}: pr is a pull request number")
    if status == "pending" and pr is None:
        raise ParityError(f"{where}: a pending feature names its pull request")
    note = value.get("note")
    if note is not None and not isinstance(note, str):
        raise ParityError(f"{where}: note is text")
    return status, pr, note


def load(path=SOURCE):
    """The areas of `path`, each feature with its three cells checked."""
    document = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    if not isinstance(document, dict) or not isinstance(document.get("areas"), list):
        raise ParityError("features.yml holds a list of areas")
    seen = set()
    areas = []
    for area in document["areas"]:
        features = []
        for feature in area.get("features", []):
            name = feature.get("name")
            ident = feature.get("id")
            if not name or not ident:
                raise ParityError(f"{area.get('name')}: a feature needs an id and a name")
            if ident in seen:
                raise ParityError(f"{ident}: the id is used twice")
            seen.add(ident)
            cells = {}
            for key, _ in PLATFORMS:
                if key not in feature:
                    raise ParityError(f"{ident}: no value for {key}")
                cells[key] = cell_of(feature[key], f"{ident}.{key}")
            features.append({"id": ident, "name": name, "cells": cells, "notes": feature.get("notes", "")})
        if not area.get("name") or not features:
            raise ParityError("an area needs a name and features")
        areas.append({"name": area["name"], "features": features})
    return areas


def shown(cell):
    status, pr, note = cell
    text = STATUSES[status]
    if status == "pending":
        text = f"In PR [#{pr}]({REPOSITORY}/pull/{pr})"
    elif pr is not None:
        text = f"{text} ([#{pr}]({REPOSITORY}/pull/{pr}))"
    if note:
        text = f"{text}: {note}"
    return text.replace("|", "\\|")


def render(areas):
    lines = [
        "# Feature parity",
        "",
        "Which user-visible features each app has. The macOS app is the reference, and the Linux and Windows apps",
        "follow its behavior. This file is generated: edit [`features.yml`](features.yml), then run",
        "`python3 scripts/parity/render.py`. A pull request that adds or finishes a feature updates its row.",
        "",
        "Status: Yes is shipped. In PR is built in an open pull request. Partial says what ships. No is not built.",
        "n/a does not apply. Unknown has not been checked.",
        "",
        "## Totals",
        "",
        "| | " + " | ".join(label for _, label in PLATFORMS) + " |",
        "|---|" + "---|" * len(PLATFORMS),
    ]
    total = sum(len(area["features"]) for area in areas)
    for status, label in STATUSES.items():
        counts = [
            sum(1 for area in areas for f in area["features"] if f["cells"][key][0] == status)
            for key, _ in PLATFORMS
        ]
        if any(counts):
            lines.append(f"| {label} | " + " | ".join(str(count) for count in counts) + " |")
    lines += ["", f"{total} features.", ""]
    for area in areas:
        lines += [
            f"## {area['name']}",
            "",
            "| Feature | " + " | ".join(label for _, label in PLATFORMS) + " | Notes |",
            "|---|" + "---|" * (len(PLATFORMS) + 1),
        ]
        for feature in area["features"]:
            row = " | ".join(shown(feature["cells"][key]) for key, _ in PLATFORMS)
            lines.append(f"| {feature['name']} | {row} | {feature['notes'].replace('|', chr(92) + '|')} |")
        lines.append("")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail when README.md is out of date")
    arguments = parser.parse_args(argv)
    try:
        text = render(load())
    except ParityError as error:
        print(f"features.yml: {error}", file=sys.stderr)
        return 1
    if arguments.check:
        if not TARGET.exists() or TARGET.read_text(encoding="utf-8") != text:
            print("docs/feature-parity/README.md is out of date: run python3 scripts/parity/render.py", file=sys.stderr)
            return 1
        return 0
    TARGET.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
