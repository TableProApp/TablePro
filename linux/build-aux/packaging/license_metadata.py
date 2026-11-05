#!/usr/bin/env python3
# Writes build-aux/debian/copyright and the RPM spec's License tag and
# bundled Provides. The copyright file describes the source package: every
# file of both release tarballs, from source_inventory.py. The spec
# describes the binary package: the License tag comes from cargo-about's
# data/licenses/third-party.json, the crates linked into the binaries, and
# the Provides from the native libraries build-aux/about/bundled lists.

import argparse
import json
import re
import sys
import tomllib
import xml.etree.ElementTree as ElementTree
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import source_inventory  # noqa: E402

DEP5_FORMAT = "https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
UPSTREAM_LICENSE = "AGPL-3.0-or-later"
UPSTREAM_COPYRIGHT = "TablePro Authors"
METAINFO = Path("data/app.tablepro.TablePro.metainfo.xml.in.in")
# The source package unpacks the repository's layout, with the app in linux/.
SOURCE_METAINFO = Path("linux") / METAINFO

APACHE_TITLE = re.compile(r"^\s*Apache License\s*$")
APACHE_TERMS = "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"
APACHE_END = "END OF TERMS AND CONDITIONS"
# lintian rejects a copyright file that carries the Apache 2.0 terms, which
# every Debian system has under common-licenses.
APACHE_POINTER = [
    "On Debian systems, the complete text of the Apache License, Version 2.0",
    'can be found in "/usr/share/common-licenses/Apache-2.0".',
]
# The same holds for the GNU licenses, whose FSF address in the GPL 2 and
# LGPL 2.1 lintian also reports as out of date. The cut runs to the end of
# the appendix, which carries the address too: title, version line, last
# line, common-licenses file and name.
GNU_TEXTS = [
    (
        re.compile(r"^\s*GNU GENERAL PUBLIC LICENSE\s*$"),
        re.compile(r"^\s*Version 2, June 1991\s*$"),
        "Public License instead of this License.",
        "GPL-2",
        ["GNU General Public License", "version 2"],
    ),
    (
        re.compile(r"^\s*GNU GENERAL PUBLIC LICENSE\s*$"),
        re.compile(r"^\s*Version 3, 29 June 2007\s*$"),
        "why-not-lgpl.html>.",
        "GPL-3",
        ["GNU General Public License", "version 3"],
    ),
    (
        re.compile(r"^\s*GNU LESSER GENERAL PUBLIC LICENSE\s*$"),
        re.compile(r"^\s*Version 2\.1, February 1999\s*$"),
        "That's all there is to it!",
        "LGPL-2.1",
        ["GNU Lesser General Public License", "version 2.1"],
    ),
]
# The license texts every Debian system has in /usr/share/common-licenses,
# by DEP-5 short name without its "+".
COMMON_LICENSES = {
    "Apache-2.0": "Apache License, Version 2.0",
    "CC0-1.0": "CC0 1.0 Universal license",
    "GFDL-1.2": "GNU Free Documentation License version 1.2",
    "GFDL-1.3": "GNU Free Documentation License version 1.3",
    "GPL-2": "GNU General Public License version 2",
    "GPL-3": "GNU General Public License version 3",
    "LGPL-2": "GNU Library General Public License version 2",
    "LGPL-2.1": "GNU Lesser General Public License version 2.1",
    "LGPL-3": "GNU Lesser General Public License version 3",
    "MPL-2.0": "Mozilla Public License, Version 2.0",
}
# DEP-5 names the GNU licenses by their major version, "GPL-2+" for SPDX's
# GPL-2.0-or-later, and LGPL-2.1 by its own.
GNU_LICENSE = re.compile(r"^(A?GPL|LGPL|GFDL)-(\d+)\.(\d+)(-only|-or-later|\+)?$")

