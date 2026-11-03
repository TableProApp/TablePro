#!/usr/bin/env python3
"""Fail when a driver capability the app reads before the plugin loads differs from the plugin's own value.

Until a plugin's code loads, the app answers from its curated entry in
TablePro/Core/Plugins/PluginMetadataRegistry*.swift. PluginMetadataRegistry.buildMetadataSnapshot then copies
these capabilities straight off the DriverPlugin type, where one the plugin does not declare is PluginKit's
default. So a value the two sides disagree on changes the UI at the first connect of a launch (#2700).

Only a plugin's primary databaseTypeId is compared: registerVariant keeps a variant's curated entry.
A value counts only as a literal, written in place or reached through a reference to a declaration that
holds one, such as HanaMetadata.containerEntityName, cassandraCapabilities or postgreSQL.capabilities.
Any other expression, and an entry or static the check cannot find or read, is a failure.

Usage:
    check-capability-parity.py [--apple <dir>]
"""

import argparse
import re
import sys
from pathlib import Path

APPLE_DIR = Path(__file__).resolve().parents[2]
REGISTRY_GLOB = "TablePro/Core/Plugins/PluginMetadataRegistry*.swift"
PLUGINKIT_DIR = "TableProPluginKit"

# The app reads these before a plugin loads, from the curated snapshot at this path.
CAPABILITIES = {
    "supportsHealthMonitor": ("supportsHealthMonitor",),
    "supportsSSH": ("capabilities", "supportsSSH"),
    "supportsSSL": ("capabilities", "supportsSSL"),
    "supportsForeignKeyDisable": ("capabilities", "supportsForeignKeyDisable"),
    "containerEntityName": ("schema", "containerEntityName"),
}

CONSTRUCTED_TYPES = {"PluginMetadataSnapshot", "CapabilityFlags", "SchemaInfo"}
# These copy every capability above unchanged. withSwitchRouting takes another snapshot's container name.
KEEPS_CAPABILITIES = {"withIconName", "withExplainVariants", "withSystemNames", "withBranding", "withIsDownloadable"}
MAX_HOPS = 16

OPEN, CLOSE = "([{", ")]}"
TOP_TOKEN = re.compile(r'//|/\*|(#*)("""|")')
CODE_TOKEN = re.compile(r'//|/\*|(#*)("""|")|[()]')
COMMENT_TOKEN = re.compile(r"/\*|\*/")
BRACKET = re.compile(r"[()\[\]{}]")
CONTINUATION = re.compile(r"\s*\.")
STRING_TOKENS = {}
ENTRY = re.compile(r'\(\s*(?:typeId\s*:\s*)?"((?:[^"\\\n]|\\.)*)"\s*,\s*(?:snapshot\s*:\s*)?')
DECLARATION = re.compile(r"\b(class|struct|enum|actor|extension)\s+([A-Z]\w*)\b([^{};]*)\{")
STATIC = re.compile(
    r"^[ \t]*(?:@\w+(?:\([^)\n]*\))?\s+)*"
    r"(?:(?:public|private|fileprivate|internal|open|nonisolated|override|final)(?:\([^)\n]*\))?\s+)*"
    r"(?:static\s+(?:let|var)|class\s+var)\s+(\w+)\s*(?::[^={\n]+?)?\s*(=|\{)",
    re.M,
)
LABEL = re.compile(r"\s*([A-Za-z_]\w*)\s*:(?!:)")
CONSTRUCTOR = re.compile(r"(?:[A-Z]\w*\.)*([A-Z]\w*)\s*\(")
MODIFIER = re.compile(r"\.\s*(\w+)\s*\(")
SNAPSHOT_PARAMETER = re.compile(r"([a-z]\w*)((?:\.[A-Za-z_]\w*)+)")
CALL = re.compile(r"(?:Self\.)?([a-z]\w*)\s*\(")
NAME = re.compile(r"(?:Self\.|PluginMetadataRegistry\.)?([a-z]\w*)")
MEMBER = re.compile(r"([A-Z]\w*)\.([A-Za-z_]\w*)")
BOOL = re.compile(r"true|false")
ESCAPES = {'"': '"', "\\": "\\", "n": "\n", "t": "\t", "r": "\r", "0": "\0", "'": "'"}


class Unreadable(Exception):
    pass


