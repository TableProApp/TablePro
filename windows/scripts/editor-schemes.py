#!/usr/bin/env python3
# The editor half of each built-in macOS theme becomes one Windows editor color scheme, so both apps offer the same.

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
THEMES = ROOT / "apple" / "TablePro" / "Resources" / "Themes"
OUT = ROOT / "windows" / "src" / "TablePro.Editor.Model" / "ColorSchemes.Themes.cs"

EDITOR = ["background", "text", "cursor", "selection", "currentLine", "currentStatement", "lineNumber"]
SYNTAX = ["keyword", "string", "number", "comment", "operator"]


def argb(value):
    digits = value.lstrip("#")
    if len(digits) == 6:
        digits += "FF"
    if len(digits) != 8:
        raise ValueError(f"not a color: {value}")
    return f"0x{(digits[6:8] + digits[0:6]).upper()}u"


def scheme(path):
    theme = json.loads(path.read_text(encoding="utf-8"))
    editor = theme["editor"]
    colors = [argb(editor[key]) for key in EDITOR] + [argb(editor["syntax"][key]) for key in SYNTAX]
    dark = "true" if theme["appearance"] == "dark" else "false"
    return theme["name"], f'        new("{theme["id"]}", "{theme["name"]}", {dark}, {", ".join(colors)}),'


def main():
    rows = sorted((scheme(path) for path in THEMES.glob("*.json")), key=lambda row: row[0].lower())
    lines = [
        "// Written by windows/scripts/editor-schemes.py from apple/TablePro/Resources/Themes; run it after a theme changes.",
        "namespace TablePro.Editor.Model;",
        "",
        "public static partial class ColorSchemes",
        "{",
        "    public static IReadOnlyList<ColorScheme> All { get; } =",
        "    [",
        *(row for _, row in rows),
        "    ];",
        "}",
        "",
    ]
    OUT.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
