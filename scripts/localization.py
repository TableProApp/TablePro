#!/usr/bin/env python3
"""Export one language out of a String Catalog and merge it back.

A `.xcstrings` file interleaves every language inside every key, so a translator who changes
fifty Vietnamese strings produces a diff scattered through a 109,000-line file, next to Turkish
and Chinese they never touched. Nobody can review that, which is why translation contributions
stall.

    scripts/localization.py export vi            -> Localization/vi.json
    scripts/localization.py import vi            -> merges it back
    scripts/localization.py status               -> per-language coverage

The exported file is flat and sorted: one key, one string, so it can be edited by hand or fed to
any translation tool. It is a working copy and is not committed; the catalog stays the single
source of truth. Export, edit, import, then commit the catalog.

The merge is byte-exact for everything it did not translate. That matters more than it sounds:
a merge that reformats the catalog puts the reviewer back in front of a 109,000-line diff, which
is the problem this exists to remove. Two Xcode quirks have to be reproduced for that to hold,
and both are covered by `verify`:

  - the key separator is " : ", not ": "
  - an empty object is written across three lines, not as "{}"
  - there is no trailing newline

Keys keep the catalog's own order. Sorting them looks tidier and rewrites the entire file.
"""

import argparse
import json
import re
import sys
from pathlib import Path

CATALOGS = {
    "mac": Path("TablePro/Resources/Localizable.xcstrings"),
    "ios": Path("TableProMobile/TableProMobile/Localizable.xcstrings"),
}
EXPORT_DIR = Path("Localization")


def load(path: Path) -> dict:
    if not path.exists():
        sys.exit(f"FATAL: {path} not found. Run from the repository root.")
    return json.loads(path.read_text(encoding="utf8"))


def serialize(catalog: dict) -> str:
    """Reproduce Xcode's own formatting exactly, so an untouched string stays untouched."""
    out = json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : "))
    return re.sub(
        r"(?m)^(\s*)\S.*?: \{\}",
        lambda m: m.group(0)[:-2] + "{\n\n" + m.group(1) + "}",
        out,
    )


def source_value(key: str, entry: dict, source_language: str) -> str:
    localization = (entry.get("localizations") or {}).get(source_language)
    if localization:
        unit = localization.get("stringUnit") or {}
        if unit.get("value"):
            return unit["value"]
    return key


def export(target: str, language: str) -> None:
    path = CATALOGS[target]
    catalog = load(path)
    source_language = catalog.get("sourceLanguage", "en")
    if language == source_language:
        sys.exit(f"FATAL: {language} is the source language; there is nothing to translate.")

    rows = {}
    for key, entry in sorted((catalog.get("strings") or {}).items()):
        if not key:
            continue
        unit = ((entry.get("localizations") or {}).get(language) or {}).get("stringUnit") or {}
        row = {
            "source": source_value(key, entry, source_language),
            "translation": unit.get("value", ""),
        }
        # Surfaced so a translator can find what still needs attention. The merge ignores it:
        # state belongs to whoever reviewed the string, not to whoever edited this file.
        if unit.get("state") and unit["state"] != "translated":
            row["state"] = unit["state"]
        rows[key] = row

    EXPORT_DIR.mkdir(exist_ok=True)
    out = EXPORT_DIR / f"{target}.{language}.json"
    out.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n", encoding="utf8")

    translated = sum(1 for row in rows.values() if row["translation"])
    print(f"{out}: {translated}/{len(rows)} translated")


def merge(target: str, language: str) -> None:
    path = CATALOGS[target]
    source = EXPORT_DIR / f"{target}.{language}.json"
    if not source.exists():
        sys.exit(f"FATAL: {source} not found. Run export first.")

    catalog = load(path)
    before = serialize(catalog)
    rows = json.loads(source.read_text(encoding="utf8"))
    strings = catalog.get("strings") or {}

    changed = 0
    unknown = []
    for key, row in rows.items():
        translation = row.get("translation") or ""
        # Only blankness is tested against the stripped form. Leading and trailing whitespace is
        # meaningful in these strings, and stripping the stored value silently corrupts them.
        if not translation.strip():
            continue
        entry = strings.get(key)
        if entry is None:
            unknown.append(key)
            continue
        localizations = entry.setdefault("localizations", {})
        unit = localizations.setdefault(language, {}).setdefault("stringUnit", {})
        # Only a changed value is a translation. Rewriting state on an untouched string would
        # quietly clear someone's needs_review, and would make an unedited round-trip produce a
        # diff, which is the thing this tool exists to prevent.
        if unit.get("value") == translation:
            continue
        unit["value"] = translation
        unit["state"] = "translated"
        changed += 1

    after = serialize(catalog)
    if after == before:
        print("No change.")
        return

    path.write_text(after, encoding="utf8")
    print(f"{path}: {changed} string(s) updated")
    if unknown:
        print(f"Skipped {len(unknown)} key(s) not in the catalog, first few: {unknown[:5]}")


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


def verify() -> int:
    """A round-trip that changes nothing must produce a byte-identical file."""
    failures = 0
    for name, path in CATALOGS.items():
        original = path.read_text(encoding="utf8")
        if serialize(json.loads(original)) != original:
            print(f"FAIL: re-serializing {path} does not reproduce it byte for byte")
            failures += 1
        else:
            print(f"ok: {path}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["export", "import", "status", "verify"])
    parser.add_argument("language", nargs="?", help="for example vi, tr, zh-Hans")
    parser.add_argument("--target", choices=sorted(CATALOGS), default="mac")
    args = parser.parse_args()

    if args.command == "verify":
        return verify()
    if args.command == "status":
        status(args.target)
        return 0
    if not args.language:
        sys.exit(f"FATAL: {args.command} needs a language, for example: {args.command} vi")
    if args.command == "export":
        export(args.target, args.language)
    else:
        merge(args.target, args.language)
    return 0


if __name__ == "__main__":
    sys.exit(main())