def mask(text):
    # A bracket or a declaration inside a comment or a string must not count, and an offset into the result
    # must still point at the same character of the original, where a literal's value is read.
    spans = []
    i = 0
    while True:
        token = TOP_TOKEN.search(text, i)
        if not token:
            break
        if token.group(0) == "//":
            end = text.find("\n", token.start())
            end = len(text) if end < 0 else end
            spans.append((token.start(), end, " "))
        elif token.group(0) == "/*":
            end = skip_block_comment(text, token.start())
            spans.append((token.start(), end, " "))
        else:
            hashes, multiline = len(token.group(1)), token.group(2) == '"""'
            close = skip_string(text, token.end(), hashes, multiline)
            spans.append((token.end(), close, "x"))
            end = close + len(token.group(2)) + hashes
        i = end
    out, emitted = [], 0
    for start, end, keep in spans:
        out.append(text[emitted:start])
        out.append(re.sub(r"[^\n]", keep, text[start:end]))
        emitted = end
    out.append(text[emitted:])
    return "".join(out)


def skip_block_comment(text, i):
    depth = 0
    for token in COMMENT_TOKEN.finditer(text, i):
        depth += 1 if token.group(0) == "/*" else -1
        if depth == 0:
            return token.end()
    return len(text)


def skip_string(text, i, hashes, multiline):
    pattern = STRING_TOKENS.get((hashes, multiline))
    if pattern is None:
        close = re.escape('"""' if multiline else '"') + "#" * hashes
        pattern = STRING_TOKENS[(hashes, multiline)] = re.compile(r"\\" + "#" * hashes + r"(\(|.)|" + close, re.S)
    while True:
        token = pattern.search(text, i)
        if not token:
            raise Unreadable("a string literal is never closed")
        if not token.group(0).startswith("\\"):
            return token.start()
        i = skip_interpolation(text, token.end()) if token.group(1) == "(" else token.end()


def skip_interpolation(text, i):
    depth = 0
    while True:
        token = CODE_TOKEN.search(text, i)
        if not token:
            raise Unreadable("an interpolation is never closed")
        lexeme = token.group(0)
        if lexeme == "(":
            depth += 1
            i = token.end()
        elif lexeme == ")":
            if depth == 0:
                return token.end()
            depth -= 1
            i = token.end()
        elif lexeme == "//":
            end = text.find("\n", token.start())
            i = len(text) if end < 0 else end
        elif lexeme == "/*":
            i = skip_block_comment(text, token.start())
        else:
            hashes, quotes = len(token.group(1)), token.group(2)
            i = skip_string(text, token.end(), hashes, quotes == '"""') + len(quotes) + hashes


class Source:
    def __init__(self, path, root):
        self.path = path
        self.name = path.relative_to(root).as_posix()
        self.text = path.read_text(encoding="utf-8")
        try:
            self.code = mask(self.text)
        except Unreadable as error:
            raise Unreadable(f"{self.name}: {error}") from error

    def where(self, offset):
        return f"{self.name}:{self.text.count(chr(10), 0, offset) + 1}"


class Expr:
    def __init__(self, source, start, end):
        while start < end and source.code[start].isspace():
            start += 1
        while end > start and source.code[end - 1].isspace():
            end -= 1
        self.source, self.start, self.end = source, start, end

    @property
    def code(self):
        return self.source.code[self.start:self.end]

    @property
    def text(self):
        return self.source.text[self.start:self.end]

    def where(self):
        return self.source.where(self.start)

    def snippet(self):
        flat = " ".join(self.text.split())
        return flat if len(flat) <= 60 else flat[:57] + "..."


def matching(code, i):
    depth = 0
    for bracket in BRACKET.finditer(code, i):
        depth += 1 if bracket.group(0) in OPEN else -1
        if depth == 0:
            return bracket.start()
    raise Unreadable("a bracket is never closed")


def expression_end(code, i):
    # A line break ends a Swift statement unless the next line goes on with a member, as .withSystemNames(...) does.
    depth, begun = 0, False
    j = i
    while j < len(code):
        c = code[j]
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            if depth == 0:
                return j
            depth -= 1
        elif depth == 0 and c in ",;":
            return j
        elif depth == 0 and c == "\n" and begun and not CONTINUATION.match(code, j):
            return j
        begun = begun or not c.isspace()
        j += 1
    return j


