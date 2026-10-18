#!/usr/bin/env python3
# Writes build-aux/debian/copyright and the RPM spec's License tag from
# cargo-about's data/licenses/third-party.json: the license expression each
# crate declares, and the text of the license TablePro uses it under.
# cargo-about templates cannot indent a license text into a deb822 field,
# hence a script.

import argparse
import json
import re
import sys
import textwrap
import xml.etree.ElementTree as ElementTree
from pathlib import Path

DEP5_FORMAT = "https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
UPSTREAM_LICENSE = "AGPL-3.0-or-later"
UPSTREAM_COPYRIGHT = "TablePro Authors"
METAINFO = Path("data/app.tablepro.TablePro.metainfo.xml.in.in")

APACHE_TITLE = re.compile(r"^\s*Apache License\s*$")
APACHE_TERMS = "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"
APACHE_END = "END OF TERMS AND CONDITIONS"
# lintian rejects a copyright file that carries the Apache 2.0 terms, which
# every Debian system has under common-licenses.
APACHE_POINTER = [
    "On Debian systems, the complete text of the Apache License, Version 2.0",
    'can be found in "/usr/share/common-licenses/Apache-2.0".',
]
COMMON_LICENSES = {"CC0-1.0": "CC0 1.0 Universal license"}

NOTICE = re.compile(r"^(?:copyright\b|©|\(c\)\s*\d)", re.IGNORECASE)
NOTICE_PREFIX = re.compile(r"^(?:copyright\b\s*)?(?:\(c\)|©)?\s*", re.IGNORECASE)
NOT_A_NOTICE = re.compile(
    r"\[(?:yyyy|year)\]|\{yyyy\}|<year>"
    r"|^copyright\s+(?:notices?|holders?|owners?|license|and\s+permission|statement)\b"
    r"|:$",
    re.IGNORECASE,
)

# DEP-5 asks for the short name Expat where an MIT text is this one. The
# holders are the part SPDX lets vary.
EXPAT_TERMS = (
    'Permission is hereby granted, free of charge, to any person obtaining a copy of this software '
    'and associated documentation files (the "Software"), to deal in the Software without restriction, '
    "including without limitation the rights to use, copy, modify, merge, publish, distribute, "
    "sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is "
    "furnished to do so, subject to the following conditions: The above copyright notice and this "
    "permission notice shall be included in all copies or substantial portions of the Software. "
    'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING '
    "BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND "
    "NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, "
    "DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, "
    "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."
)
EXPAT = re.compile(
    r"\s+".join(map(re.escape, EXPAT_TERMS.split())).replace(
        r"AUTHORS\s+OR\s+COPYRIGHT\s+HOLDERS", r"[^.]+?"
    ),
    re.IGNORECASE,
)
# The X11 license is the Expat text with this clause added.
X11_CLAUSE = re.compile(r"shall\s+not\s+be\s+used\s+in\s+advertising", re.IGNORECASE)

SPEC_LICENSE = re.compile(r"^License:([ \t]+)(?:%\{shrink:\n(?:[^\n]*\n)*?\}|[^\n]*)$", re.MULTILINE)
EXPRESSION_TOKEN = re.compile(r"\(|\)|[^\s()]+")
LICENSE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+-]*$")


class MetadataError(Exception):
    pass