NOTICE = re.compile(r"^(?:copyright\b|©|\(c\)\s*\d)", re.IGNORECASE)
NOTICE_PREFIX = re.compile(r"^(?:copyright\b\s*:?\s*)?(?:\(c\)|©)?\s*", re.IGNORECASE)
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
PROVIDES_COMMENT = "# build-aux/update-third-party-licenses.sh writes these from build-aux/about/bundled."
# RPM adds bundled(crate(...)) itself from %cargo_vendor_manifest.
SPEC_PROVIDES = re.compile("^" + re.escape(PROVIDES_COMMENT) + r"\n(?:Provides:[ \t]+bundled\([^\n]*\n)*", re.MULTILINE)
VENDOR_CRATE = re.compile(r"^vendor/([^/]+)/\*$")
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
    gnu = GNU_LICENSE.match(license_id)
    if gnu:
        family, major, minor, suffix = gnu.groups()
        version = major if minor == "0" else f"{major}.{minor}"
        return f"{family}-{version}{'+' if suffix in ('-or-later', '+') else ''}"
    for suffix, replacement in (("-or-later", "+"), ("-only", "")):
        if license_id.endswith(suffix):
            return license_id.removesuffix(suffix) + replacement
    return license_id


def dep5(node, expat=False):
    if node[0] == "license":
        return dep5_id(node[1], expat)
    if node[0] == "with":
        # DEP-5 writes an exception as "<license> with <name> exception".
        return f"{dep5_id(node[1], expat)} with {node[2].replace('-exception', '')} exception"
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


def debian_text(text):
    lines = without_apache(text.split("\n"))
    for gnu in GNU_TEXTS:
        lines = without_gnu(lines, gnu)
    return lines


def without_apache(lines):
    # Some crates ship the terms as Markdown, with headings in mixed case.
    terms = next((i for i, line in enumerate(lines) if APACHE_TERMS in line.upper()), None)
    if terms is None:
        return lines
    titles = [i for i in range(terms) if APACHE_TITLE.match(lines[i])]
    ends = [i for i in range(terms, len(lines)) if APACHE_END in lines[i].upper()]
    if not ends:
        raise MetadataError("an Apache 2.0 text has no end line to cut at")
    return lines[: titles[-1] if titles else terms] + APACHE_POINTER + lines[ends[0] + 1 :]


def without_gnu(lines, gnu):
    title, version, last, common, (name, numbered) = gnu
    content = [i for i, line in enumerate(lines) if line.strip()]
    start = next(
        (i for i, n in zip(content, content[1:]) if title.match(lines[i]) and version.match(lines[n])),
        None,
    )
    if start is None:
        return lines
    end = next((i for i in range(start, len(lines)) if last in lines[i]), None)
    if end is None:
        raise MetadataError(f"a {common} text has no last line to cut at")
    pointer = [
        f"On Debian systems, the complete text of the {name}",
        f'{numbered} can be found in "/usr/share/common-licenses/{common}".',
    ]
    return lines[:start] + pointer + lines[end + 1 :]


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


def common_license_pointer(short_name):
    base = short_name.removesuffix("+")
    return [
        f"On Debian systems, the complete text of the {COMMON_LICENSES[base]}",
        f'can be found in "/usr/share/common-licenses/{base}".',
    ]


def license_ids(node):
    if node[0] == "license":
        return [node[1]]
    if node[0] == "with":
        raise MetadataError(f"{spdx(node)} has no text to point at; ship the file that carries it")
    return [found for term in node[1] for found in license_ids(term)]


def unit_expat(texts):
    # With no text of its own, an MIT unit points at the Expat paragraph.
    if not texts:
        return True
    return any(is_expat(text) for text in texts) and not any(X11_CLAUSE.search(text) for text in texts)


def unit_holders(unit, texts):
    # The cut license texts hold the FSF's notice, not a holder's.
    found = list(dict.fromkeys(list(unit.get("copyright", [])) + notices(["\n".join(debian_text(t)) for t in texts])))
    if found:
        return found
    if unit.get("authors"):
        return unit["authors"]
    raise MetadataError(f"{', '.join(unit['files'])} names no copyright holder; add one to build-aux/about/source.json")


