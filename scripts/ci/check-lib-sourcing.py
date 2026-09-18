#!/usr/bin/env python3
"""Fails when a script calls a scripts/lib function without sourcing the library that defines it.

A missing `source` line is invisible to every tool the repo already runs. bash -n only parses,
shellcheck cannot know whether a bare word is a function or a command on PATH, and the call site
reads exactly like a working one. It surfaces at run time as exit 127, and for the one script that
only runs during a release, that means it surfaces during a release: v0.67.1's DMG job died with
"exit code 127" right after "DMG signed", because create-dmg.sh called notarize_and_staple and
never sourced scripts/lib/notarize.sh.

Usage: check-lib-sourcing.py [scripts-dir]
"""

import pathlib
import re
import sys

FUNCTION = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", re.M)
# Any .sh named on a source line. Matched by basename so it works whether the script
# writes lib/common.sh or, as macos.sh does from inside lib/, just common.sh.
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

    # Sourcing is transitive: macos.sh sources common.sh, so a script that sources macos.sh gets
    # both. Resolving that is the difference between a useful check and five false reports.
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