# An SPDX expression as ("license", id), ("with", id, exception),
# ("and", terms) or ("or", terms).
def parse_expression(text):
    tokens = EXPRESSION_TOKEN.findall(text.replace("/", " OR "))
    position = 0

    def peek():
        return tokens[position] if position < len(tokens) else None

    def take():
        nonlocal position
        token = peek()
        if token is None:
            raise MetadataError(f"the license expression {text!r} ends early")
        position += 1
        return token

    def operand():
        token = take()
        if token == "(":
            node = disjunction()
            if take() != ")":
                raise MetadataError(f"the license expression {text!r} has an unclosed parenthesis")
        elif LICENSE_ID.match(token) and token.upper() not in {"AND", "OR", "WITH"}:
            if token in {"Unknown", "Ignore"}:
                raise MetadataError(f"cargo-about could not read the license expression {text!r}")
            node = ("license", token)
        else:
            raise MetadataError(f"the license expression {text!r} has {token!r} where a license belongs")
        if (peek() or "").upper() == "WITH":
            take()
            if node[0] != "license":
                raise MetadataError(f"the license expression {text!r} applies WITH to an expression")
            exception = take()
            if not LICENSE_ID.match(exception):
                raise MetadataError(f"the license expression {text!r} has {exception!r} where an exception belongs")
            node = ("with", node[1], exception)
        return node

    def chain(operator, part):
        terms = [part()]
        while (peek() or "").upper() == operator:
            take()
            terms.append(part())
        return combine(operator.lower(), terms)

    def conjunction():
        return chain("AND", operand)

    def disjunction():
        return chain("OR", conjunction)

    node = disjunction()
    if peek() is not None:
        raise MetadataError(f"the license expression {text!r} has {peek()!r} after its end")
    return node


# Flat, each operand once and sorted, so "MIT OR Apache-2.0" and
# "Apache-2.0 OR MIT" are one term.
def combine(kind, terms):
    flat = []
    for term in terms:
        for part in term[1] if term[0] == kind else (term,):
            if part not in flat:
                flat.append(part)
    if len(flat) == 1:
        return flat[0]
    return (kind, tuple(sorted(flat, key=sort_key)))


def sort_key(node):
    return spdx(node).replace("(", "").replace(")", "").lower()


def spdx(node, nested=False):
    if node[0] == "license":
        return node[1]
    if node[0] == "with":
        return f"{node[1]} WITH {node[2]}"
    joined = f" {node[0].upper()} ".join(spdx(term, nested=True) for term in node[1])
    return f"({joined})" if nested else joined


def is_expat(text):
    text = text.replace("“", '"').replace("”", '"')
    return bool(EXPAT.search(text)) and not X11_CLAUSE.search(text)


def dep5_id(license_id, expat):
    if license_id == "MIT" and expat:
        return "Expat"
    for suffix, replacement in (("-or-later", "+"), ("-only", "")):
        if license_id.endswith(suffix):
            return license_id.removesuffix(suffix) + replacement
    return license_id


def dep5(node, expat=False):
    if node[0] == "license":
        return dep5_id(node[1], expat)
    if node[0] == "with":
        # DEP-5 writes an exception as "<license> with <name> exception".
        return f"{dep5_id(node[1], expat)} with {node[2].removesuffix('-exception')} exception"
    if node[0] == "or":
        for term in node[1]:
            if term[0] == "and" and any(part[0] == "or" for part in term[1]):
                raise MetadataError(f"DEP-5 cannot write {spdx(node)}")
        return " or ".join(dep5(term, expat) for term in node[1])
    # "and" binds tighter than "or" in DEP-5 unless a comma precedes it.
    separator = ", and " if any(term[0] == "or" for term in node[1]) else " and "
    return separator.join(dep5(term, expat) for term in node[1])


