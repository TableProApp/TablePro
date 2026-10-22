"""Keyboard path for every clickable control on a surface.

Each accessible name maps to how a keyboard user reaches the same action:
"shortcut: ...", "menu: ...", "tab-stop", or "gap: ..." for a known missing
path. A clickable that is not listed fails the scenario, so a new
mouse-only control cannot appear unnoticed.
"""

PATH_KINDS = ("shortcut:", "menu:", "tab-stop", "gap:")

SQL_EDITOR = {
    "Run": "shortcut: Ctrl+Enter",
    "Explain": "menu: Main menu > Explain query",
    "Fold block": "shortcut: Ctrl+Shift+[",
    "Unfold all": "shortcut: Ctrl+Shift+]",
    "Session": "tab-stop",
    "Pin results": "tab-stop",
    "Split": "tab-stop",
    "New query (Ctrl+E)": "shortcut: Ctrl+E",
    "Close Tab": "shortcut: Ctrl+W",
    "New connection": "tab-stop",
    "Open saved connection": "shortcut: Ctrl+P (Open Quickly lists connections)",
    "Main menu": "shortcut: F10",
    "Search tables": "tab-stop",
    "New Table\u2026": "tab-stop",
    "Table from CSV\u2026": "tab-stop",
    "Open safety_items": "tab-stop (Enter on the sidebar row)",
    "Close": "shortcut: Ctrl+Q",
    "Minimize": "tab-stop",
    "Maximize": "tab-stop",
}


def unregistered(names, registry):
    return sorted({name for name in names if name not in registry})


def malformed(registry):
    return sorted(name for name, path in registry.items() if not path.startswith(PATH_KINDS))