def literal(expr):
    if BOOL.fullmatch(expr.code):
        return expr.code == "true"
    quoted = re.fullmatch(r'(#*)"([^"\n]*)"\1', expr.code)
    if not quoted:
        return None
    hashes = quoted.group(1)
    body = expr.text[len(hashes) + 1:len(expr.text) - len(hashes) - 1]
    if "\\" + hashes + "(" in body:
        return None
    if hashes:
        return body
    value, k = [], 0
    while k < len(body):
        if body[k] == "\\" and k + 1 < len(body) and body[k + 1] in ESCAPES:
            value.append(ESCAPES[body[k + 1]])
            k += 2
        else:
            value.append(body[k])
            k += 1
    return "".join(value)


def arguments(expr, open_at):
    source = expr.source
    close = matching(source.code, open_at)
    if close >= expr.end:
        raise Unreadable(f"{expr.where()}: `{expr.snippet()}` is never closed")
    args = {}
    start = open_at + 1
    while start < close:
        end = expression_end(source.code, start)
        if end > close:
            end = close
        label = LABEL.match(source.code, start, end)
        if label:
            name = label.group(1)
            if name in args:
                raise Unreadable(f"{source.where(start)}: passes {name} twice")
            args[name] = Expr(source, label.end(), end)
        start = end + 1
    return args, Expr(source, close + 1, expr.end)


def describe(value):
    return ("true" if value else "false") if isinstance(value, bool) else f'"{value}"'


def normalized(name):
    return re.sub(r"\W", "", name).lower()


class Curated:
    def __init__(self, sources):
        self.sources = sources
        self.entries = {}
        for source in sources:
            for found in ENTRY.finditer(source.text):
                quote = found.start(1) - 1
                if source.code[found.start()] != "(" or source.code[quote] != '"':
                    continue
                # A call such as requestTemplate("Scan", ...) is not an entry; a tuple follows a bracket or a comma.
                before = source.code[:found.start()].rstrip()
                if before and (before[-1].isalnum() or before[-1] in "_)]?!>"):
                    continue
                type_id = literal(Expr(source, quote, found.end(1) + 1))
                if type_id is None:
                    continue
                end = expression_end(source.code, found.end())
                self.entries.setdefault(type_id, []).append(Expr(source, found.end(), end))

    def resolve(self, expr, path, hops=0):
        if hops > MAX_HOPS:
            raise Unreadable(f"{expr.where()}: follows more than {MAX_HOPS} references")
        value = literal(expr)
        if value is not None:
            if path:
                raise Unreadable(f"{expr.where()}: `{expr.snippet()}` has no {path[0]}")
            return value, expr.where()
        code = expr.code

        constructed = CONSTRUCTOR.match(code)
        if constructed and constructed.group(1) in CONSTRUCTED_TYPES:
            args, tail = arguments(expr, expr.start + constructed.end() - 1)
            self.check_tail(tail)
            if not path:
                raise Unreadable(f"{expr.where()}: `{expr.snippet()}` is not a literal")
            if path[0] not in args:
                raise Unreadable(f"{expr.where()}: {constructed.group(1)}(...) passes no {path[0]}")
            return self.resolve(args[path[0]], path[1:], hops)

        parameter = SNAPSHOT_PARAMETER.fullmatch(code)
        if parameter:
            entry = self.entry_for_parameter(parameter.group(1), expr)
            return self.resolve(entry, list(parameter.group(2)[1:].split(".")) + list(path), hops + 1)

        call = CALL.match(code)
        if call:
            close = matching(code, call.end() - 1)
            if code[close + 1:].strip():
                raise Unreadable(f"{expr.where()}: cannot read `{expr.snippet()}` as a literal")
            return self.resolve(self.function_body(call.group(1), expr), path, hops + 1)

        named = NAME.fullmatch(code)
        if named:
            return self.resolve(self.binding(named.group(1), expr), path, hops + 1)

        raise Unreadable(f"{expr.where()}: cannot read `{expr.snippet()}` as a literal")

    def check_tail(self, tail):
        rest = tail
        while rest.code:
            modifier = MODIFIER.match(rest.code)
            if not modifier or modifier.group(1) not in KEEPS_CAPABILITIES:
                raise Unreadable(f"{rest.where()}: `{rest.snippet()}` may change a capability this check compares")
            close = matching(rest.source.code, rest.start + modifier.end() - 1)
            rest = Expr(rest.source, close + 1, rest.end)

    def entry_for_parameter(self, name, expr):
        # KingbaseES's entry is PostgreSQL's, passed in as `postgreSQL: PluginMetadataSnapshot`.
        declared = re.compile(r"\b" + re.escape(name) + r"\s*:\s*PluginMetadataSnapshot\b")
        if not any(declared.search(source.code) for source in self.sources):
            raise Unreadable(f"{expr.where()}: `{name}` is not a PluginMetadataSnapshot parameter")
        named = [type_id for type_id in self.entries if normalized(type_id) == normalized(name)]
        if len(named) != 1 or len(self.entries[named[0]]) != 1:
            raise Unreadable(f"{expr.where()}: `{name}` names no single curated entry")
        return self.entries[named[0]][0]

    def function_body(self, name, expr):
        pattern = re.compile(r"\bfunc\s+" + re.escape(name) + r"\s*\(")
        found = [(source, match) for source in self.sources for match in pattern.finditer(source.code)]
        if len(found) != 1:
            raise Unreadable(f"{expr.where()}: {len(found)} functions named {name}")
        source, match = found[0]
        parameters_end = matching(source.code, match.end() - 1)
        body_open = source.code.index("{", parameters_end)
        body = Expr(source, body_open + 1, matching(source.code, body_open))
        returned = re.match(r"return\b", body.code)
        return Expr(source, body.start + returned.end(), body.end) if returned else body

    def binding(self, name, expr):
        pattern = re.compile(r"\blet\s+" + re.escape(name) + r"\s*(?::[^=\n]+)?=")
        found = [(source, match) for source in self.sources for match in pattern.finditer(source.code)]
        if len(found) != 1:
            raise Unreadable(f"{expr.where()}: {len(found)} let bindings named {name}")
        source, match = found[0]
        return Expr(source, match.end(), expression_end(source.code, match.end()))


