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

DOCS = Path(__file__).resolve().parent.parent
LINK = re.compile(r"\]\((/[^)\s]*?)(?:\s+\"[^\"]*\")?\)")
SRC = re.compile(r'src=\{?"(/[^"]+)"')
FENCE = re.compile(r"```.*?```", re.S)


def nav_pages(node, out, collecting=False):
    if isinstance(node, dict):
        for key, value in node.items():
            nav_pages(value, out, key == "pages")
    elif isinstance(node, list):
        for value in node:
            nav_pages(value, out, collecting)
    elif collecting and isinstance(node, str) and not node.startswith(("http", "#")):
        out.add(node)


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
        body = FENCE.sub("", path.read_text())
        anchors[slug] = {
            "#" + re.sub(r"[^a-z0-9]+", "-", h.lower()).strip("-")
            for h in re.findall(r"^#{2,4} +(.+?)\s*$", body, re.M)
        }

    for path in sorted(DOCS.rglob("*.mdx")):
        if "node_modules" in path.parts:
            continue
        rel = path.relative_to(DOCS)
        body = FENCE.sub("", path.read_text())
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
                elif anchor and "#" + anchor not in anchors.get(page, set()):
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
