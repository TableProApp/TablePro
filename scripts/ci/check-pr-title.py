#!/usr/bin/env python3
"""Check a pull request title against the commit subject rules, because a squash merge uses it.

The title must be a Conventional Commits subject, `<type>(<scope>)!: <description>`, with the scope
and the `!` optional, and the title must fit in 72 characters. GitHub appends ` (#123)` when it
squashes; that suffix is not counted.

Usage:
    python3 scripts/ci/check-pr-title.py TITLE
"""

import re
import sys

TYPES = ("feat", "fix", "refactor", "perf", "test", "docs", "build", "ci", "chore", "style", "revert")
MAX_TITLE = 72
SUBJECT = re.compile(rf"^(?:{'|'.join(TYPES)})(?:\([a-z0-9][a-z0-9-]*\))?!?: \S")


def problems(title):
    found = []
    if not SUBJECT.match(title):
        found.append(
            f"`{title}` is not a Conventional Commits subject. Use `<type>(<scope>): <description>`, where type is "
            + "one of "
            + ", ".join(TYPES)
            + " and the scope is lowercase words joined by hyphens, for example `fix(editor): keep the caret`"
        )
    if len(title) > MAX_TITLE:
        found.append(f"the title is {len(title)} characters, over the {MAX_TITLE} limit")
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
