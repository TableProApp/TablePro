import re, sys

def mask(src):
    out = list(src)
    n = len(src)

    def blank(i):
        if out[i] != "\n":
            out[i] = " "

    def scan_string(i, hashes, multiline):
        quote = '"""' if multiline else '"'
        closing = quote + "#" * hashes
        i += len(quote)
        while i < n:
            if src[i] == "\\" and src.startswith("#" * hashes, i + 1):
                k = i + 1 + hashes
                if k < n and src[k] == "(":
                    i = scan_code(k + 1, True) + 1
                    continue
                for j in range(i, min(k + 1, n)):
                    blank(j)
                i = k + 1
                continue
            if src.startswith(closing, i):
                return i + len(closing)
            if not multiline and src[i] == "\n":
                return i
            blank(i)
            i += 1
        return i

    def scan_code(i, stop_at_paren):
        depth = 0
        while i < n:
            c = src[i]
            if c == "/" and src.startswith("//", i):
                while i < n and src[i] != "\n":
                    blank(i)
                    i += 1
                continue
            if c == "/" and src.startswith("/*", i):
                level = 0
                while i < n:
                    if src.startswith("/*", i):
                        level += 1
                        blank(i); blank(i + 1)
                        i += 2
                    elif src.startswith("*/", i):
                        level -= 1
                        blank(i); blank(i + 1)
                        i += 2
                        if level == 0:
                            break
                    else:
                        blank(i)
                        i += 1
                continue
            if c == "#" or c == '"':
                j = i
                while j < n and src[j] == "#":
                    j += 1
                if j < n and src[j] == '"':
                    i = scan_string(j, j - i, src.startswith('"""', j))
                    continue
                i = max(j, i + 1)
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0 and stop_at_paren:
                    return i
                depth -= 1
            i += 1
        return i

    scan_code(0, False)
    return "".join(out)

def brace_pairs(masked):
    pairs, stack = {}, []
    for i, c in enumerate(masked):
        if c == "{":
            stack.append(i)
        elif c == "}" and stack:
            pairs[stack.pop()] = i
    return pairs

ATTRIBUTE = r"@[\w.]+(?:\((?:[^()]|\([^()]*\))*\))?"
MODIFIER = (r"(?:public|private|fileprivate|internal|open|package)(?:\(set\))?|static|class|final|override|required|"
            r"convenience|mutating|nonmutating|lazy|weak|unowned(?:\(\w+\))?|dynamic|optional|indirect|"
            r"nonisolated(?:\(unsafe\))?|isolated|distributed|consuming|borrowing|__consuming")
KEYWORDS = ("func|init|deinit|subscript|var|let|case|typealias|associatedtype|class|struct|enum|extension|protocol|"
            "actor|import|operator|precedencegroup|macro")
DECL = re.compile(r"[ \t]*((?:(?:%s|%s)\s+)*)(%s)\b" % (ATTRIBUTE, MODIFIER, KEYWORDS))
DIRECTIVE = re.compile(r"[ \t]*#(?:if|else|elseif|endif|Preview|warning|error|sourceLocation)\b")
CONTAINERS = {"class", "struct", "enum", "extension", "protocol", "actor"}
ACCESSOR = re.compile(r"\s*(?:@\w+\s+)*(?:mutating\s+|nonmutating\s+)?"
                      r"(get|set|_read|_modify|didSet|willSet|init|unsafeAddress|unsafeMutableAddress)"
                      r"(?:\s*\(\s*\w+\s*\))?(?:\s+async)?(?:\s+throws(?:\s*\([^)]*\))?)?\s*(?=\{|\n|$|get\b|set\b|\})")

class Body:
    def __init__(self, start, end, kind, name, line, replacement, end_line=0):
        self.start, self.end, self.kind, self.name, self.line, self.replacement = start, end, kind, name, line, replacement
        self.end_line = end_line

    def label(self):
        return "%s:%d:%s" % (self.kind, self.line, self.name)

def line_starts(masked, start, end):
    positions, depth, fresh = [], 0, True
    i = start
    while i < end:
        c = masked[i]
        if fresh and depth == 0 and not c.isspace():
            positions.append(i)
            fresh = False
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0 and c == "}":
                fresh = True
        elif c in "\n;" and depth == 0:
            fresh = True
        i += 1
    return positions

def first_brace(masked, start, end):
    depth = 0
    for i in range(start, end):
        c = masked[i]
        if c == "{" and depth == 0:
            return i
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
    return None

def opaque_replacement(header, keyword="var"):
    if keyword in ("func", "subscript"):
        arrow = header.rfind("->")
    else:
        arrow = header.find(":")
    result = header[arrow:] if arrow >= 0 else ""
    if "some " not in result:
        return "fatalError()"
    if re.search(r"some\s+View\b", result):
        return "EmptyView()"
    return None