def conforms_to_driver_plugin(clause):
    return re.search(r"\bDriverPlugin\b", clause) is not None


class Declared:
    def __init__(self, name, folder, source, clause):
        self.name, self.folder, self.source = name, folder, source
        self.is_driver = conforms_to_driver_plugin(clause)
        self.statics = {}


def statics_in(source, body_open, body_close):
    # Only the top level: a static of a nested type is not the plugin's.
    code = source.code
    found = []
    depth, counted = 0, body_open + 1
    for match in STATIC.finditer(code, body_open + 1, body_close):
        depth += code.count("{", counted, match.start()) - code.count("}", counted, match.start())
        counted = match.start()
        if depth != 0:
            continue
        if match.group(2) == "=":
            found.append((match.group(1), Expr(source, match.end(), expression_end(source.code, match.end()))))
        else:
            brace = match.end() - 1
            body = Expr(source, brace + 1, matching(source.code, brace))
            returned = re.match(r"return\b", body.code)
            found.append((match.group(1), Expr(source, body.start + returned.end(), body.end) if returned else body))
    return found


class Plugins:
    def __init__(self, plugins_dir, root):
        self.plugins_dir = plugins_dir
        self.types = []
        self.defaults = {}
        extensions = []
        for path in sorted(plugins_dir.rglob("*.swift")):
            folder = path.relative_to(plugins_dir).parts[0]
            # A test bundle's doubles are not what the plugin ships, and may share a real type's name.
            if folder.endswith("Tests"):
                continue
            source = Source(path, root)
            for match in DECLARATION.finditer(source.code):
                body_open = match.end() - 1
                try:
                    body_close = matching(source.code, body_open)
                    members = statics_in(source, body_open, body_close)
                except Unreadable as error:
                    raise Unreadable(f"{source.where(body_open)}: {error}") from error
                if match.group(1) == "extension":
                    extensions.append((match.group(2), folder, match.group(3), members))
                else:
                    declared = Declared(match.group(2), folder, source, match.group(3))
                    self.add(declared, members)
                    self.types.append(declared)
        for name, folder, clause, members in extensions:
            if name == "DriverPlugin" and folder == PLUGINKIT_DIR:
                for member, expr in members:
                    self.defaults.setdefault(member, []).append(expr)
            for declared in self.types:
                if declared.name == name and declared.folder == folder:
                    declared.is_driver = declared.is_driver or conforms_to_driver_plugin(clause)
                    self.add(declared, members)

    @staticmethod
    def add(declared, members):
        for member, expr in members:
            declared.statics.setdefault(member, []).append(expr)

    def drivers(self):
        for folder in sorted(path.name for path in self.plugins_dir.iterdir() if (path / "Info.plist").is_file()):
            found = [declared for declared in self.types if declared.folder == folder and declared.is_driver]
            if len(found) > 1:
                yield folder, None, f"{len(found)} types conform to DriverPlugin"
            elif found:
                yield folder, found[0], None
            elif any(declared.folder == folder and "databaseTypeId" in declared.statics for declared in self.types):
                yield folder, None, "declares databaseTypeId on a type that does not visibly conform to DriverPlugin"

    def find(self, name, near, expr):
        found = [declared for declared in self.types if declared.name == name and declared.folder == near]
        if not found:
            found = [declared for declared in self.types if declared.name == name]
        if len(found) != 1:
            raise Unreadable(f"{expr.where()}: {len(found)} types named {name}")
        return found[0]

    def static(self, declared, member, hops=0):
        if hops > MAX_HOPS:
            raise Unreadable(f"{declared.name}.{member} follows more than {MAX_HOPS} references")
        exprs = declared.statics.get(member, [])
        if len(exprs) > 1:
            places = ", ".join(expr.where() for expr in exprs)
            raise Unreadable(f"{declared.name} declares {member} {len(exprs)} times ({places})")
        if exprs:
            return self.value(exprs[0], declared, hops)
        if not declared.is_driver:
            raise Unreadable(f"{declared.source.name}: {declared.name} declares no static {member}")
        defaults = self.defaults.get(member, [])
        if len(defaults) != 1:
            raise Unreadable(f"PluginKit has {len(defaults)} defaults for {member}")
        value, where = self.value(defaults[0], None, hops)
        return value, f"PluginKit default, {where}"

    def value(self, expr, declared, hops):
        value = literal(expr)
        if value is not None:
            return value, expr.where()
        member = MEMBER.fullmatch(expr.code)
        if member and (member.group(1) != "Self" or declared):
            near = declared.folder if declared else PLUGINKIT_DIR
            owner = declared if member.group(1) == "Self" else self.find(member.group(1), near, expr)
            return self.static(owner, member.group(2), hops + 1)
        raise Unreadable(f"{expr.where()}: cannot read `{expr.snippet()}` as a literal")


