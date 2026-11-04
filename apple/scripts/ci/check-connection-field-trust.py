#!/usr/bin/env python3
"""Fail when a declared connection field has no trust class.

Import, export, share links and sync keep an additional field only by its class in
ConnectionFieldTrust.swift, so a field missing there is dropped from every file and link. A field a
plugin declares `.secure` must be classed `.secret`, and a key listed twice traps at launch.

Usage:
    check-connection-field-trust.py [path...]    # default: the plugin sources and the curated table
"""

import re
import sys
from pathlib import Path

APPLE = Path(__file__).resolve().parents[2]

CATALOG = APPLE / "Packages/TableProCore/Sources/TableProConnectionLibrary/ConnectionFieldTrust.swift"

DEFAULT_PATHS = [
    APPLE / "Plugins",
    APPLE / "TablePro/Core/Plugins",
]

# Where an `id:` constant may be declared.
DECLARATION_ROOTS = [
    APPLE / "Plugins",
    APPLE / "Packages",
    APPLE / "TablePro",
]

FIELD_CALL = re.compile(r"(?<![\w.])ConnectionField\(")
TYPE_DECLARATION = re.compile(r"\b(?:enum|struct|class|actor|extension|protocol)\s+([A-Za-z_][\w.]*)")
NOT_A_TYPE = {"func", "var", "let", "case", "subscript", "init"}
CONSTANT = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::\s*String\s*)?=\s*\"|\bcase\s+(\w+)\s*=\s*\"")
EXPRESSION = re.compile(r"^(?:Self\.)?([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*?)(?:\.rawValue)?$")
CATALOG_ENTRY = re.compile(r"^\s*\"([^\"]+)\":\s*\.(\w+)", re.MULTILINE)


def scan(source):
    """Blank comments and string bodies, keeping offsets; return the masked text and each literal by its quote offset."""
    masked = list(source)
    literals = {}
    i = 0
    length = len(source)

    def blank(start, end):
        for k in range(start, end):
            if masked[k] != "\n":
                masked[k] = " "

    while i < length:
        if source.startswith("//", i):
            end = source.find("\n", i)
            end = length if end == -1 else end
            blank(i, end)
            i = end
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            end = length if end == -1 else end + 2
            blank(i, end)
            i = end
        elif source[i] == '"' or (source[i] == "#" and source.startswith('#"', i)):
            hashes = 0
            while source.startswith("#", i + hashes):
                hashes += 1
            quote = i + hashes
            multiline = source.startswith('"""', quote)
            opener = '"""' if multiline else '"'
            closer = opener + "#" * hashes
            interpolation = "\\" + "#" * hashes + "("
            j = quote + len(opener)
            pieces = []
            plain = True
            while j < length and not source.startswith(closer, j):
                if source.startswith(interpolation, j):
                    plain = False
                    j = matching_paren(source, j + len(interpolation))
                    continue
                if source[j] == "\\":
                    pieces.append(source[j:j + 2])
                    j += 2
                    continue
                if not multiline and source[j] == "\n":
                    break
                pieces.append(source[j])
                j += 1
            literals[quote] = "".join(pieces) if plain else None
            blank(quote + len(opener), j)
            i = j + len(closer)
        else:
            i += 1
    return "".join(masked), literals


def matching_paren(source, start):
    depth = 1
    j = start
    while j < len(source) and depth:
        if source[j] == '"':
            j += 1
            while j < len(source) and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
        elif source[j] == "(":
            depth += 1
        elif source[j] == ")":
            depth -= 1
        j += 1
    return j


def scopes(masked):
    """Yield (offset, kind, value) for each type opening, brace and constant, in source order."""
    events = []
    for match in TYPE_DECLARATION.finditer(masked):
        if match.group(1) not in NOT_A_TYPE:
            events.append((match.start(), "type", match.group(1)))
    for match in re.finditer(r"[{}]", masked):
        events.append((match.start(), match.group(0), None))
    for match in CONSTANT.finditer(masked):
        events.append((match.end() - 1, "constant", match.group(1) or match.group(2)))
    return sorted(events, key=lambda event: event[0])


class SwiftFile:
    def __init__(self, path):
        self.path = path
        self.source = path.read_text(encoding="utf-8")
        self.masked, self.literals = scan(self.source)
        self.constants = []
        self.scope_at = []
        stack = []
        pending = None
        depth = 0
        for offset, kind, value in scopes(self.masked):
            if kind == "type":
                pending = value
            elif kind == "{":
                depth += 1
                if pending is not None:
                    stack.append((depth, pending.split(".")))
                    pending = None
            elif kind == "}":
                if stack and stack[-1][0] == depth:
                    stack.pop()
                depth -= 1
            else:
                path = [part for _, parts in stack for part in parts]
                self.constants.append((path + [value], self.literals.get(offset)))
            self.scope_at.append((offset, [part for _, parts in stack for part in parts]))

    def field_calls(self):
        """Yield (line, id expression, is_secure, enclosing type path) for each ConnectionField( call."""
        for match in FIELD_CALL.finditer(self.masked):
            end = matching_paren(self.masked, match.end())
            arguments = split_arguments(self.masked, match.end(), end - 1)
            line = self.source.count("\n", 0, match.start()) + 1
            identifier = None
            secure = False
            for start, stop in arguments:
                text = self.masked[start:stop].strip()
                if text.startswith("id:"):
                    value_start = start + self.masked[start:stop].index("id:") + 3
                    identifier = self.expression(value_start, stop)
                elif re.fullmatch(r"fieldType:\s*\.secure", text):
                    secure = True
            if identifier is not None:
                yield line, identifier, secure, self.scope(match.start())

    def expression(self, start, stop):
        text = self.masked[start:stop]
        stripped = text.strip()
        if stripped.startswith('"') and stripped.endswith('"'):
            quote = start + text.index('"')
            return ("literal", self.literals.get(quote))
        return ("name", re.sub(r"\s+", "", stripped))

    def scope(self, offset):
        current = []
        for event_offset, path in self.scope_at:
            if event_offset > offset:
                break
            current = path
        return current


