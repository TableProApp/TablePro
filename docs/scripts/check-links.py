#!/usr/bin/env python3
"""Resolve every internal link, image and navigation entry in docs/ against the files on disk.

The Mintlify CLI does this too, but it needs a working npm install with native bindings, and it
cannot answer the question that has broken this repo twice: a page that exists but sits in no
navigation group, so nothing ever links to it and the sidebar never shows it.
"""

import json
import re
import sys
from pathlib import Path
from urllib.parse import quote, unquote

DOCS = Path(__file__).resolve().parent.parent
LINK = re.compile(r"\]\((/[^)\s]*?)(?:\s+\"[^\"]*\")?\)")
SRC = re.compile(r'src=\{?"(/[^"]+)"')
FENCE = re.compile(r"```.*?```", re.S)
HEADING = re.compile(r"^#{1,4} +(.+?)\s*$", re.M)
CODE_SPAN = re.compile(r"(`[^`]*`)")
INLINE_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
EMPHASIS = re.compile(r"(\*\*|\*)(.+?)\1")
TAG = re.compile(r"<[^>]+>")


def heading_text(raw):
    """The heading as Mintlify reads it: the text of its nodes, without the markdown around them."""
    text = []
    for part in CODE_SPAN.split(raw):
        if len(part) >= 2 and part.startswith("`") and part.endswith("`"):
            text.append(part[1:-1])
            continue
        part = INLINE_LINK.sub(r"\1", part)
        part = EMPHASIS.sub(r"\2", part)
        text.append(TAG.sub("", part))
    return "".join(text)


def clean_heading_id(anchor):
    """Both sides of an anchor comparison, normalised the way `mint broken-links` does it.

    Mirrors `cleanHeadingId` in @mintlify/common: percent-decode, then drop the punctuation the
    rendered page leaves out of its ids. So `#pl%2Fsql` and the heading "PL/SQL" both become
    `pl/sql`, and a lone `%` is taken literally rather than rejected.
    """
    escaped = re.sub(r"%(?![0-9A-Fa-f]{2})", "%25", anchor)
    try:
        decoded = unquote(escaped, errors="strict")
    except UnicodeDecodeError:
        return anchor
    return re.sub(r"""[?,;:!'"()\[\]{}]""", "", decoded)


def heading_slug(title):
    """The slug Mintlify gives a heading, before `clean_heading_id`.

    Mirrors `slugify` in @mintlify/common over @sindresorhus/slugify. A title is lowercased, its
    whitespace becomes `-` and it is percent-encoded. When encoding escaped anything, the escapes
    are kept, so "PL/SQL" is `pl%2Fsql`, not the `pl-sql` a plain alphanumeric slug would give.
    """
    unicode_id = quote(re.sub(r"\s+", "-", title.lower().strip()), safe="-_.!~*'()")
    kept = "a-zA-Z0-9%_" if re.search(r"%[0-9A-F]{2}", unicode_id) else "a-z0-9_"
    slug = re.sub(f"[^{kept}]+", "-", unicode_id)
    slug = re.sub(r"([a-zA-Z\d]+)-([ts])(-|$)", r"\1\2\3", slug)
    return re.sub(r"-{2,}", "-", slug).strip("-")


def page_anchors(body):
    seen = {}
    anchors = set()
    for raw in HEADING.findall(body):
        slug = heading_slug(heading_text(raw))
        if not slug:
            continue
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        if count:
            suffix = count + 1
            while f"{slug}-{suffix}" in seen:
                suffix += 1
            slug = f"{slug}-{suffix}"
            seen[slug] = 1
        anchors.add(clean_heading_id(slug))
    return anchors


def nav_pages(node, out, collecting=False):
    if isinstance(node, dict):
        for key, value in node.items():
            nav_pages(value, out, key == "pages")
    elif isinstance(node, list):
        for value in node:
            nav_pages(value, out, collecting)
    elif collecting and isinstance(node, str) and not node.startswith(("http", "#")):
        out.add(node)


IMPORT = re.compile(r'^import\s+(\w+)\s+from\s+"(/snippets/[^"]+)"', re.M)


