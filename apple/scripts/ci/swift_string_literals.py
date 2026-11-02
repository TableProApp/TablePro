"""The string literals of a Swift source, for the scripts/ci checks that read the SQL the apps write."""


def string_literals(source, interpolation_text=" "):
    """Yield (line, text, before) for each string literal outside comments.

    An interpolation reads as `interpolation_text` in its literal's text; its own literals are yielded on their own.
    `before` is the source just ahead of the literal, for a check to tell what the literal is passed to.
    """
    i = 0
    line = 1
    length = len(source)
    while i < length:
        char = source[i]
        if char == "\n":
            line += 1
            i += 1
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = length if end == -1 else end
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            end = length if end == -1 else end + 2
            line += source.count("\n", i, end)
            i = end
        elif char == '"' or (char == "#" and source.startswith('#"', i)):
            hashes = 0
            while source.startswith("#", i + hashes):
                hashes += 1
            start = i + hashes
            multiline = source.startswith('"""', start)
            opener = '"""' if multiline else '"'
            closer = opener + "#" * hashes
            body_start = start + len(opener)
            before = source[max(0, i - 60):i]
            interpolation = "\\" + "#" * hashes + "("
            pieces = []
            j = body_start
            while j < length and not source.startswith(closer, j):
                if source.startswith(interpolation, j):
                    end = matching_paren(source, j + len(interpolation))
                    # An interpolation is Swift code: its own literals are checked on their own.
                    for inner_line, inner_text, inner_before in string_literals(source[j:end], interpolation_text):
                        yield line + source.count("\n", i, j) + inner_line - 1, inner_text, inner_before
                    pieces.append(interpolation_text)
                    j = end
                    continue
                if source[j] == "\\":
                    pieces.append(source[j:j + 2])
                    j += 2
                    continue
                if not multiline and source[j] == "\n":
                    break
                pieces.append(source[j])
                j += 1
            yield line, "".join(pieces), before
            line += source.count("\n", i, j)
            i = j + len(closer)
        else:
            i += 1


def matching_paren(source, start):
    """The index just past the parenthesis that closes the one opened before `start`."""
    depth = 1
    j = start
    while j < len(source) and depth:
        char = source[j]
        if char == '"':
            j += 1
            while j < len(source) and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        j += 1
    return j
