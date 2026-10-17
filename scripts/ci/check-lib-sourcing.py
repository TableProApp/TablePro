#!/usr/bin/env python3
"""Fails when a script calls a scripts/lib function without sourcing the library that defines it.

Usage: check-lib-sourcing.py [scripts-dir]
"""

import pathlib
import re
import sys

FUNCTION = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", re.M)
# Matched by basename: macos.sh, from inside lib/, sources plain common.sh.
SOURCED = re.compile(r"^\s*(?:source|\.)\s+.*?([A-Za-z0-9_.-]+\.sh)", re.M)


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "scripts")
    lib_dir = root / "lib"
    if not lib_dir.is_dir():
        sys.exit(f"check-lib-sourcing.py: no such directory: {lib_dir}")

    # function name -> library that defines it
    owner = {}
    for lib in sorted(lib_dir.glob("*.sh")):
        for name in FUNCTION.findall(lib.read_text(encoding="utf-8")):
            owner.setdefault(name, lib.name)

    # Sourcing is transitive: a script that sources macos.sh also gets common.sh.
    def sourced_libs(text):
        return {name for name in SOURCED.findall(text) if (lib_dir / name).is_file()}

    closure = {}
    for lib in sorted(lib_dir.glob("*.sh")):
        seen, queue = set(), [lib.name]
        while queue:
            name = queue.pop()
            if name in seen:
                continue
            seen.add(name)
            queue.extend(sourced_libs((lib_dir / name).read_text(encoding="utf-8")))
        closure[lib.name] = seen

    problems = []
    for script in sorted(root.rglob("*.sh")):
        if lib_dir in script.parents:
            continue
        source = script.read_text(encoding="utf-8")
        sourced = set()
        for name in sourced_libs(source):
            sourced |= closure.get(name, {name})
        # Defined in the script itself, so it is not the library's to provide.
        local = set(FUNCTION.findall(source))
        for name, lib in sorted(owner.items()):
            if name in local or lib in sourced:
                continue
            call = re.search(rf"^\s*{re.escape(name)}(?:\s|$)", source, re.M)
            if call:
                line = source[: call.start()].count("\n") + 1
                problems.append(f"{script}:{line}: calls {name}, defined in lib/{lib}, without sourcing it")

    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        sys.exit(1)
    print(f"{len(owner)} library functions, every caller sources its library.")


if __name__ == "__main__":
    main()
