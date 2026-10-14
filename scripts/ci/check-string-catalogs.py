#!/usr/bin/env python3
"""Check the string catalogs for translations that would format the wrong value.

A translation is data, so the compiler never reads it, and `xcstringstool compile` accepts a `%lld`
retyped as `%@` or a dropped argument without a warning. String(format:) then formats garbage or
traps. The rules below are the ones the shipped catalogs already keep.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

CATALOGS = {
    "TablePro": "TablePro/Resources/Localizable.xcstrings",
    "TableProMobile": "TableProMobile/TableProMobile/Localizable.xcstrings",
}
TERMINAL_MARKS = {":": (":", "："), "?": ("?", "？"), ".": (".", "。")}
# SQL notation, written the way SQL documentation writes it, not a UI ellipsis.
TECHNICAL_ELLIPSES = ("ALTER...DROP", "OVER(...)", ", ...)")
SPECIFIER = re.compile(
    r"%(?:#@[^@]*@|(?:(?P<index>\d+)\$)?[-+ #0]*\d*(?:\.\d*)?(?P<length>ll|hh|l|h|z|q)?(?P<conversion>[@diuUfFeEgGxXoscpaA%]))"
)
TOKEN = re.compile(r"\$\{[^}]*\}")


def specifiers(text: str) -> list[tuple[int | None, str]]:
    found = []
    for match in SPECIFIER.finditer(text):
        conversion = match.group("conversion")
        if conversion is None or conversion == "%":
            continue
        index = match.group("index")
        found.append((int(index) if index else None, (match.group("length") or "") + conversion))
    return found


def arguments(text: str, substitutions: dict[int, str]) -> dict[int, str]:
    result = {index or position + 1: kind for position, (index, kind) in enumerate(specifiers(text))}
    result.update(substitutions)
    return result


def mismatch(source: str, source_subs: dict[int, str], value: str, value_subs: dict[int, str]) -> str | None:
    expected = arguments(source, source_subs)
    found = arguments(value, value_subs)
    if not expected and not found:
        return None
    indices = [index for index, _ in specifiers(value)]
    if None in indices and any(index is not None for index in indices):
        return "mixes positional and plain specifiers"
    if set(found) != set(expected):
        want = ",".join(map(str, sorted(expected))) or "no arguments"
        got = ",".join(map(str, sorted(found))) or "none"
        return f"consumes {got} but the source passes {want}"
    for index in sorted(expected):
        if expected[index] != found[index]:
            return f"argument {index} is %{found[index]} but the source passes %{expected[index]}"
    return None


def ends_with_ellipsis(text: str) -> bool:
    return text.endswith("...") or text.endswith("…")


def substitutions(localization: dict) -> dict[int, str]:
    return {s["argNum"]: s["formatSpecifier"] for s in (localization.get("substitutions") or {}).values()}


def translated_units(payload: dict):
    source_language = payload["sourceLanguage"]
    for key, entry in sorted(payload["strings"].items()):
        localizations = entry.get("localizations") or {}
        source_localization = localizations.get(source_language) or {}
        source = (source_localization.get("stringUnit") or {}).get("value", key)
        source_subs = substitutions(source_localization)
        for language, localization in sorted(localizations.items()):
            if language == source_language:
                continue
            units = [localization["stringUnit"]] if "stringUnit" in localization else []
            for variation in (localization.get("variations") or {}).values():
                units += [case["stringUnit"] for case in variation.values() if "stringUnit" in case]
            for unit in units:
                if unit.get("state") == "translated":
                    yield key, source, source_subs, language, unit["value"], substitutions(localization)


def offenders(name: str, payload: dict) -> list[str]:
    found = []
    for key, entry in sorted(payload["strings"].items()):
        if name == "TablePro" and "..." in key and entry.get("extractionState") != "stale" and not any(t in key for t in TECHNICAL_ELLIPSES):
            found.append(f'{name}: "{key}" spells its ellipsis with three periods, use …')
    for key, source, source_subs, language, value, value_subs in translated_units(payload):
        where = f'{name}:{language}: "{key}" -> "{value}"'
        complaint = mismatch(source, source_subs, value, value_subs)
        if complaint:
            found.append(f"{where}: {complaint}")
        if "^[" in value:
            found.append(f"{where}: carries inflection markup, which only English applies")
        if sorted(TOKEN.findall(key)) != sorted(TOKEN.findall(value)):
            found.append(f"{where}: loses or adds a Shortcuts ${{parameter}} token")
        if ends_with_ellipsis(key) != ends_with_ellipsis(value):
            found.append(f"{where}: trailing ellipsis differs from the source")
        elif not ends_with_ellipsis(key):
            mark = next((m for m in TERMINAL_MARKS if key.endswith(m)), None)
            if mark and not value.endswith(TERMINAL_MARKS[mark]):
                found.append(f"{where}: drops the source's closing {mark}")
    return found


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    found = []
    for name, path in CATALOGS.items():
        found += offenders(name, json.loads((root / path).read_text(encoding="utf-8")))
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