def problems_in(apple):
    registry = sorted(apple.glob(REGISTRY_GLOB))
    if not registry:
        raise SystemExit(f"no {REGISTRY_GLOB} under {apple}")
    try:
        curated = Curated([Source(path, apple) for path in registry])
        plugins = Plugins(apple / "Plugins", apple)
    except Unreadable as error:
        return [str(error)], [], 0

    unreadable, mismatches, compared = [], [], 0
    for folder, driver, reason in plugins.drivers():
        if reason:
            unreadable.append(f"{folder}: {reason}")
            continue
        try:
            type_id, _ = plugins.static(driver, "databaseTypeId")
            if not isinstance(type_id, str):
                raise Unreadable(f"databaseTypeId is {describe(type_id)}, not a string")
        except Unreadable as error:
            unreadable.append(f"{folder}: {error}")
            continue
        entries = curated.entries.get(type_id, [])
        if len(entries) != 1:
            places = "".join(f" ({entry.where()})" for entry in entries)
            unreadable.append(f'{folder}: {len(entries)} curated entries for "{type_id}" in {REGISTRY_GLOB}{places}')
            continue
        compared += 1
        for capability, path in CAPABILITIES.items():
            try:
                curated_value, curated_where = curated.resolve(entries[0], path)
                plugin_value, plugin_where = plugins.static(driver, capability)
            except Unreadable as error:
                unreadable.append(f"{type_id} {capability}: {error}")
                continue
            if curated_value != plugin_value:
                mismatches.append(
                    f"{type_id} {capability}: curated {describe(curated_value)} ({curated_where}), "
                    f"plugin {describe(plugin_value)} ({plugin_where})"
                )
    return unreadable, mismatches, compared


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apple", type=Path, default=APPLE_DIR, help="the apple/ folder to check")
    args = parser.parse_args(argv)

    unreadable, mismatches, compared = problems_in(args.apple)
    errors = unreadable + mismatches
    if errors:
        for error in errors:
            print(f"::error::{error}", file=sys.stderr)
        hint = (
            " The plugin's value replaces the curated one once its code loads: declare the same value on both sides."
            if mismatches
            else ""
        )
        print(f"\n{len(errors)} problem(s).{hint}", file=sys.stderr)
        return 1
    if compared == 0:
        print(f"::error::no driver plugin under {args.apple / 'Plugins'}", file=sys.stderr)
        return 1
    print(f"{compared} driver plugins agree with their curated entries on {', '.join(CAPABILITIES)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
