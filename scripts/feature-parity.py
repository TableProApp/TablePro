#!/usr/bin/env python3
"""Write docs/feature-parity/README.md from docs/feature-parity/features.yml.

Usage:
  scripts/feature-parity.py           write README.md
  scripts/feature-parity.py --check   fail when features.yml is invalid or README.md is not what it writes
"""

import argparse
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs" / "feature-parity" / "features.yml"
TARGET = SOURCE.with_name("README.md")
PULL = "https://github.com/TableProApp/TablePro/pull/"

PLATFORMS = (("linux", "Linux"), ("windows", "Windows"))
STATUSES = {
    "yes": ("Yes", "On `main`."),
    "pending": ("In #N", "In that open pull request."),
    "partial": ("Partial", "Part of it is on `main`. The note says which part."),
    "no": ("No", "Not built."),
    "na": ("n/a", "Does not apply to that app. The note says why."),
    "unknown": ("Unknown", "Not checked yet."),
}
NEEDS_NOTE = {"partial", "na"}
NUMBER = re.compile(r"[1-9][0-9]*")
REFERENCE = re.compile(r"#([1-9][0-9]*)\b")

HEADER = """# Feature parity

Which of the macOS app's features the Linux and Windows apps have. A feature with no row has not been compared yet.
What the Linux app does in each area, in detail: [linux/ROADMAP.md](../../linux/ROADMAP.md#implemented).

`scripts/feature-parity.py` writes this file from [features.yml](features.yml). Edit that file, then run the script.

| Status | Meaning |
|---|---|
"""


class RegistryError(ValueError):
    pass


def one_line(text, where, what):
    if not isinstance(text, str) or not text.strip() or "\n" in text:
        raise RegistryError(f"{where}: {what} is one line of text")
    return text.strip()


def cell(value, where):
    if isinstance(value, str):
        value = {"status": value}
    if not isinstance(value, dict):
        raise RegistryError(f"{where}: give a status, or a mapping of status, pr and note")
    extra = sorted(set(value) - {"status", "pr", "note"})
    if extra:
        raise RegistryError(f"{where}: unknown keys {', '.join(extra)}")
    status, pr, note = value.get("status"), value.get("pr"), value.get("note")
    if status not in STATUSES:
        raise RegistryError(f"{where}: status {status!r} is not one of {', '.join(STATUSES)}")
    if (status == "pending") != (pr is not None):
        raise RegistryError(f"{where}: pr names the open pull request of a pending feature, and only of one")
    if pr is not None and not (isinstance(pr, str) and NUMBER.fullmatch(pr)):
        raise RegistryError(f"{where}: pr {pr!r} is not a pull request number")
    if note is not None:
        note = one_line(note, where, "note")
    elif status in NEEDS_NOTE:
        raise RegistryError(f"{where}: a {status} feature says why in a note")
    return status, pr, note


def load(path):
    # BaseLoader keeps every scalar a string, so yes and no stay statuses instead of YAML 1.1 booleans.
    with Path(path).open(encoding="utf-8") as handle:
        document = yaml.load(handle, Loader=yaml.BaseLoader)
    areas = document.get("areas") if isinstance(document, dict) else None
    if not isinstance(areas, list) or not areas:
        raise RegistryError("give a list of areas")
    names = set()
    loaded = []
    for area in areas:
        if not isinstance(area, dict) or set(area) != {"name", "features"}:
            raise RegistryError("an area has a name and features, and nothing else")
        title = one_line(area["name"], "area", "name")
        if not isinstance(area["features"], list) or not area["features"]:
            raise RegistryError(f"{title}: give a list of features")
        features = []
        for feature in area["features"]:
            expected = {"name"} | {key for key, _ in PLATFORMS}
            if not isinstance(feature, dict) or set(feature) != expected:
                raise RegistryError(f"{title}: a feature has exactly {', '.join(sorted(expected))}")
            name = one_line(feature["name"], title, "name")
            if name in names:
                raise RegistryError(f"{name}: listed twice")
            names.add(name)
            cells = [cell(feature[key], f"{name}, {key}") for key, _ in PLATFORMS]
            features.append((name, cells))
        loaded.append((title, features))
    return loaded


def linked(text):
    return REFERENCE.sub(lambda match: f"[#{match[1]}]({PULL}{match[1]})", text.replace("|", "\\|"))


def shown(status, pr, note):
    text = f"In [#{pr}]({PULL}{pr})" if status == "pending" else STATUSES[status][0]
    return f"{text}: {linked(note)}" if note else text


def render(areas):
    lines = [HEADER.rstrip("\n")]
    lines += [f"| {label} | {meaning} |" for label, meaning in STATUSES.values()]
    header = "| Feature | " + " | ".join(label for _, label in PLATFORMS) + " |"
    for title, features in areas:
        lines += ["", f"## {title}", "", header, "|---" * (len(PLATFORMS) + 1) + "|"]
        for name, cells in features:
            lines.append("| " + " | ".join([linked(name)] + [shown(*value) for value in cells]) + " |")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Write docs/feature-parity/README.md from features.yml.")
    parser.add_argument("--check", action="store_true", help="fail when README.md is not what features.yml writes")
    arguments = parser.parse_args(argv)
    try:
        text = render(load(SOURCE))
    except (OSError, yaml.YAMLError, RegistryError) as error:
        print(f"{SOURCE.relative_to(ROOT)}: {error}", file=sys.stderr)
        return 1
    if not arguments.check:
        TARGET.write_text(text, encoding="utf-8")
        return 0
    if not TARGET.is_file() or TARGET.read_text(encoding="utf-8") != text:
        print(f"{TARGET.relative_to(ROOT)} is stale. Run scripts/feature-parity.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
