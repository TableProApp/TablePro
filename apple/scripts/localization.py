#!/usr/bin/env python3
"""Coverage and hidden-string checks for the String Catalogs.

Translation itself goes through Xcode: `xcodebuild -exportLocalizations` writes one XLIFF per
language, `xcodebuild -importLocalizations` merges it back, and Xcode stays the only tool that
rewrites a catalog. CONTRIBUTING.md has the commands.

    scripts/localization.py status              -> per-language coverage
    scripts/localization.py plugins [--add]     -> strings Xcode cannot see, missing or unmanaged
    scripts/localization.py plugins --target ios -> the same for the package targets the iOS app links
    scripts/localization.py extracted [--add]   -> strings the app's last build extracted, missing

Xcode extracts strings per target. Code in a plugin bundle or in a package under `Packages/`
resolves `String(localized:)` against `Bundle.main`, which is the host app, so its strings must be
in the app's catalog, yet no sync of the app target ever finds them in its sources. Xcode deletes
such a key on its next sync (a build in Xcode, an export, an import) unless the key is managed
manually. `plugins` checks that every one of them is present and manual.

Only Xcode itself syncs a catalog: a build from the command line extracts the app's strings into
`.stringsdata` files and never adds them. `extracted` reads those files from the last build and
lists every key the catalog lacks. `--derived-data` names the build's DerivedData folder; without
it, xcodebuild reports the project's default one.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

CATALOGS = {
    "mac": Path("TablePro/Resources/Localizable.xcstrings"),
    "ios": Path("TableProMobile/TableProMobile/Localizable.xcstrings"),
}
HIDDEN_SOURCE_ROOTS = (Path("Plugins"), Path("Packages"))
IOS_PROJECT = Path("TableProMobile/project.yml")
# The project, its scheme, and the targets whose sources hold the catalog.
APP_BUILDS = {
    "mac": ("TablePro.xcodeproj", "TablePro", ("TablePro",)),
    "ios": ("TableProMobile/TableProMobile.xcodeproj", "TableProMobile", ("TableProMobile", "TableProWidgetExtension")),
}

# Xcode writes a catalog through JSONSerialization with exactly these options. Writing through the
# same call keeps the file identical to what Xcode would write, so its next sync moves nothing.
WRITE_LIKE_XCODE = """
import Foundation
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: input))
try JSONSerialization.data(
    withJSONObject: catalog,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
).write(to: output)
"""


def load(path: Path) -> dict:
    if not path.exists():
        sys.exit(f"FATAL: {path} not found. Run from apple/.")
    return json.loads(path.read_text(encoding="utf8"))


def write(path: Path, catalog: dict) -> None:
    with tempfile.TemporaryDirectory() as scratch:
        script = Path(scratch) / "write.swift"
        script.write_text(WRITE_LIKE_XCODE, encoding="utf8")
        source = Path(scratch) / "catalog.json"
        source.write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf8")
        subprocess.run(["xcrun", "swift", str(script), str(source), str(path)], check=True)


def status(target: str) -> None:
    catalog = load(CATALOGS[target])
    source_language = catalog.get("sourceLanguage", "en")
    strings = {k: v for k, v in (catalog.get("strings") or {}).items() if k}

    languages: dict[str, int] = {}
    for entry in strings.values():
        for language, localization in (entry.get("localizations") or {}).items():
            if language == source_language:
                continue
            if ((localization.get("stringUnit") or {}).get("value") or "").strip():
                languages[language] = languages.get(language, 0) + 1

    total = len(strings)
    print(f"{CATALOGS[target]}  source={source_language}  keys={total}")
    for language in sorted(languages):
        done = languages[language]
        print(f"  {language:<8} {done:>5}/{total}  {done * 100 // max(total, 1):>3}%")


# A call wrapped after `String(` and a literal holding `\"` both read as a key. The first pattern
# missed both, so a wrapped message and every one naming a quoted value never reached the catalog.
PLUGIN_KEY = re.compile(r'String\(\s*localized:\s*"(?!"")((?:[^"\\]|\\.)*)"')
PLUGIN_MULTILINE_KEY = re.compile(r'String\(\s*localized:\s*"""[ \t]*\n(.*?)\n([ \t]*)"""', re.DOTALL)
SWIFT_ESCAPE = re.compile(r'\\(u\{[0-9A-Fa-f]+\}|[ntr0"\'\\])')
SWIFT_ESCAPED_CHARACTER = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def swift_literal_value(literal: str) -> str:
    """The string a Swift literal spells, which is what the catalog keys it by."""

    def replace(match: re.Match) -> str:
        escape = match.group(1)
        if escape.startswith("u{"):
            return chr(int(escape[2:-1], 16))
        return SWIFT_ESCAPED_CHARACTER[escape]

    return SWIFT_ESCAPE.sub(replace, literal)


def swift_multiline_literal(body: str, indent: str) -> str:
    """The text of a `\"\"\"` literal: the closing delimiter's indent is stripped from every line,
    and a line ending in an unescaped backslash continues without a newline."""
    text = ""
    for line in body.split("\n"):
        line = line.removeprefix(indent)
        trailing = len(line) - len(line.rstrip("\\"))
        if trailing % 2:
            text += line[:-1]
        else:
            text += line + "\n"
    return text.removesuffix("\n")


def source_literals(source: str) -> list[str]:
    literals = [match.group(1) for match in PLUGIN_KEY.finditer(source)]
    literals += [swift_multiline_literal(*match.groups()) for match in PLUGIN_MULTILINE_KEY.finditer(source)]
    return literals


def hidden_keys(roots: tuple[Path, ...] = HIDDEN_SOURCE_ROOTS) -> list[str]:
    """Every literal that plugin and package code asks to localize, in source order."""
    seen: dict[str, None] = {}
    for root in roots:
        for path in sorted(root.rglob("*.swift")):
            # Tests never ship, and `.build` holds SwiftPM's checkouts of third-party code.
            if "Tests" in path.parts or any(part.startswith(".") for part in path.parts):
                continue
            for literal in source_literals(path.read_text(encoding="utf8", errors="replace")):
                # An interpolated key is a different defect: it never matches any catalog entry.
                if literal and "\\(" not in literal:
                    seen.setdefault(swift_literal_value(literal), None)
    return list(seen)


# Only the package products the iOS app links ship on iOS, so only their strings belong in its catalog.
def ios_hidden_source_roots(project: Path = IOS_PROJECT, packages: Path = Path("Packages")) -> tuple[Path, ...]:
    roots: list[Path] = []
    package = None
    for line in project.read_text(encoding="utf8").splitlines():
        stripped = line.strip()
        if stripped.startswith("- package:"):
            package = stripped.split(":", 1)[1].strip()
            continue
        if stripped.startswith("- framework:") or stripped.startswith("- target:") or stripped.startswith("- sdk:"):
            package = None
            continue
        if package is None:
            continue
        if stripped.startswith("product:"):
            products = [stripped.split(":", 1)[1].strip()]
        elif stripped.startswith("- ") and ":" not in stripped:
            products = [stripped[2:].strip()]
        else:
            continue
        for product in products:
            # TableProPluginKit's root is a symlink to Plugins/, and its strings ship on iOS all the same.
            root = packages / package / "Sources" / product
            if root.is_dir():
                roots.append(root)
    return tuple(dict.fromkeys(roots))


def hidden_source_roots(target: str) -> tuple[Path, ...]:
    return ios_hidden_source_roots() if target == "ios" else HIDDEN_SOURCE_ROOTS


def is_managed(entry: dict) -> bool:
    # Symbol generation stays off: the app sets STRING_CATALOG_GENERATE_SYMBOLS, which covers every
    # manual key, and keys such as "Output" and "output" would generate the same symbol.
    return entry.get("extractionState") == "manual" and entry.get("generatesSymbol") is False


def unmanaged_keys(strings: dict, keys: list[str]) -> list[str]:
    return [key for key in keys if not is_managed(strings.get(key) or {})]


def manage(strings: dict, keys: list[str]) -> None:
    for key in keys:
        entry = strings.setdefault(key, {})
        entry["extractionState"] = "manual"
        entry["generatesSymbol"] = False


def plugins(add: bool, target: str) -> int:
    path = CATALOGS[target]
    catalog = load(path)
    strings = catalog["strings"]
    pending = unmanaged_keys(strings, hidden_keys(hidden_source_roots(target)))

    if not pending:
        print(f"ok: every plugin and package string is in {path}, managed manually")
        return 0

    if not add:
        print(f"{len(pending)} plugin or package strings are missing from {path} or not managed manually:")
        for key in pending[:20]:
            print(f"  {key!r}")
        if len(pending) > 20:
            print(f"  ... and {len(pending) - 20} more")
        print("Run with --add to add them and mark them managed manually.")
        return 1

    manage(strings, pending)
    write(path, catalog)
    print(f"managed {len(pending)} plugin and package strings in {path}")
    return 0


# The compiler places a string from a #Preview body at the macro's line. A preview never ships, and
# Xcode's own sync leaves its strings out of the catalog.
PREVIEW_MACRO = re.compile(r"\s*#Preview\b")


def objects_root(target: str, derived_data: Path | None) -> Path:
    if derived_data is not None:
        return derived_data / "Build" / "Intermediates.noindex"
    project, scheme, _ = APP_BUILDS[target]
    settings = subprocess.run(
        ["xcodebuild", "-project", project, "-scheme", scheme, "-showBuildSettings", "-skipPackagePluginValidation"],
        check=True, capture_output=True, text=True,
    ).stdout
    for line in settings.splitlines():
        name, _, value = line.strip().partition(" = ")
        if name == "OBJROOT":
            return Path(value)
    sys.exit(f"FATAL: xcodebuild reported no OBJROOT for {project}")


def extracted_strings(objects: Path, targets: tuple[str, ...], table: str) -> list[dict]:
    newest: dict[tuple[str, str], tuple[float, dict]] = {}
    for target in targets:
        for path in objects.glob(f"*.build/*/{target}.build/**/*.stringsdata"):
            data = json.loads(path.read_text(encoding="utf8"))
            # A deleted file's copy stays behind until a clean build.
            if not Path(data["source"]).is_file():
                continue
            # Each build configuration keeps its own copy: only the newest is current.
            slot = (target, path.name)
            modified = path.stat().st_mtime
            if slot not in newest or modified > newest[slot][0]:
                newest[slot] = (modified, data)

    extracted: list[dict] = []
    for _, (_, data) in sorted(newest.items()):
        lines = Path(data["source"]).read_text(encoding="utf8", errors="replace").splitlines()
        entries = []
        for entry in (data.get("tables") or {}).get(table, []):
            line = (entry.get("location") or {}).get("startingLine", 0)
            if not (0 < line <= len(lines) and PREVIEW_MACRO.match(lines[line - 1])):
                entries.append(entry)
        if entries:
            extracted.append({**data, "tables": {table: entries}})
    return extracted


def extracted_keys(extracted: list[dict], table: str) -> list[str]:
    return list(dict.fromkeys(entry["key"] for data in extracted for entry in data["tables"][table]))


# Xcode's own sync writes each new entry, so a key with a default value or a comment comes out as an
# Xcode build would write it.
def synced_entries(path: Path, extracted: list[dict], keys: list[str]) -> dict:
    wanted = set(keys)
    with tempfile.TemporaryDirectory() as scratch:
        # xcstringstool matches a table to a catalog by the catalog's file name.
        copy = Path(scratch) / path.name
        copy.write_text(json.dumps({"sourceLanguage": "en", "strings": {}, "version": "1.1"}), encoding="utf8")
        arguments = []
        for index, data in enumerate(extracted):
            entries = [entry for entry in data["tables"][path.stem] if entry["key"] in wanted]
            if entries:
                stringsdata = Path(scratch) / f"{index}.stringsdata"
                stringsdata.write_text(json.dumps({**data, "tables": {path.stem: entries}}), encoding="utf8")
                arguments += ["--stringsdata", str(stringsdata)]
        subprocess.run(["xcrun", "xcstringstool", "sync", str(copy), *arguments], check=True, capture_output=True)
        return json.loads(copy.read_text(encoding="utf8"))["strings"]


def extracted(add: bool, target: str, derived_data: Path | None) -> int:
    path = CATALOGS[target]
    catalog = load(path)
    strings = catalog["strings"]
    objects = objects_root(target, derived_data)
    targets = APP_BUILDS[target][2]
    found = extracted_strings(objects, targets, path.stem)

    if not found:
        print(f"no build of {', '.join(targets)} under {objects}: build the app, then run this again")
        return 2

    pending = [key for key in extracted_keys(found, path.stem) if key not in strings]
    if not pending:
        print(f"ok: every string the last build of {', '.join(targets)} extracted is in {path}")
        return 0

    if not add:
        print(f"{len(pending)} strings the app uses are missing from {path}:")
        for key in pending[:20]:
            print(f"  {key!r}")
        if len(pending) > 20:
            print(f"  ... and {len(pending) - 20} more")
        print("Run with --add to add them, or build in Xcode, which adds them the same way.")
        return 1

    strings.update(synced_entries(path, found, pending))
    write(path, catalog)
    print(f"added {len(pending)} strings to {path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["extracted", "plugins", "status"])
    parser.add_argument("--target", choices=sorted(CATALOGS), default="mac")
    parser.add_argument("--add", action="store_true", help="for plugins and extracted: add the pending keys")
    parser.add_argument("--derived-data", type=Path, help="for extracted: the DerivedData folder of the app's build")
    args = parser.parse_args()

    if args.command == "plugins":
        return plugins(args.add, args.target)
    if args.command == "extracted":
        return extracted(args.add, args.target, args.derived_data)
    status(args.target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
