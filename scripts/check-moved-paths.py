#!/usr/bin/env python3
"""Fail when a tracked file still uses a path from before the move out of linux/.

Dated records (docs/archive, docs/evidence, CHANGELOG.md) keep their old paths on purpose.
"""
import re
import subprocess
import sys

OLD = re.compile(
    r"(?<![\w./\-])linux/(crates|scripts|docs|ci|vendor|packaging|flatpak|po|data|tests|testdata"
    r"|Cargo\.(toml|lock)|ARCHITECTURE\.md|ROADMAP\.md)\b"
    r"|(?<![\w.\-])crates/(app|release-tests|driver-tls-tests)\b|(?<![\w.\-])testdata/value-contract"
)
SKIP = ("docs/archive/", "docs/evidence/", "CHANGELOG.md", "docs/proposals/folder-restructure.md",
        "scripts/check-moved-paths.py", "scripts/tests/test_check_moved_paths.py", "vendor/", "apps/linux/po/")


def stale(files):
    found = []
    for name in files:
        if name.startswith(SKIP):
            continue
        try:
            text = open(name, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        found += [(name, n, line.strip()) for n, line in enumerate(text.splitlines(), 1) if OLD.search(line)]
    return found


def main():
    files = subprocess.check_output(["git", "ls-files"], text=True).splitlines()
    found = stale(files)
    for name, n, line in found:
        print(f"{name}:{n}: old path: {line[:120]}")
    print(f"moved paths: {len(found)} stale" if found else "moved paths: ok")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
