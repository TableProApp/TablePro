#!/usr/bin/env python3
"""Fail when the docs assert something about the app that the source contradicts.

Three classes of claim rot faster than anything else in docs, and all three shipped
wrong at once in August 2026: a menu path after the Database menu took commands off
View and Query, a keyboard shortcut after the filter bar moved to Cmd+Option+F, and
the PluginKit ABI number after a breaking bump. Each is mechanically checkable
against the source that defines it, so none of them should ever need a human to
notice.

Run from the repository root or from docs/.
"""

import re
import sys
from pathlib import Path

MENU_FILES = {
    "TablePro": "AppMenuBuilder.swift",
    "File": "FileMenuBuilder.swift",
    "Edit": "EditMenuBuilder.swift",
    "View": "ViewMenuBuilder.swift",
    "Database": "DatabaseMenuBuilder.swift",
    "Query": "QueryMenuBuilder.swift",
    "Window": "WindowMenuBuilder.swift",
    "Help": "HelpMenuBuilder.swift",
}

# A leaf the docs name that the menu builders cannot define, because something else
# builds it: AppKit's own items, a submenu filled at runtime from the server, or a
# contextual menu that happens to read like a menu path.
# The shortcuts page words some rows differently from the action name in Settings >
# Keyboard. Each alias joins a documented row to the case that binds it, so the chord
# is still checked. A row with no alias and no exact title match is reported as
# unchecked rather than passing silently.
SHORTCUT_ALIASES = {
    "Toggle filter bar (table tab)": "toggleFilters",
    "Toggle sidebar": "toggleTableBrowser",
    "Toggle inspector": "toggleInspector",
    "Toggle history": "toggleHistory",
    "Toggle results": "toggleResults",
    "Find": "find",
}

RUNTIME_LEAVES = {
    "Table Maintenance",
    "Schema",
    "Services",
}


def leaf_forms(leaf: str) -> set[str]:
    """Every spelling of a menu item the docs may legitimately use.

    Two differences are conventions, not errors. The style guide drops a trailing
    ellipsis when the sentence instructs, so `Open Quickly…` is written `Open Quickly`.
    And AppKit rewrites a show/hide item's title at runtime, so the builder's
    `Show Connections` appears in the menu bar as `Hide Connections` once the pane is
    open.
    """
    forms = {leaf, leaf.rstrip("…").rstrip()}
    for a, b in (("Show ", "Hide "), ("Hide ", "Show ")):
        if leaf.startswith(a):
            flipped = b + leaf[len(a):]
            forms |= {flipped, flipped.rstrip("…").rstrip()}
    return forms


def repo_root() -> Path:
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "TablePro" / "Core" / "Menu").is_dir():
            return parent
    sys.exit("could not locate the repository root from " + str(here))


