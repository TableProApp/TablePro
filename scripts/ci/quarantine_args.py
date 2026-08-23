#!/usr/bin/env python3
"""Turns a quarantine file into -skip-testing arguments, refusing any entry that skips nothing.

Driven by quarantine-args.sh, which owns the xcodebuild enumeration. This half exists in Python
because the enumeration is JSON and the quarantine file needs comment stripping, and neither is
work bash does without producing the kind of quoting bug the old parser had.

Reads TARGET and QUARANTINE from the environment; takes the enumeration JSON as argv[1].
"""

import json
import os
import sys


def enumerated_identifiers(path):
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)

    errors = payload.get("errors") or []
    if errors:
        sys.exit("test enumeration reported: " + "; ".join(errors))

    return {
        test["identifier"]
        for value in payload.get("values", [])
        for test in value.get("enabledTests", [])
    }


def entries(path):
    """(line number, entry) for every non-comment line."""
    found = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            entry = line.split("#", 1)[0].strip()
            if entry:
                found.append((number, entry))
    return found


def main():
    target = os.environ["TARGET"]
    quarantine = os.environ["QUARANTINE"]
    identifiers = enumerated_identifiers(sys.argv[1])
    if not identifiers:
        sys.exit(f"test enumeration returned no cases for {target}")

    suites = {identifier.split("/")[1] for identifier in identifiers if identifier.count("/") >= 2}

    ok = True
    args = []
    for number, entry in entries(quarantine):
        qualified = f"{target}/{entry}"
        if qualified in identifiers or entry in suites:
            args.append(f"-skip-testing:{qualified}")
            continue

        ok = False
        # The overwhelmingly common mistake, and the one a grep of the sources cannot catch: a
        # Swift Testing case is only skipped when the entry carries its parentheses.
        if f"{qualified}()" in identifiers:
            hint = f"did you mean '{entry}()'? A Swift Testing case needs its parentheses"
        elif "/" in entry and entry.split("/")[0] in suites:
            hint = f"'{entry.split('/')[0]}' exists but has no case named '{entry.split('/', 1)[1]}'"
        else:
            hint = "nothing by that name is enumerated; delete the line"
        print(f"{quarantine}:{number}: '{entry}' would skip nothing: {hint}", file=sys.stderr)

    if not ok:
        sys.exit(1)
    print("\n".join(args))


if __name__ == "__main__":
    main()
