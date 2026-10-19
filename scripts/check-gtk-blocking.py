#!/usr/bin/env python3
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
RAW_STRING = re.compile(r"(?:br|r)(#+)?\"")


def tokens(source):
    result = []
    index = 0
    line = 1
    while index < len(source):
        char = source[index]
        if char.isspace():
            line += char == "\n"
            index += 1
            continue
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
            continue
        if source.startswith("/*", index):
            index, line = skip_block_comment(source, index, line)
            continue
        raw = RAW_STRING.match(source, index)
        if raw:
            index, line = skip_raw_string(source, raw, index, line)
            continue
        if char == '"':
            index, line = skip_quoted(source, index, line, char)
            continue
        if char == "'":
            end = source.find("'", index + 1, source.find("\n", index))
            if end >= 0 and end - index <= 12:
                line += source[index : end + 1].count("\n")
                index = end + 1
            else:
                result.append((char, line, index, index + 1))
                index += 1
            continue
        match = IDENTIFIER.match(source, index)
        if match:
            result.append((match.group(), line, index, match.end()))
            index = match.end()
            continue
        value = "::" if source.startswith("::", index) else char
        result.append((value, line, index, index + len(value)))
        index += len(value)
    return result


def skip_block_comment(source, index, line):
    depth = 1
    index += 2
    while index < len(source) and depth:
        if source.startswith("/*", index):
            depth += 1
            index += 2
        elif source.startswith("*/", index):
            depth -= 1
            index += 2
        else:
            line += source[index] == "\n"
            index += 1
    return index, line


def skip_raw_string(source, match, index, line):
    closing = '"' + (match.group(1) or "")
    end = source.find(closing, match.end())
    end = len(source) if end < 0 else end + len(closing)
    return end, line + source[index:end].count("\n")


def skip_quoted(source, index, line, quote):
    index += 1
    while index < len(source):
        if source[index] == "\\":
            line += source[index : index + 2].count("\n")
            index += 2
        elif source[index] == quote:
            return index + 1, line
        else:
            line += source[index] == "\n"
            index += 1
    return index, line


def test_code_ranges(source, lexed):
    values = [token[0] for token in lexed]
    ranges = []
    pattern = ["#", "[", "cfg", "(", "test", ")", "]"]
    for start in range(len(values) - len(pattern) + 1):
        if values[start : start + len(pattern)] != pattern:
            continue
        item = start + len(pattern)
        while item + 1 < len(values) and values[item : item + 2] == ["#", "["]:
            close = item + 2
            depth = 1
            while close < len(values) and depth:
                depth += values[close] == "["
                depth -= values[close] == "]"
                close += 1
            item = close
        delimiter = item
        while delimiter < len(values) and values[delimiter] not in {"{", ";"}:
            delimiter += 1
        if delimiter == len(values):
            continue
        if values[delimiter] == ";":
            end = delimiter
        else:
            depth = 1
            end = delimiter + 1
            while end < len(values) and depth:
                depth += values[end] == "{"
                depth -= values[end] == "}"
                end += 1
            end -= 1
        ranges.append((lexed[start][2], lexed[end][3]))
    return ranges


def production_source(source):
    masked = list(source)
    for start, end in test_code_ranges(source, tokens(source)):
        for index in range(start, end):
            if masked[index] != "\n":
                masked[index] = " "
    return "".join(masked)


def imported_names(lexed):
    values = [token[0] for token in lexed]
    sleep_names = set()
    thread_names = set()
    block_on_names = {"block_on"}
    for index, value in enumerate(values):
        if value != "use":
            continue
        end = index + 1
        while end < len(values) and values[end] != ";":
            end += 1
        statement = values[index + 1 : end]
        if "block_on" in statement:
            block_on = statement.index("block_on")
            block_on_names.add(alias_after(statement, block_on + 1, "block_on"))
        if statement[:3] == ["std", "::", "thread"]:
            collect_thread_imports(statement, sleep_names, thread_names)
        elif statement[:4] == ["std", "::", "{", "thread"]:
            collect_nested_thread_alias(statement, thread_names)
    return sleep_names, thread_names, block_on_names


def collect_thread_imports(statement, sleep_names, thread_names):
    tail = statement[3:]
    if not tail:
        thread_names.add("thread")
    elif tail[:2] == ["::", "sleep"]:
        sleep_names.add(alias_after(tail, 2, "sleep"))
    elif tail and tail[0] == "as":
        thread_names.add(tail[1])
    elif tail[:2] == ["::", "{"]:
        for item in split_items(tail[2:-1]):
            if item and item[0] == "sleep":
                sleep_names.add(alias_after(item, 1, "sleep"))
            elif item and item[0] == "self":
                thread_names.add(alias_after(item, 1, "thread"))


def collect_nested_thread_alias(statement, thread_names):
    items = split_items(statement[3:-1])
    for item in items:
        if item and item[0] == "thread":
            thread_names.add(alias_after(item, 1, "thread"))


def split_items(values):
    items = []
    current = []
    for value in values:
        if value == ",":
            items.append(current)
            current = []
        else:
            current.append(value)
    if current:
        items.append(current)
    return items


def alias_after(values, index, fallback):
    return values[index + 1] if values[index : index + 1] == ["as"] else fallback


def violations(source):
    lexed = tokens(production_source(source))
    values = [token[0] for token in lexed]
    sleep_names, thread_names, block_on_names = imported_names(lexed)
    found = []
    for index, value in enumerate(values):
        if values[index : index + 6] == ["std", "::", "thread", "::", "sleep", "("]:
            found.append((lexed[index][1], "std::thread::sleep"))
        elif value in thread_names and values[index : index + 4] == [value, "::", "sleep", "("]:
            found.append((lexed[index][1], f"{value}::sleep"))
        elif value in sleep_names and values[index + 1 : index + 2] == ["("]:
            found.append((lexed[index][1], f"{value}(...)"))
        if value in block_on_names and values[index + 1 : index + 2] == ["("]:
            found.append((lexed[index][1], value))
    return found


def check_paths(paths):
    failures = []
    for path in paths:
        relative = path.relative_to(ROOT)
        if relative.name.endswith("_tests.rs") or relative.name == "tests.rs":
            continue
        for line, call in violations(path.read_text(encoding="utf-8")):
            failures.append((relative, line, call))
    return failures


def main():
    paths = (ROOT / "apps/linux/app/src/ui").rglob("*.rs")
    failures = check_paths(paths)
    if failures:
        print("error: synchronous waits are not allowed in production GTK UI code:")
        for path, line, call in failures:
            print(f"{path}:{line}: {call}")
        return 1
    print("gtk-blocking: ok (production UI has no blocking sleep or block_on call)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