def split_arguments(masked, start, end):
    """Top-level comma-separated spans between start and end."""
    spans = []
    depth = 0
    piece = start
    for k in range(start, end):
        char = masked[k]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            spans.append((piece, k))
            piece = k + 1
    spans.append((piece, end))
    return spans


def swift_files(paths):
    for path in paths:
        if path.is_file():
            yield path
        elif path.is_dir():
            for found in sorted(path.rglob("*.swift")):
                if any(part.endswith("Tests") or part == ".build" for part in found.relative_to(path).parts):
                    continue
                yield found


class Resolver:
    def __init__(self, roots):
        self.files = list(swift_files(roots))
        self.folders = {}
        for path in self.files:
            self.folders.setdefault(top_folder(path), []).append(path)
        self.texts = {}
        self.parsed = {}

    def parse(self, path):
        if path not in self.parsed:
            self.parsed[path] = SwiftFile(path)
        return self.parsed[path]

    def text(self, path):
        if path not in self.texts:
            self.texts[path] = path.read_text(encoding="utf-8")
        return self.texts[path]

    def resolve(self, expression, origin, scope):
        match = EXPRESSION.match(expression)
        if not match:
            return None, f"cannot read the id expression {expression}"
        components = match.group(1).split(".")
        name = components[-1]
        tiers = (
            lambda: [origin],
            lambda: [path for path in self.folders.get(top_folder(origin), []) if path != origin],
            lambda: self.files,
        )
        for tier in tiers:
            values = set()
            for parsed in (self.parse(path) for path in tier() if all(word in self.text(path) for word in components[-2:])):
                for path, value in parsed.constants:
                    if path[-1] != name or value is None:
                        continue
                    if len(components) > 1 and path[-len(components):] != components:
                        continue
                    if len(components) == 1 and parsed.path != origin and not shares_scope(path[:-1], scope):
                        continue
                    values.add(value)
            if len(values) == 1:
                return values.pop(), None
            if len(values) > 1:
                return None, f"{expression} is declared with more than one value: {', '.join(sorted(values))}"
        return None, f"cannot resolve {expression} to a string literal"


def shares_scope(declared, scope):
    return bool(declared) and bool(scope) and declared[0] == scope[0]


def top_folder(path):
    if APPLE not in path.parents:
        return (str(path.parent),)
    relative = path.relative_to(APPLE).parts
    if relative[0] == "Packages" and len(relative) > 3:
        return relative[:4]
    return relative[:2]


def catalog_entries(text):
    start = text.find("static let trustByKey")
    if start == -1:
        return None
    open_bracket = text.index("[", text.index("=", start))
    depth = 0
    for k in range(open_bracket, len(text)):
        if text[k] == "[":
            depth += 1
        elif text[k] == "]":
            depth -= 1
            if depth == 0:
                return CATALOG_ENTRY.findall(text[open_bracket:k])
    return None


def main(argv):
    paths = [Path(arg) for arg in argv] or DEFAULT_PATHS
    missing = [path for path in paths + [CATALOG] if not path.exists()]
    if missing:
        for path in missing:
            print(f"error: {path} does not exist", file=sys.stderr)
        return 2

    entries = catalog_entries(CATALOG.read_text(encoding="utf-8"))
    if entries is None:
        print(f"error: {CATALOG} has no trustByKey table", file=sys.stderr)
        return 2

    failures = 0
    classes = {}
    for key, trust in entries:
        if key in classes:
            failures += 1
            print(f"{CATALOG}: {key} is listed twice; a duplicate dictionary key traps at launch")
        classes[key] = trust

    resolver = Resolver([root for root in DECLARATION_ROOTS if root.exists()])
    for path in swift_files(paths):
        if "ConnectionField(" not in resolver.text(path.resolve()):
            continue
        parsed = resolver.parse(path.resolve())
        for line, (kind, value), secure, scope in parsed.field_calls():
            if kind == "literal":
                identifier, problem = value, None if value is not None else "an interpolated id"
            else:
                identifier, problem = resolver.resolve(value, path.resolve(), scope)
            if problem:
                failures += 1
                print(f"{path}:{line}: {problem}; use a string literal or a constant this check can find")
                continue
            trust = classes.get(identifier)
            if trust is None:
                failures += 1
                print(f"{path}:{line}: {identifier} has no class in ConnectionFieldCatalog.trustByKey")
            elif secure and trust != "secret":
                failures += 1
                print(f"{path}:{line}: {identifier} is a secure field but its class is .{trust}, not .secret")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
