#!/usr/bin/env python3
# Writes build-aux/debian/copyright and the RPM spec's License tag from
# cargo-about's data/licenses/third-party.json. cargo-about templates cannot
# indent a license text into a deb822 field, hence a script.

import argparse
import json
import re
import sys
import textwrap
from pathlib import Path

DEP5_FORMAT = "https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
UPSTREAM_LICENSE = "AGPL-3.0-or-later"
UPSTREAM_COPYRIGHT = "TablePro Authors"

APACHE_TITLE = re.compile(r"^\s*Apache License\s*$")
APACHE_TERMS = "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"
APACHE_END = "END OF TERMS AND CONDITIONS"
# lintian rejects a copyright file that carries the Apache 2.0 terms, which
# every Debian system has under common-licenses.
APACHE_POINTER = [
    "On Debian systems, the complete text of the Apache License, Version 2.0",
    'can be found in "/usr/share/common-licenses/Apache-2.0".',
]

NOTICE = re.compile(r"^(?:copyright\b|©|\(c\)\s*\d)", re.IGNORECASE)
NOTICE_PREFIX = re.compile(r"^(?:copyright\b\s*)?(?:\(c\)|©)?\s*", re.IGNORECASE)
NOT_A_NOTICE = re.compile(
    r"\[(?:yyyy|year)\]|\{yyyy\}|<year>"
    r"|^copyright\s+(?:notices?|holders?|owners?|license|and\s+permission|statement)\b"
    r"|:$",
    re.IGNORECASE,
)

SPEC_LICENSE = re.compile(r"^License:(\s+).*$", re.MULTILINE)


class MetadataError(Exception):
    pass


def load_licenses(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)["licenses"]


def crate_entries(licenses):
    entries = {}
    for index, license in enumerate(licenses):
        for used_by in license["used_by"]:
            crate = used_by["crate"]
            key = (crate["name"], crate["version"])
            if index not in entries.setdefault(key, []):
                entries[key].append(index)
    return entries


def dep5_name(spdx_id):
    # DEP-5 writes an exception as "<license> with <name> exception".
    license_id, separator, exception = spdx_id.partition(" WITH ")
    if not separator:
        return spdx_id
    return f"{license_id} with {exception.removesuffix('-exception')} exception"


def debian_text(text):
    lines = text.split("\n")
    if APACHE_TERMS not in text:
        return lines
    terms = next(i for i, line in enumerate(lines) if APACHE_TERMS in line)
    titles = [i for i in range(terms) if APACHE_TITLE.match(lines[i])]
    ends = [i for i in range(terms, len(lines)) if APACHE_END in lines[i]]
    if not titles or not ends:
        raise MetadataError("an Apache 2.0 text has no title or end line to cut at")
    return lines[: titles[-1]] + APACHE_POINTER + lines[ends[0] + 1 :]


def notices(texts):
    found = []
    for text in texts:
        for line in text.split("\n"):
            line = " ".join(line.split())
            if not NOTICE.match(line) or NOT_A_NOTICE.search(line):
                continue
            notice = NOTICE_PREFIX.sub("", line)
            if notice and notice not in found:
                found.append(notice)
    return found


def unnamed_holders(crates):
    names = ", ".join(dict.fromkeys(name for name, _ in crates))
    return textwrap.wrap(f"the authors of {names}", width=72, break_on_hyphens=False)


def field(name, lines):
    first, *rest = lines
    out = [f"{name}: {first}".rstrip()]
    for line in rest:
        line = line.expandtabs().replace("\f", "").rstrip()
        out.append(f" {line}" if line else " .")
    return out


def text_block(texts):
    lines = []
    for text in texts:
        body = debian_text(text)
        while body and not body[0].strip():
            body.pop(0)
        while body and not body[-1].strip():
            body.pop()
        if lines:
            lines.append("")
        lines.extend(body)
    return lines


def render_copyright(licenses, upstream_text):
    paragraphs = [
        field("Format", [DEP5_FORMAT])
        + field("Upstream-Name", ["TablePro"])
        + field("Upstream-Contact", ["https://github.com/TableProApp/TablePro/issues"])
        + field("Source", ["https://github.com/TableProApp/TablePro"])
        + field(
            "Comment",
            [
                "build-aux/packaging/license_metadata.py writes this file from",
                "data/licenses/third-party.json. The vendor/ paragraphs cover the crates",
                "linked into tablepro and tablepro-askpass, each under the license",
                "TablePro uses it under, with the license text the crate ships.",
            ],
        ),
        field("Files", ["*"])
        + field("Copyright", [UPSTREAM_COPYRIGHT])
        + field("License", [UPSTREAM_LICENSE] + text_block([upstream_text])),
    ]

    groups = {}
    for crate, indices in crate_entries(licenses).items():
        groups.setdefault(tuple(indices), []).append(crate)

    for indices, crates in sorted(groups.items(), key=lambda group: sorted(group[1])[0]):
        crates = sorted(crates)
        texts = []
        for index in indices:
            if licenses[index]["text"] not in texts:
                texts.append(licenses[index]["text"])
        ids = []
        for index in indices:
            name = dep5_name(licenses[index]["id"])
            if name not in ids:
                ids.append(name)
        holders = notices(texts) or unnamed_holders(crates)
        paragraphs.append(
            field("Files", [f"vendor/{name}-{version}/*" for name, version in crates])
            + field("Copyright", holders)
            + field("License", [" and ".join(ids)] + text_block(texts))
        )

    return "\n\n".join("\n".join(paragraph) for paragraph in paragraphs) + "\n"


def rpm_license(licenses):
    third_party = sorted({license["id"] for license in licenses} - {UPSTREAM_LICENSE})
    return " AND ".join([UPSTREAM_LICENSE] + third_party)


def apply_spec_license(spec, expression):
    if len(SPEC_LICENSE.findall(spec)) != 1:
        raise MetadataError("the spec must have exactly one License tag")
    return SPEC_LICENSE.sub(lambda match: f"License:{match.group(1)}{expression}", spec)


def expected(args):
    licenses = load_licenses(args.licenses)
    upstream = Path(args.license_file).read_text(encoding="utf-8")
    spec = Path(args.spec).read_text(encoding="utf-8")
    return {
        Path(args.copyright): render_copyright(licenses, upstream),
        Path(args.spec): apply_spec_license(spec, rpm_license(licenses)),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Write, or check, the package license metadata generated from third-party.json."
    )
    parser.add_argument("command", choices=["write", "check"])
    parser.add_argument("--licenses", required=True)
    parser.add_argument("--license-file", required=True)
    parser.add_argument("--copyright", required=True)
    parser.add_argument("--spec", required=True)
    args = parser.parse_args(argv)

    try:
        outputs = expected(args)
    except (OSError, KeyError, ValueError, MetadataError) as error:
        print(f"license_metadata.py: {error}", file=sys.stderr)
        return 1

    stale = []
    for path, content in outputs.items():
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current == content:
            continue
        if args.command == "write":
            path.write_text(content, encoding="utf-8")
        else:
            stale.append(path)

    for path in stale:
        print(
            f"license_metadata.py: {path} does not match data/licenses; "
            "run build-aux/update-third-party-licenses.sh",
            file=sys.stderr,
        )
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