def files_paragraph(files, holders, synopsis, texts):
    return field("Files", files) + field("Copyright", holders) + field("License", [synopsis] + text_block(texts))


def standalone_paragraph(short_name, license_id, texts_root):
    if short_name.removesuffix("+") in COMMON_LICENSES:
        return field("License", [short_name] + common_license_pointer(short_name))
    path = Path(texts_root) / f"{license_id}.txt"
    if not path.is_file():
        raise MetadataError(f"no text for {short_name}, which a file without a license file of its own is under; add {path}")
    return field("License", [short_name] + text_block([path.read_text(encoding="utf-8")]))


def render_copyright(dist, crates, nested, upstream_text, metadata_license, texts_root):
    paragraphs = [
        field("Format", [DEP5_FORMAT])
        + field("Upstream-Name", ["TablePro"])
        + field("Upstream-Contact", ["https://github.com/TableProApp/TablePro/issues"])
        + field("Source", ["https://github.com/TableProApp/TablePro"])
        + field(
            "Comment",
            [
                "linux/build-aux/packaging/license_metadata.py writes this file. The",
                "vendor/ paragraphs cover every crate of the vendor component tarball,",
                "which holds all of Cargo.lock, whatever the target or dependency kind,",
                "with the license files each crate ships. The code a crate carries from",
                "another project follows, from linux/build-aux/about/source.json and",
                "linux/build-aux/about/bundled.",
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
            field("Files", [SOURCE_METAINFO.as_posix()])
            + field("Copyright", [UPSTREAM_COPYRIGHT])
            + field("License", [dep5_id(metadata_license, False)] + common_license_pointer(metadata_license))
        )

    standalone = {}

    def described(unit):
        texts = list(dict.fromkeys(unit["texts"]))
        node = parse_expression(unit["expression"])
        expat = unit_expat(texts)
        if not texts:
            for license_id in license_ids(node):
                standalone.setdefault(dep5_id(license_id, expat), license_id)
        return dep5(node, expat), tuple(texts), tuple(unit_holders(unit, texts))

    for unit in dist:
        synopsis, texts, holders = described(unit)
        paragraphs.append(files_paragraph(unit["files"], holders, synopsis, texts))

    groups = {}
    for unit in crates:
        groups.setdefault(described(unit), []).extend(unit["files"])
    for (synopsis, texts, holders), files in sorted(groups.items(), key=lambda item: sorted(item[1])[0]):
        paragraphs.append(files_paragraph(sorted(files), holders, synopsis, texts))

    for unit in nested:
        synopsis, texts, holders = described(unit)
        paragraphs.append(files_paragraph(unit["files"], holders, synopsis, texts))

    for short_name, license_id in sorted(standalone.items(), key=lambda item: item[0].lower()):
        paragraphs.append(standalone_paragraph(short_name, license_id, texts_root))

    return "\n\n".join("\n".join(paragraph) for paragraph in paragraphs) + "\n"


def covered_crates(copyright_text):
    found = set()
    for block in copyright_text.split("\n\n"):
        lines = block.split("\n")
        if not lines[0].startswith("Files: "):
            continue
        patterns = [lines[0].removeprefix("Files: ")]
        for line in lines[1:]:
            if not line.startswith(" "):
                break
            patterns.append(line.strip())
        for pattern in patterns:
            crate = VENDOR_CRATE.match(pattern)
            if crate:
                found.add(crate.group(1))
    return found


def check_coverage(copyright_text, lock_text):
    locked = {f"{name}-{version}" for name, version in source_inventory.lock_packages(lock_text)}
    covered = covered_crates(copyright_text)
    problems = []
    missing = sorted(locked - covered)
    if missing:
        problems.append(f"no vendor/ paragraph for these crates of Cargo.lock: {', '.join(missing)}")
    stale = sorted(covered - locked)
    if stale:
        problems.append(f"vendor/ paragraphs for crates Cargo.lock no longer has: {', '.join(stale)}")
    return problems


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


def rpm_provides(crates, bundles):
    linked = {(crate["name"], crate["version"]) for crate in crates}
    provides = []
    for (name, version), bundle in sorted(bundles.items()):
        if (name, version) not in linked:
            raise MetadataError(f"build-aux/about/bundled/{name} is for {name} {version}, which the binaries do not link")
        for component in bundle["components"]:
            if "provides" not in component:
                continue
            provide = f"bundled({component['provides']})"
            if "version" in component:
                provide += f" = {component['version']}"
            if provide not in provides:
                provides.append(provide)
    return provides


def apply_spec_provides(spec, provides):
    if len(SPEC_PROVIDES.findall(spec)) != 1:
        raise MetadataError("the spec must have exactly one block of bundled() Provides")
    block = PROVIDES_COMMENT + "\n" + "".join(f"Provides:       {provide}\n" for provide in provides)
    return SPEC_PROVIDES.sub(lambda match: block, spec)


def clarified_expressions(about_path):
    with open(about_path, "rb") as handle:
        about = tomllib.load(handle)
    return {
        name: table["clarify"]["license"]
        for name, table in about.items()
        if isinstance(table, dict) and "license" in table.get("clarify", {})
    }


def spec_outputs(args, metadata_license):
    _, crates = load(args.licenses)
    bundles = source_inventory.load_bundles(args.bundled)
    spec = Path(args.spec).read_text(encoding="utf-8")
    spec = apply_spec_license(spec, rpm_license(crates, metadata_license))
    return apply_spec_provides(spec, rpm_provides(crates, bundles))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Write, or check, the package license metadata: the Debian copyright file and the RPM spec."
    )
    parser.add_argument("command", choices=["write", "check"])
    parser.add_argument("--licenses", required=True, help="cargo-about's third-party.json, the linked crates")
    parser.add_argument("--license-file", required=True)
    parser.add_argument("--copyright", required=True)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--lock", required=True, help="the workspace's Cargo.lock, which cargo vendor copies")
    parser.add_argument("--bundled", required=True, help="build-aux/about/bundled")
    parser.add_argument("--metadata", help="cargo metadata of the workspace, for write")
    parser.add_argument("--about", help="about.toml, whose clarify entries correct a crate's expression, for write")
    parser.add_argument("--source", help="build-aux/about/source.json, for write")
    parser.add_argument("--texts", help="build-aux/about/licenses, for write")
    args = parser.parse_args(argv)
    if args.command == "write" and not all((args.metadata, args.about, args.source, args.texts)):
        parser.error("write needs --metadata, --about, --source and --texts")

    try:
        # LICENSE sits at the source root, beside data/.
        source_root = Path(args.license_file).resolve().parent.parent
        metadata_license = metainfo_license(Path(args.license_file).parent / METAINFO)
        outputs = {Path(args.spec): spec_outputs(args, metadata_license)}
        if args.command == "write":
            metadata = json.loads(Path(args.metadata).read_text(encoding="utf-8"))
            dist, crates, nested = source_inventory.inventory(
                metadata,
                clarified_expressions(args.about),
                args.source,
                args.bundled,
                source_root,
            )
            upstream = Path(args.license_file).read_text(encoding="utf-8")
            outputs[Path(args.copyright)] = render_copyright(
                dist, crates, nested, upstream, metadata_license, args.texts
            )
            problems = []
        else:
            problems = check_coverage(
                Path(args.copyright).read_text(encoding="utf-8"), Path(args.lock).read_text(encoding="utf-8")
            )
    except (
        OSError,
        KeyError,
        ValueError,
        ElementTree.ParseError,
        MetadataError,
        source_inventory.InventoryError,
    ) as error:
        print(f"license_metadata.py: {error}", file=sys.stderr)
        return 1

    for path, content in outputs.items():
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current == content:
            continue
        if args.command == "write":
            path.write_text(content, encoding="utf-8")
        else:
            problems.append(f"{path} does not match data/licenses")

    for problem in problems:
        print(f"license_metadata.py: {problem}; run build-aux/update-third-party-licenses.sh", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
