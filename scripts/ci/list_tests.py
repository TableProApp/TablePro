#!/usr/bin/env python3
"""Turns xcodebuild's test enumeration into -only-testing or -skip-testing arguments.

Driven by list-tests.sh, which owns the xcodebuild call. Reads TARGET, QUARANTINE, SHARD and MODE
from the environment and takes the enumeration JSON as argv[1]. MODE `skip` prints a -skip-testing
argument for every quarantined case; anything else prints -only-testing for one shard of the rest.
Prints one argument per line and nothing at all when there is none, because the caller turns every
line into an argument and xcodebuild refuses an empty one.
"""

import json
import os
import sys


def quarantined_names(path):
    """Entries to skip. '#' starts a comment, blank lines are ignored."""
    if not path:
        return set()
    names = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            entry = line.split("#", 1)[0].strip()
            if entry:
                names.add(entry)
    return names


def enumerated_identifiers(path):
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)

    errors = payload.get("errors") or []
    if errors:
        sys.exit("test enumeration reported: " + "; ".join(errors))

    identifiers = {
        test["identifier"]
        for value in payload.get("values", [])
        for test in value.get("enabledTests", [])
    }
    return sorted(identifiers)


def forms(identifier):
    """Every spelling an entry may use: Target/Suite/case(), Suite/case() and Suite."""
    parts = identifier.split("/")
    if len(parts) <= 1:
        return {identifier}
    return {identifier, "/".join(parts[1:]), parts[1]}


def parse_shard(raw, total):
    """'I/N' -> (index, count). Absent means one shard holding everything."""
    if not raw:
        return 0, 1
    try:
        index, count = (int(part) for part in raw.split("/", 1))
    except ValueError:
        sys.exit(f"--shard expects I/N, got {raw!r}")
    if count < 1 or not 0 <= index < count:
        sys.exit(f"--shard {raw} is out of range")
    if count > total:
        sys.exit(f"--shard {raw} asks for more shards than there are tests ({total})")
    return index, count


def main():
    target = os.environ["TARGET"]
    identifiers = enumerated_identifiers(sys.argv[1])
    if not identifiers:
        sys.exit(f"test enumeration returned no cases for {target}")

    quarantine = os.environ.get("QUARANTINE")
    skipped = quarantined_names(quarantine)

    known = set()
    for identifier in identifiers:
        known |= forms(identifier)
    inert = sorted(skipped - known)
    if inert:
        sys.exit(
            f"{quarantine}: these entries match no enumerated case, so they skip nothing "
            "(a Swift Testing case needs its parentheses): " + ", ".join(inert)
        )

    quarantined = [identifier for identifier in identifiers if forms(identifier) & skipped]
    if os.environ.get("MODE") == "skip":
        if quarantined:
            print("\n".join(f"-skip-testing:{identifier}" for identifier in quarantined))
        return

    held_back = set(quarantined)
    runnable = [identifier for identifier in identifiers if identifier not in held_back]
    if not runnable:
        sys.exit(f"every enumerated case in {target} is quarantined")

    index, count = parse_shard(os.environ.get("SHARD"), len(runnable))
    selected = runnable[index::count]
    if not selected:
        sys.exit(f"shard {index}/{count} of {target} selected no cases")

    print("\n".join(f"-only-testing:{identifier}" for identifier in selected))


if __name__ == "__main__":
    main()
