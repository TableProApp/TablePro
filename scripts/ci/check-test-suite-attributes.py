#!/usr/bin/env python3
"""Check no top-level type in TableProTests carries a @Suite that has no trait.

Swift Testing finds a type's @Test functions without any @Suite on it, so `@Suite("Some name")`
only renames the type in Xcode's test navigator and in the result bundle. What it costs is compile
time, and the cost grows with the square of how many there are. @Suite is a peer macro, and a peer
macro may introduce uniquely named declarations, so the compiler files every top-level one in
module-scope lookup under a single placeholder for "some unique name". Each @Suite expansion emits
declarations that refer to each other by unique name, and every one of those lookups walks the
whole placeholder list, expanding every other top-level @Suite in the module to see what it
declared.

Measured on the macOS Tests build job (Xcode 26.4.1, 3 vCPU, 7 GB): with 2,309 top-level @Suite
attributes in TableProTests, the target's emit-module job ran for 544 to 626 seconds, the longest
compile job in the whole build, and half of the samples taken in it sat in that lookup. Removing
the 2,173 that carried only a display name took the emit-module job to 290 seconds on the same
runner, and the target's compile batches, summed, from 3,958 to 2,373 seconds. The emit-module
window had tracked the count as it grew: 238 seconds at 1,644 suites, 340 at 1,826, 622 at 2,163.

So a top-level @Suite is allowed only when it carries a trait (.serialized, .enabled(if:),
.disabled, .timeLimit, a tag), which is the one thing an unannotated type cannot express. Nested
suites and @Test functions are not checked: their expansions are members of a type, and member
lookup does not walk the module.

Pure text, no Xcode: it runs on Ubuntu in about a second, and test_check_test_suite_attributes.py
pins what it must and must not report.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SCANNED = "TableProTests"
ATTRIBUTE = re.compile(r"@(?:Testing\.)?Suite\b")
INTERESTING = re.compile(r'[{}"#/@]')


class SwiftText:
    """Enough of a Swift lexer to tell code from comments and string literals, and to find the
    brace depth of a position. Regex literals are not recognised; test sources do not put braces
    or quotes in them."""

    def __init__(self, text: str) -> None:
        self.text = text

    def comment_end(self, index: int) -> int | None:
        text = self.text
        if text.startswith("//", index):
            newline = text.find("\n", index)
            return len(text) if newline < 0 else newline
        if not text.startswith("/*", index):
            return None
        depth = 0
        position = index
        while position < len(text):
            if text.startswith("/*", position):
                depth += 1
                position += 2
            elif text.startswith("*/", position):
                depth -= 1
                position += 2
                if depth == 0:
                    return position
            else:
                position += 1
        return len(text)

    def string_end(self, index: int) -> int | None:
        text = self.text
        hashes = 0
        while text.startswith("#", index + hashes):
            hashes += 1
        opening = index + hashes
        if not text.startswith('"', opening):
            return None
        multiline = text.startswith('"""', opening)
        delimiter = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        position = opening + (3 if multiline else 1)
        while position < len(text):
            if text.startswith(escape, position):
                after = position + len(escape)
                if text.startswith("(", after):
                    position = self.balanced_end(after)
                else:
                    position = after + 1
            elif text.startswith(delimiter, position):
                return position + len(delimiter)
            elif not multiline and text[position] == "\n":
                return position
            else:
                position += 1
        return len(text)

    def non_code_end(self, index: int) -> int | None:
        """The end of the comment or string literal that starts at `index`, if one does."""
        comment = self.comment_end(index)
        if comment is not None:
            return comment
        return self.string_end(index)

    def balanced_end(self, index: int) -> int:
        """The position just past the bracket that closes the one at `index`."""
        text = self.text
        closing = {"(": ")", "[": "]", "{": "}"}
        stack = [closing[text[index]]]
        position = index + 1
        while position < len(text) and stack:
            skipped = self.non_code_end(position)
            if skipped is not None:
                position = skipped
                continue
            character = text[position]
            if character in closing:
                stack.append(closing[character])
            elif character == stack[-1]:
                stack.pop()
            position += 1
        return position

    def top_level_attributes(self) -> list[tuple[int, int]]:
        """(start, end) of every @Suite attribute at brace depth zero, arguments included."""
        text = self.text
        found: list[tuple[int, int]] = []
        depth = 0
        position = 0
        while True:
            match = INTERESTING.search(text, position)
            if match is None:
                return found
            position = match.start()
            skipped = self.non_code_end(position)
            if skipped is not None:
                position = skipped
                continue
            character = text[position]
            if character == "{":
                depth += 1
            elif character == "}":
                depth = max(depth - 1, 0)
            elif character == "@" and depth == 0:
                attribute = ATTRIBUTE.match(text, position)
                if attribute is not None:
                    end = self.arguments_end(attribute.end())
                    found.append((position, end))
                    position = end
                    continue
            position += 1

    def arguments_end(self, index: int) -> int:
        position = index
        while position < len(self.text) and self.text[position] in " \t":
            position += 1
        if position < len(self.text) and self.text[position] == "(":
            return self.balanced_end(position)
        return index

    def arguments(self, start: int, end: int) -> list[str]:
        """The top-level arguments of an attribute's argument list, comments removed."""
        text = self.text
        opening = text.find("(", start, end)
        if opening < 0:
            return []
        items: list[str] = []
        current: list[str] = []
        position = opening + 1
        closing = end - 1
        while position < closing:
            comment = self.comment_end(position)
            if comment is not None:
                current.append(" ")
                position = comment
                continue
            skipped = self.string_end(position)
            if skipped is None and text[position] in "([{":
                skipped = self.balanced_end(position)
            if skipped is not None:
                current.append(text[position:skipped])
                position = skipped
                continue
            if text[position] == ",":
                items.append("".join(current).strip())
                current = []
            else:
                current.append(text[position])
            position += 1
        items.append("".join(current).strip())
        return [item for item in items if item]


def is_string_literal(expression: str) -> bool:
    return SwiftText(expression).string_end(0) == len(expression)


def carries_a_trait(arguments: list[str]) -> bool:
    return any(not is_string_literal(argument) for argument in arguments)


def offenders(root: Path) -> list[tuple[str, int, str]]:
    found: list[tuple[str, int, str]] = []
    for path in sorted((root / SCANNED).rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "Suite" not in text:
            continue
        source = SwiftText(text)
        for start, end in source.top_level_attributes():
            if carries_a_trait(source.arguments(start, end)):
                continue
            line = text.count("\n", 0, start) + 1
            attribute = " ".join(text[start:end].split())
            found.append((path.relative_to(root).as_posix(), line, attribute))
    return found


def main_for(root: Path) -> int:
    found = offenders(root)
    if not found:
        return 0

    for path, line, attribute in found:
        print(f"{path}:{line}: {attribute}")
    print()
    print(
        f"{len(found)} top-level @Suite attribute(s) with no trait. Each top-level @Suite adds compile time to the "
        "test module quadratically, because every @Suite expansion walks every other top-level @Suite."
    )
    print(
        "Leave the type unannotated: Swift Testing finds its @Test functions anyway, and a @Test display name is "
        "fine. Keep @Suite only to carry a trait such as .serialized or .enabled(if:)."
    )
    return 1


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    return main_for(root)


if __name__ == "__main__":
    sys.exit(main())
