#!/usr/bin/env python3
"""Coverage and hidden-string checks for the String Catalogs.

Translation itself goes through Xcode: `xcodebuild -exportLocalizations` writes one XLIFF per
language, `xcodebuild -importLocalizations` merges it back, and Xcode stays the only tool that
rewrites a catalog. CONTRIBUTING.md has the commands.

    scripts/localization.py status              -> per-language coverage
    scripts/localization.py plugins [--add]     -> strings Xcode cannot see, missing or unmanaged
    scripts/localization.py plugins --target ios -> the same for the package targets the iOS app links

Xcode extracts strings per target. Code in a plugin bundle or in a package under `Packages/`
resolves `String(localized:)` against `Bundle.main`, which is the host app, so its strings must be
in the app's catalog, yet no sync of the app target ever finds them in its sources. Xcode deletes
such a key on its next sync (a build in Xcode, an export, an import) unless the key is managed
manually. `plugins` checks that every one of them is present and manual.
"""

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
        sys.exit(f"FATAL: {path} not found. Run from the repository root.")
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


def ios_hidden_source_roots() -> tuple[Path, ...]:
    """The package targets the iOS app links. Every other package never ships on iOS, so its strings
    do not belong in the iOS catalog."""
    roots: list[Path] = []
    package = None
    for line in IOS_PROJECT.read_text(encoding="utf8").splitlines():
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
            root = Path("Packages") / package / "Sources" / product
            if root.is_dir() and not root.is_symlink():
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["plugins", "status"])
    parser.add_argument("--target", choices=sorted(CATALOGS), default="mac")
    parser.add_argument("--add", action="store_true", help="for plugins: add and manage the pending keys")
    args = parser.parse_args()

    if args.command == "plugins":
        return plugins(args.add, args.target)
    status(args.target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
