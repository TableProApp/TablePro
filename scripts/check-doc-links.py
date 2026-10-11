#!/usr/bin/env python3
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE = re.compile(r"^\s*(```|~~~)")
GENERATED = re.compile(r"(^|/)target/")


def targets(text):
    in_fence = False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for match in LINK.finditer(line):
            yield match.group(1)


def file_part(target):
    if urlparse(target).scheme or target.startswith("#"):
        return None
    path = unquote(target.split("#", 1)[0].split("?", 1)[0])
    if not path or GENERATED.search(path):
        return None
    return path


def broken_links(root, files):
    found = []
    for source in files:
        for target in targets(source.read_text(encoding="utf-8", errors="replace")):
            path = file_part(target)
            if path is None:
                continue
            resolved = (root / path.lstrip("/")) if path.startswith("/") else (source.parent / path)
            if not resolved.exists():
                found.append((source, path))
    return found


def markdown_files(root):
    skipped = {"target", ".git", "node_modules", "evidence", "vendor"}
    generated = {"packaging/out"}
    files = [
        p
        for p in root.rglob("*.md")
        if not skipped.intersection(p.relative_to(root).parts)
        and "/".join(p.relative_to(root).parts[:2]) not in generated
    ]
    return files + sorted(root.parent.glob("*.md"))


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