def check_snippets(path, raw, failures):
    """A snippet has to be the only thing on its line.

    A snippet is block content: several sentences, sometimes a table, sometimes a markdown link
    that wraps. Mintlify renders it as a block, and any prose sharing the line with it returns
    HTTP 500 in production while `mint validate` and the Mintlify deploy both report success.

    An earlier version of this check only rejected text that carried the SAME sentence past the
    snippet, on the premise that "starting a new sentence after one on the same line renders fine".
    That premise was wrong. `features/table-structure.mdx` was edited to start a new sentence and
    kept returning 500, and six other pages were down for the same reason: four with a new sentence
    after the snippet, one with a markdown link after it, and `features/plugins.mdx` with prose
    BEFORE it, which the old check never looked at. All 24 pages that render put the snippet alone
    on its line; all 7 that returned 500 did not.
    """
    rel = path.relative_to(DOCS)
    declared = {}
    for name, source in IMPORT.findall(raw):
        declared[name] = source
        if not (DOCS / source.lstrip("/")).exists():
            failures.append(f"{rel} imports {source}, which is not in docs/snippets")
    if not declared:
        return

    used = "|".join(re.escape(n) for n in declared)
    in_fence = False
    for line_no, line in enumerate(raw.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for match in re.finditer(rf"<({used})\b[^>]*/>", line):
            before = line[: match.start()].strip()
            after = line[match.end() :].strip()
            if not before and not after:
                continue
            where = "before and after" if before and after else ("before" if before else "after")
            failures.append(
                f"{rel}:{line_no} puts prose {where} <{match.group(1)} /> on the same line; "
                f"a snippet is block content and returns HTTP 500 unless it is alone on its line"
            )


def main() -> int:
    config = json.loads((DOCS / "docs.json").read_text())
    pages = set()
    nav_pages(config["navigation"], pages)
    redirects = {r["source"]: r["destination"] for r in config.get("redirects", [])}

    on_disk = {
        str(p.relative_to(DOCS).with_suffix(""))
        for p in DOCS.rglob("*.mdx")
        if "snippets" not in p.parts and "node_modules" not in p.parts
    }

    failures = []
    for page in sorted(pages - on_disk):
        failures.append(f"docs.json lists {page}, which has no .mdx file")
    for page in sorted(on_disk - pages):
        failures.append(f"{page}.mdx is in no navigation group")

    anchors = {}
    for path in DOCS.rglob("*.mdx"):
        if "node_modules" in path.parts:
            continue
        slug = "/" + str(path.relative_to(DOCS).with_suffix(""))
        anchors[slug] = page_anchors(FENCE.sub("", path.read_text()))

    for path in sorted(DOCS.rglob("*.mdx")):
        if "node_modules" in path.parts:
            continue
        rel = path.relative_to(DOCS)
        body = FENCE.sub("", path.read_text())
        check_snippets(path, body, failures)
        for line_no, line in enumerate(body.splitlines(), 1):
            for target in LINK.findall(line):
                page, _, anchor = target.partition("#")
                page = page.rstrip("/") or "/"
                if page in redirects:
                    page = redirects[page]
                if page == "/":
                    continue
                bare = page.lstrip("/")
                if bare not in on_disk and f"{bare}/index" in on_disk:
                    page = f"/{bare}/index"
                    bare = page.lstrip("/")
                if bare not in on_disk:
                    failures.append(f"{rel}:{line_no} links to {target}, which does not resolve")
                elif anchor and clean_heading_id(anchor) not in anchors.get(page, set()):
                    failures.append(f"{rel}:{line_no} links to {target}, but that heading does not exist")
            for asset in SRC.findall(line):
                if not (DOCS / asset.lstrip("/")).exists():
                    failures.append(f"{rel}:{line_no} references {asset}, which is not in docs/")

    if failures:
        for failure in failures:
            print("  FAIL", failure)
        print(f"\n{len(failures)} unresolved references.")
        return 1
    print(f"  ok  {len(pages)} navigation entries, {len(on_disk)} pages, every link resolves")
    return 0


if __name__ == "__main__":
    sys.exit(main())