def name_of(header, keyword):
    m = re.search(r"\b%s\s+([`\w]+)" % keyword, header) if keyword not in ("init", "deinit", "subscript") else None
    return m.group(1) if m else keyword

def accessor_bodies(masked, pairs, open_at, close_at, name, src_line, header, keyword):
    found = []
    for start in line_starts(masked, open_at + 1, close_at):
        m = ACCESSOR.match(masked, start)
        if not m:
            continue
        brace = first_brace(masked, m.end(), close_at)
        if brace is None:
            continue
        replacement = "fatalError()"
        if m.group(1) == "get":
            replacement = opaque_replacement(header, keyword)
        if m.group(1) in ("init", "unsafeAddress", "unsafeMutableAddress") or replacement is None:
            continue
        found.append(Body(brace, pairs[brace], m.group(1), name, src_line(brace), replacement))
    return found

def find_bodies(src):
    masked = mask(src)
    pairs = brace_pairs(masked)
    newlines = [i for i, c in enumerate(src) if c == "\n"]

    def src_line(pos):
        lo, hi = 0, len(newlines)
        while lo < hi:
            mid = (lo + hi) // 2
            if newlines[mid] < pos:
                lo = mid + 1
            else:
                hi = mid
        return lo + 1

    bodies = []

    def walk(start, end):
        starts = []
        for pos in line_starts(masked, start, end):
            line_begin = masked.rfind("\n", 0, pos) + 1
            m = DECL.match(masked, max(line_begin, start))
            if m and m.start(2) >= pos:
                starts.append((pos, m.group(2), m.end(2)))
            elif DIRECTIVE.match(masked, max(line_begin, start)):
                starts.append((pos, "#", pos + 1))
        for index, (pos, keyword, after) in enumerate(starts):
            span_end = starts[index + 1][0] if index + 1 < len(starts) else end
            if keyword == "class":
                following = re.match(r"\s+(\w+)", masked[after:span_end])
                if following and following.group(1) in ("func", "var", "let", "subscript"):
                    continue
            brace = first_brace(masked, after, span_end)
            if brace is None or brace not in pairs:
                continue
            close = pairs[brace]
            header = masked[pos:brace]
            name = name_of(header, keyword)
            if keyword in CONTAINERS:
                walk(brace + 1, close)
            elif keyword in ("func", "init", "deinit"):
                replacement = opaque_replacement(header, keyword) if keyword == "func" else "fatalError()"
                if replacement:
                    bodies.append(Body(brace, close, keyword, name, src_line(brace), replacement))
            elif keyword in ("var", "subscript", "let"):
                stripped = header.rstrip()
                depth, equals = 0, -1
                for k, c in enumerate(header):
                    if c in "([<":
                        depth += 1
                    elif c in ")]>" and depth > 0 and not (c == ">" and header[k - 1] == "-"):
                        depth -= 1
                    elif c == "=" and depth == 0 and header[k + 1:k + 2] != "=" and header[k - 1:k] not in "=!<>":
                        equals = k
                        break
                if equals >= 0:
                    if stripped.endswith("="):
                        continue
                    if ACCESSOR.match(masked, brace + 1):
                        bodies.extend(accessor_bodies(masked, pairs, brace, close, name, src_line, header, keyword))
                    continue
                if keyword == "let":
                    continue
                if ACCESSOR.match(masked, brace + 1):
                    bodies.extend(accessor_bodies(masked, pairs, brace, close, name, src_line, header, keyword))
                    continue
                replacement = opaque_replacement(header, keyword)
                if replacement:
                    bodies.append(Body(brace, close, "get", name, src_line(brace), replacement))

    walk(0, len(src))
    for body in bodies:
        body.end_line = src_line(body.end)
    bodies.sort(key=lambda b: b.start)
    return bodies

def stubbed_inner(src, body):
    return " " + body.replacement + " " + "\n" * src.count("\n", body.start, body.end)

def apply(src, bodies):
    out = src
    for body in sorted(bodies, key=lambda b: -b.start):
        out = out[:body.start + 1] + stubbed_inner(src, body) + out[body.end:]
    return out

def statements(src, body):
    masked = mask(src)
    starts = []
    continuation = re.compile(r"(?:else|catch|where|in)\b|[.)\]}?:+\-*/%&|^<>=!,]")
    for pos in line_starts(masked, body.start + 1, body.end):
        if continuation.match(masked, pos):
            continue
        previous = masked[:pos].rstrip()
        if previous and previous[-1] in "=,(+-*/&|<>?:[" and not previous.endswith("->"):
            continue
        starts.append(pos)
    return starts

def truncate(src, body, cut):
    return src[:cut] + "fatalError()\n" + src[body.end:]

if __name__ == "__main__":
    text = open(sys.argv[1]).read()
    found = find_bodies(text)
    for b in found:
        print("%5d %-8s %-40s %s" % (b.line, b.kind, b.name, b.replacement))
    if len(sys.argv) > 2:
        open(sys.argv[2], "w").write(apply(text, found))