def localized_strings(path: Path) -> set[str]:
    return set(re.findall(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"', path.read_text()))


def doc_pages(docs: Path) -> list[Path]:
    return [p for p in sorted(docs.rglob("*.mdx")) if p.name != "changelog.mdx"]


def check_menu_paths(root: Path, docs: Path) -> list[str]:
    menu_dir = root / "TablePro" / "Core" / "Menu"
    per_menu = {}
    for menu, file in MENU_FILES.items():
        forms: set[str] = set()
        for leaf in localized_strings(menu_dir / file):
            forms |= leaf_forms(leaf)
        per_menu[menu] = forms

    every_leaf: set[str] = set()
    for forms in per_menu.values():
        every_leaf |= forms

    failures = []
    pattern = re.compile(r"\*\*(" + "|".join(MENU_FILES) + r") > ([^*]+)\*\*")
    for page in doc_pages(docs):
        for line_no, line in enumerate(page.read_text().splitlines(), start=1):
            for menu, tail in pattern.findall(line):
                leaf = tail.split(" > ")[-1].strip()
                if leaf in RUNTIME_LEAVES or leaf in per_menu[menu]:
                    continue
                where = f"{page.relative_to(docs)}:{line_no}"
                if leaf in every_leaf:
                    owner = next(m for m, s in per_menu.items() if leaf in s)
                    failures.append(
                        f"{where}: **{menu} > {leaf}** lives on the {owner} menu"
                    )
                else:
                    failures.append(
                        f"{where}: **{menu} > {leaf}** is not a menu item in any builder"
                    )
    return failures


def check_shortcuts(root: Path, docs: Path) -> list[str]:
    models = root / "TablePro" / "Models" / "UI" / "KeyboardShortcutModels.swift"
    source = models.read_text()

    titles = dict(
        re.findall(r'case \.(\w+):\s*return String\(localized:\s*"([^"]+)"\)', source)
    )
    bindings = {}
    for case, args in re.findall(r"\.(\w+):\s*\.character\(([^)]*)\)", source):
        key = re.match(r'"([^"]+)"', args.strip())
        if not key:
            continue
        chord = {
            label
            for modifier, label in (
                ("control", "Ctrl"),
                ("option", "Option"),
                ("shift", "Shift"),
                ("command", "Cmd"),
            )
            if re.search(modifier + r":\s*true", args)
        }
        literal = key.group(1)
        chord.add(literal.upper() if len(literal) == 1 else literal)
        bindings[case] = frozenset(chord)

    documented = {}
    table_row = re.compile(r"^\|\s*([^|]+?)\s*\|\s*`([^`]+)`\s*\|")
    shortcuts_page = docs / "features" / "keyboard-shortcuts.mdx"
    for line_no, line in enumerate(shortcuts_page.read_text().splitlines(), start=1):
        row = table_row.match(line)
        if row:
            documented.setdefault(row.group(1).strip(), (row.group(2).strip(), line_no))

    by_title = {title: case for case, title in titles.items()}
    for label, case in SHORTCUT_ALIASES.items():
        by_title.setdefault(label, case)

    failures = []
    checked = 0
    for label, (written, line_no) in documented.items():
        case = by_title.get(label)
        if case is None or case not in bindings:
            continue
        checked += 1
        if frozenset(written.split("+")) != bindings[case]:
            order = ["Ctrl", "Option", "Shift", "Cmd"]
            chord = bindings[case]
            spelled = "+".join(
                [m for m in order if m in chord] + sorted(chord - set(order))
            )
            failures.append(
                f"features/keyboard-shortcuts.mdx:{line_no}: {label} is documented as "
                f"`{written}`, the app binds the chord {spelled}"
            )
    print(f"      {checked} of {len(documented)} documented rows joined to a binding")
    return failures


def check_pluginkit_version(root: Path, docs: Path) -> list[str]:
    manager = (root / "TablePro" / "Core" / "Plugins" / "PluginManager.swift").read_text()
    current = re.search(r"currentPluginKitVersion\s*=\s*(\d+)", manager)
    if not current:
        return ["PluginManager.swift no longer declares currentPluginKitVersion"]
    expected = current.group(1)

    failures = []
    claim = re.compile(
        r"(?:TableProPluginKitVersion|\bpluginKitVersion|currentPluginKitVersion|"
        r"minimumCompatiblePluginKitVersion)\D*?\b(\d{1,3})\b"
    )
    example = re.compile(r"v\d+\.\d+\.\d+:\d+")
    for page in doc_pages(docs / "development"):
        for line_no, line in enumerate(page.read_text().splitlines(), start=1):
            for found in claim.findall(example.sub("", line)):
                if found != expected:
                    failures.append(
                        f"{page.relative_to(docs)}:{line_no}: PluginKit version {found}, "
                        f"the app ships {expected}"
                    )
    return failures


def main() -> int:
    root = repo_root()
    docs = root / "docs"

    checks = (
        ("menu paths", check_menu_paths),
        ("keyboard shortcuts", check_shortcuts),
        ("PluginKit version", check_pluginkit_version),
    )

    total = 0
    for label, check in checks:
        failures = check(root, docs)
        total += len(failures)
        mark = "FAIL" if failures else "ok"
        print(f"{mark:>4}  {label}")
        for failure in failures:
            print(f"        {failure}")

    if total:
        print(f"\n{total} claim(s) in docs/ contradict the source.")
        return 1
    print("\ndocs/ agrees with the source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
