#!/usr/bin/env python3
import re
import sys

TYPES = ("feat", "fix", "refactor", "perf", "test", "docs", "build", "ci", "chore", "style", "revert", "security")
SUBJECT = re.compile(rf"^(?:{'|'.join(TYPES)})(?:\([a-z0-9][a-z0-9-]*\))?!?: \S")
MAX_LENGTH = 100


def problems(title):
    found = []
    if not SUBJECT.match(title):
        found.append(
            f"`{title}` is not a Conventional Commits subject. Use `<type>(<scope>): <summary>`, where type is one of "
            + ", ".join(TYPES)
            + " and the scope is lowercase words joined by hyphens, for example `fix(editor): keep the caret`"
        )
    if len(title) > MAX_LENGTH:
        found.append(f"the title is {len(title)} characters; keep it to {MAX_LENGTH}")
    return found


def workflow_command_data(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(argv):
    if len(argv) != 2:
        sys.exit("Usage: check-pr-title.py TITLE")
    title = argv[1].strip()
    found = problems(title)
    for problem in found:
        print(f"::error title=Pull request title::{workflow_command_data(problem)}")
    if found:
        return 1
    print(f"OK: {title}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
