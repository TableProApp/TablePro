#!/usr/bin/env python3
# Writes data/licenses/NOTICE from the NOTICE files of the crates
# third-party.json lists. The Apache License 2.0 asks for a work's NOTICE
# to ship with what is built from it, and cargo-about reads license files
# only.

import argparse
import json
import sys
import textwrap
from pathlib import Path

NAMES = ("NOTICE", "NOTICE.txt", "NOTICE.md")
HEADER = """\
The NOTICE files of the crates linked into TablePro, as the Apache License
2.0 asks. build-aux/update-third-party-licenses.sh writes this file.
"""


class NoticeError(Exception):
    pass


def crate_directories(metadata):
    return {
        (package["name"], package["version"]): Path(package["manifest_path"]).parent
        for package in metadata["packages"]
    }


def collect(crates, directories):
    notices = {}
    for crate in crates:
        key = (crate["name"], crate["version"])
        if key not in directories:
            raise NoticeError(f"cargo metadata has no {key[0]} {key[1]}")
        for name in NAMES:
            path = directories[key] / name
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8").strip("\n")
            if text.strip():
                notices.setdefault(text, []).append(f"{key[0]} {key[1]}")
    return notices


def render(notices):
    sections = [HEADER]
    for text, crates in sorted(notices.items(), key=lambda item: item[1][0]):
        used_by = textwrap.wrap("Used by: " + ", ".join(crates), width=72, break_on_hyphens=False)
        sections.append("\n".join(used_by) + "\n\n" + text + "\n")
    return "\n".join(sections)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Write the NOTICE files of the linked crates to one file.")
    parser.add_argument("--licenses", required=True)
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)

    try:
        crates = json.loads(Path(args.licenses).read_text(encoding="utf-8"))["crates"]
        metadata = json.loads(Path(args.metadata).read_text(encoding="utf-8"))
        text = render(collect(crates, crate_directories(metadata)))
    except (OSError, KeyError, ValueError, NoticeError) as error:
        print(f"crate_notices.py: {error}", file=sys.stderr)
        return 1

    Path(args.output).write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
