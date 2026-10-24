#!/usr/bin/env python3
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse

FENCE = re.compile(r"^\s*(```|~~~)")
GENERATED = re.compile(r"(^|/)target/")


class AnchorParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.anchors = set()

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.anchors.update(value for name, value in attrs if name == "id" and value)


def targets(text):
    in_fence = False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        offset = 0
        while (opening := line.find("[", offset)) >= 0:
            if opening and line[opening - 1] == "!":
                offset = opening + 1
                continue
            depth = 0
            cursor = opening
            while cursor < len(line):
                if line[cursor] == "\\":
                    cursor += 2
                    continue
                if line[cursor] == "[":
                    depth += 1
                elif line[cursor] == "]":
                    depth -= 1
                    if depth == 0:
                        break
                cursor += 1
            if depth or cursor + 1 >= len(line) or line[cursor + 1] != "(":
                offset = opening + 1
                continue
            end = line.find(")", cursor + 2)
            if end < 0:
                offset = opening + 1
                continue
            destination = line[cursor + 2:end].split(maxsplit=1)
            if destination:
                yield destination[0]
            offset = end + 1


def file_part(target):
    if urlparse(target).scheme or target.startswith("#"):
        return None
    path = unquote(target.split("#", 1)[0].split("?", 1)[0])
    if not path or GENERATED.search(path):
        return None
    return path


def fragment_part(target):
    if urlparse(target).scheme:
        return None
    fragment = target.partition("#")[2]
    return unquote(fragment.split("?", 1)[0]) if fragment else None


def markdown_anchors(path):
    anchors = set()
    counts = {}
    parser = AnchorParser()
    in_fence = False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        parser.feed(line)
        text = line.lstrip()
        if len(line) - len(text) > 3:
            continue
        level = len(text) - len(text.lstrip("#"))
        if not 1 <= level <= 6 or level == len(text) or not text[level].isspace():
            continue
        title = text[level:].strip()
        while title.endswith("#"):
            title = title[:-1].rstrip()
        if not title:
            continue
        title = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", title)
        title = re.sub(r"<[^>]*>|[`*~]", "", title).lower()
        slug = "".join(char for char in title if char.isalnum() or char.isspace() or char in "-_")
        slug = re.sub(r"\s+", "-", slug).strip("-")
        duplicate = counts.get(slug, 0)
        counts[slug] = duplicate + 1
        anchors.add(slug if duplicate == 0 else f"{slug}-{duplicate}")
    anchors.update(parser.anchors)
    return anchors


def broken_links(root, files):
    found = []
    anchor_cache = {}
    for source in files:
        for target in targets(source.read_text(encoding="utf-8", errors="replace")):
            path = file_part(target)
            fragment = fragment_part(target)
            if path is None:
                if target.startswith("#") and fragment:
                    anchors = anchor_cache.get(source)
                    if anchors is None:
                        anchors = markdown_anchors(source)
                        anchor_cache[source] = anchors
                    if fragment not in anchors:
                        found.append((source, target))
                continue
            resolved = (root / path.lstrip("/")) if path.startswith("/") else (source.parent / path)
            if not resolved.exists():
                found.append((source, path))
                continue
            if fragment and resolved.suffix.lower() == ".md":
                anchors = anchor_cache.get(resolved)
                if anchors is None:
                    anchors = markdown_anchors(resolved)
                    anchor_cache[resolved] = anchors
                if fragment not in anchors:
                    found.append((source, target))
    return found


def markdown_files(root):
    skipped = {"target", ".git", ".cargo", ".rustup", ".flatpak-builder", "node_modules", "evidence", "vendor"}
    generated = "apps/linux/packaging/out/"
    files = [
        p
        for p in root.rglob("*.md")
        if not skipped.intersection(p.relative_to(root).parts)
        and not p.relative_to(root).as_posix().startswith(generated)
    ]
    return files


def main():
    root = Path(__file__).resolve().parents[1]
    problems = broken_links(root, markdown_files(root))
    for source, target in sorted(problems):
        print(f"{source.relative_to(root)}: broken link {target}", file=sys.stderr)
    if problems:
        print(f"doc links: {len(problems)} broken", file=sys.stderr)
        return 1
    print("doc links: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