def load(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    return data["licenses"], data["crates"]


def metainfo_license(path):
    found = ElementTree.parse(path).getroot().findtext("metadata_license")
    if not found:
        raise MetadataError(f"{path} has no metadata_license")
    return found.strip()


def crate_texts(licenses, crates):
    texts = {(crate["name"], crate["version"]): [] for crate in crates}
    for index, license in enumerate(licenses):
        for used_by in license["used_by"]:
            key = (used_by["crate"]["name"], used_by["crate"]["version"])
            if key not in texts:
                raise MetadataError(f"{key[0]} {key[1]} has a license text but no license expression")
            if index not in texts[key]:
                texts[key].append(index)
    for (name, version), indices in texts.items():
        if not indices:
            raise MetadataError(f"{name} {version} has a license expression but no license text")
    return texts


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


def common_license_pointer(license_id):
    return [
        f"On Debian systems, the complete text of the {COMMON_LICENSES[license_id]}",
        f'can be found in "/usr/share/common-licenses/{license_id}".',
    ]


def render_copyright(licenses, crates, upstream_text, metadata_license):
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
                "linked into tablepro and tablepro-askpass. Each names every license",
                "the crate offers and holds the text of the one TablePro uses, as the",
                "crate ships it.",
            ],
        ),
        field("Files", ["*"])
        + field("Copyright", [UPSTREAM_COPYRIGHT])
        + field("License", [dep5_id(UPSTREAM_LICENSE, False)] + text_block([upstream_text])),
    ]
    if metadata_license != UPSTREAM_LICENSE:
        if metadata_license not in COMMON_LICENSES:
            raise MetadataError(f"the metainfo is under {metadata_license}, which has no text here")
        paragraphs.append(
            field("Files", [METAINFO.as_posix()])
            + field("Copyright", [UPSTREAM_COPYRIGHT])
            + field("License", [dep5_id(metadata_license, False)] + common_license_pointer(metadata_license))
        )

    expressions = {(crate["name"], crate["version"]): crate["license"] for crate in crates}
    groups = {}
    for crate, indices in crate_texts(licenses, crates).items():
        texts = []
        for index in indices:
            if licenses[index]["text"] not in texts:
                texts.append(licenses[index]["text"])
        mit = [licenses[index]["text"] for index in indices if licenses[index]["id"] == "MIT"]
        expat = bool(mit) and all(is_expat(text) for text in mit)
        synopsis = dep5(parse_expression(expressions[crate]), expat)
        groups.setdefault((synopsis, tuple(texts)), []).append(crate)

    for (synopsis, texts), group in sorted(groups.items(), key=lambda item: sorted(item[1])[0]):
        group = sorted(group)
        paragraphs.append(
            field("Files", [f"vendor/{name}-{version}/*" for name, version in group])
            + field("Copyright", notices(texts) or unnamed_holders(group))
            + field("License", [synopsis] + text_block(texts))
        )

    return "\n\n".join("\n".join(paragraph) for paragraph in paragraphs) + "\n"


def rpm_license(crates, metadata_license):
    upstream = [("license", UPSTREAM_LICENSE)]
    if metadata_license != UPSTREAM_LICENSE:
        upstream.append(("license", metadata_license))
    terms = []
    for crate in crates:
        node = parse_expression(crate["license"])
        for term in node[1] if node[0] == "and" else (node,):
            if term not in upstream and term not in terms:
                terms.append(term)
    return [spdx(term, nested=True) for term in upstream + sorted(terms, key=sort_key)]


def apply_spec_license(spec, terms):
    if len(SPEC_LICENSE.findall(spec)) != 1:
        raise MetadataError("the spec must have exactly one License tag")
    lines = [f"    {term} AND" for term in terms[:-1]] + [f"    {terms[-1]}"]
    block = "%{shrink:\n" + "\n".join(lines) + "\n}"
    return SPEC_LICENSE.sub(lambda match: f"License:{match.group(1)}{block}", spec)


def expected(args):
    licenses, crates = load(args.licenses)
    upstream = Path(args.license_file).read_text(encoding="utf-8")
    # LICENSE sits at the source root, beside data/.
    metadata_license = metainfo_license(Path(args.license_file).parent / METAINFO)
    spec = Path(args.spec).read_text(encoding="utf-8")
    return {
        Path(args.copyright): render_copyright(licenses, crates, upstream, metadata_license),
        Path(args.spec): apply_spec_license(spec, rpm_license(crates, metadata_license)),
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
    except (OSError, KeyError, ValueError, ElementTree.ParseError, MetadataError) as error:
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
