#!/usr/bin/env python3
"""Fail when a plugin's TableProProvides* Info.plist keys differ from the ids its Swift class declares.

The app registers a plugin from these keys without loading its code, and loads a plugin that has
none at launch. The first database type id is the plugin's primary one.

Usage:
    check-plugin-provides.py [--plugins <dir>]           # compare every Plugins/*/Info.plist
    check-plugin-provides.py [--plugins <dir>] --write   # stamp the keys from the Swift ids
"""

import argparse
import plistlib
import re
import sys
from pathlib import Path

PLUGINS_DIR = Path(__file__).resolve().parents[2] / "Plugins"

DATABASE_KEY = "TableProProvidesDatabaseTypeIds"
EXPORT_KEY = "TableProProvidesExportFormatIds"
IMPORT_KEY = "TableProProvidesImportFormatIds"
KEYS = (DATABASE_KEY, EXPORT_KEY, IMPORT_KEY)

STATIC = r"^[ \t]*(?:[a-z]+[ \t]+)*static[ \t]+(?:let|var)[ \t]+"
PRIMARY_ID = re.compile(STATIC + r"databaseTypeId(?:\s*:\s*String)?\s*=\s*\"([^\"]+)\"", re.M)
EXTRA_IDS = re.compile(STATIC + r"additionalDatabaseTypeIds(?:\s*:\s*\[String\])?\s*=\s*\[([^\]]*)\]", re.M)
FORMAT_ID = re.compile(STATIC + r"formatId(?:\s*:\s*String)?\s*=\s*\"([^\"]+)\"", re.M)
EXPORTER = re.compile(r"\b(?:class|struct|enum|actor)\s+\w+\s*:[^{]*\bExportFormatPlugin\b")
IMPORTER = re.compile(r"\b(?:class|struct|enum|actor)\s+\w+\s*:[^{]*\bImportFormatPlugin\b")
STRING = re.compile(r"\"([^\"]*)\"")
# INFOPLIST_PREPROCESS substitutes these at build time, so the source file is not a valid plist.
MACRO_INTEGER = re.compile(r"<integer>([A-Z_][A-Z0-9_]*)</integer>")
SENTINEL_BASE = 1 << 62


class Unreadable(Exception):
    pass


def plugin_directories(plugins_dir):
    return sorted(path for path in plugins_dir.iterdir() if (path / "Info.plist").is_file())


def find_one(pattern, sources, what):
    found = [(path, match) for path, text in sources for match in pattern.finditer(text)]
    if len(found) > 1:
        names = ", ".join(sorted({path.name for path, _ in found}))
        raise Unreadable(f"declares {what} {len(found)} times ({names})")
    return found[0][1] if found else None


def provided_ids(directory):
    sources = [(path, path.read_text(encoding="utf-8")) for path in sorted(directory.rglob("*.swift"))]
    expected = {}

    primary = find_one(PRIMARY_ID, sources, "databaseTypeId")
    if primary:
        extra = find_one(EXTRA_IDS, sources, "additionalDatabaseTypeIds")
        expected[DATABASE_KEY] = [primary.group(1)] + (STRING.findall(extra.group(1)) if extra else [])

    format_id = find_one(FORMAT_ID, sources, "formatId")
    if format_id:
        is_exporter = any(EXPORTER.search(text) for _, text in sources)
        is_importer = any(IMPORTER.search(text) for _, text in sources)
        if not (is_exporter or is_importer):
            raise Unreadable("declares formatId but no type conforms to ExportFormatPlugin or ImportFormatPlugin")
        if is_exporter:
            expected[EXPORT_KEY] = [format_id.group(1)]
        if is_importer:
            expected[IMPORT_KEY] = [format_id.group(1)]

    if not expected:
        raise Unreadable("declares neither databaseTypeId nor formatId as a string literal")
    return expected


def read_plist(path):
    macros = {}

    def to_sentinel(match):
        value = macros.setdefault(match.group(1), SENTINEL_BASE + len(macros))
        return f"<integer>{value}</integer>"

    text = MACRO_INTEGER.sub(to_sentinel, path.read_text(encoding="utf-8"))
    try:
        info = plistlib.loads(text.encode("utf-8"))
    except Exception as error:
        raise Unreadable(f"Info.plist does not parse: {error}") from error
    if not isinstance(info, dict):
        raise Unreadable("Info.plist is not a dictionary")
    return info, macros


def write_plist(path, info, macros):
    text = plistlib.dumps(info, sort_keys=True).decode("utf-8")
    for name, value in macros.items():
        text = text.replace(f"<integer>{value}</integer>", f"<integer>{name}</integer>")
    path.write_text(text, encoding="utf-8")


def problems_in(directory, write=False):
    expected = provided_ids(directory)
    info, macros = read_plist(directory / "Info.plist")

    problems = []
    for key in KEYS:
        declared = info.get(key)
        wanted = expected.get(key)
        if declared == wanted:
            continue
        if wanted is None:
            problems.append(f"{directory.name}: Info.plist has {key} {declared}, the class provides none")
        elif declared is None:
            problems.append(f"{directory.name}: Info.plist has no {key}, the class provides {wanted}")
        else:
            problems.append(f"{directory.name}: Info.plist has {key} {declared}, the class provides {wanted}")

    if write and problems:
        for key in KEYS:
            info.pop(key, None)
        info.update(expected)
        write_plist(directory / "Info.plist", info, macros)
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--plugins", type=Path, default=PLUGINS_DIR)
    parser.add_argument("--write", action="store_true", help="rewrite the keys from the Swift ids")
    args = parser.parse_args(argv)

    directories = plugin_directories(args.plugins)
    if not directories:
        sys.exit(f"no Info.plist under {args.plugins}/*/")

    unreadable, mismatches = [], []
    for directory in directories:
        try:
            problems = problems_in(directory, args.write)
        except Unreadable as error:
            unreadable.append(f"{directory.name}: {error}")
            continue
        if problems and args.write:
            print(f"stamped {directory.name}/Info.plist")
        else:
            mismatches += problems

    errors = unreadable + mismatches
    if errors:
        for error in errors:
            print(f"::error::{error}", file=sys.stderr)
        hint = " Run scripts/ci/check-plugin-provides.py --write" if mismatches else ""
        print(f"\n{len(errors)} problem(s).{hint}", file=sys.stderr)
        return 1
    if not args.write:
        print(f"{len(directories)} plugin Info.plists declare the ids their classes provide")
    return 0


if __name__ == "__main__":
    sys.exit(main())
