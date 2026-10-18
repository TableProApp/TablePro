#!/usr/bin/env python3

import re
import sys

TYPES = ("feat", "fix", "refactor", "perf", "test", "docs", "build", "ci", "chore", "style", "revert")
MAX_TITLE = 72
SUBJECT = re.compile(rf"^(?:{'|'.join(TYPES)})(?:\([a-z0-9][a-z0-9-]*\))?!?: \S")
# A pick into a release line keeps its subject from main, whose trailing (#N) names its origin.
PROVENANCE = re.compile(r" \(#[0-9]+\)$")


def problems(title):
    found = []
    if not SUBJECT.match(title):
        found.append(
            f"`{title}` is not a Conventional Commits subject. Use `<type>(<scope>): <description>`, where type is "
            + "one of "
            + ", ".join(TYPES)
            + " and the scope is lowercase words joined by hyphens, for example `fix(editor): keep the caret`"
        )
    length = len(PROVENANCE.sub("", title, count=1))
    if length > MAX_TITLE:
        found.append(f"the title is {length} characters, over the {MAX_TITLE} limit")
    return found


def workflow_command_data(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(argv):
    if len(argv) != 2:
        sys.exit("Usage: check-pr-title.py TITLE")
    title = argv[1]
    found = problems(title)
    for problem in found:
        print(f"::error title=Pull request title::{workflow_command_data(problem)}")
    if found:
        return 1
    print(f"OK: {title}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
