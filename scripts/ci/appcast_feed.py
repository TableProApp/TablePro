"""Text-level primitives for editing the published Sparkle feed.

Two scripts change appcast.xml: merge-appcast.py adds a release's items, pull-release.py removes
them again when a build has to be withdrawn. They have to agree on where an item starts and ends,
so that lives here rather than in both.

Everything works on the file's text, because a full ElementTree round trip destroys every CDATA
section. Measured on the published 695 KB feed: the round trip takes 7 ms, keeps the sparkle prefix
exactly and is semantically identical, but entity-escapes all 155 release-note blocks and grows the
file 9%, which every install then downloads and every future diff then buries. (The older claim here
that a round trip rewrites namespace prefixes was wrong; `register_namespace` preserves them.) So
items that are not being touched are moved byte for byte and only parsed to be understood.
"""

import pathlib
import xml.etree.ElementTree as ElementTree

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SHORT_VERSION = f"{{{SPARKLE_NS}}}shortVersionString"
BUNDLE_VERSION = f"{{{SPARKLE_NS}}}version"
HARDWARE = f"{{{SPARKLE_NS}}}hardwareRequirements"
DELTAS = f"{{{SPARKLE_NS}}}deltas"
ED_SIGNATURE = f"{{{SPARKLE_NS}}}edSignature"


class FeedError(Exception):
    """A violated invariant. Every one of these fails the job that raised it."""


def parse_text(text):
    try:
        return ElementTree.fromstring(text)
    except ElementTree.ParseError as error:
        raise FeedError(f"not well-formed XML: {error}") from error


def parse(path):
    try:
        return ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError) as error:
        raise FeedError(f"{path}: {error}") from error


def read(path):
    try:
        return pathlib.Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise FeedError(f"{path}: {error}") from error


def channel_items(root, path):
    channel = root.find("channel")
    if channel is None:
        raise FeedError(f"{path}: no <channel> element")
    return channel.findall("item")


def item_short_version(item):
    element = item.find(SHORT_VERSION)
    return None if element is None else (element.text or "").strip()


def item_bundle_version(item):
    element = item.find(BUNDLE_VERSION)
    return None if element is None else (element.text or "").strip()


def item_enclosures(item):
    enclosures = list(item.findall("enclosure"))
    deltas = item.find(DELTAS)
    if deltas is not None:
        enclosures.extend(deltas.findall("enclosure"))
    return enclosures


SKIPPABLE = (("<![CDATA[", "]]>", "CDATA section"), ("<!--", "-->", "comment"))
ITEM_OPEN = "<item"
ITEM_CLOSE = "</item>"
TAG_DELIMITERS = frozenset(">/ \t\r\n")


def skip_region(text, index):
    """The offset just past a CDATA section or comment starting at `index`, else None."""
    for opener, closer, label in SKIPPABLE:
        if text.startswith(opener, index):
            end = text.find(closer, index + len(opener))
            if end == -1:
                raise FeedError(f"unterminated {label} in the feed")
            return end + len(closer)
    return None


def opens_item(text, index):
    """True only for a real `<item>` tag. `<itemCount>` starts with the same five characters."""
    if not text.startswith(ITEM_OPEN, index):
        return False
    after = index + len(ITEM_OPEN)
    return after >= len(text) or text[after] in TAG_DELIMITERS


def item_spans(text):
    """Whole-line (start, end) offsets of every <item> in document order.

    Release-note CDATA can hold either literal tag, and so can an XML comment, so both are skipped
    whole rather than matching tags pairwise across the document. An item never nests inside another
    item, so the first `</item>` outside a skipped region closes it. Every marker begins with `<`,
    so the scan hops between those rather than walking characters.
    """
    spans = []
    index = 0
    length = len(text)
    while index < length:
        index = text.find("<", index)
        if index == -1:
            break
        skip = skip_region(text, index)
        if skip is not None:
            index = skip
            continue
        if not opens_item(text, index):
            index += 1
            continue

        open_at = index
        cursor = open_at + len(ITEM_OPEN)
        close_at = -1
        while cursor < length:
            cursor = text.find("<", cursor)
            if cursor == -1:
                break
            skip = skip_region(text, cursor)
            if skip is not None:
                cursor = skip
                continue
            if text.startswith(ITEM_CLOSE, cursor):
                close_at = cursor
                break
            cursor += 1
        if close_at == -1:
            raise FeedError("an <item> is never closed in the feed")

        line_start = text.rfind("\n", 0, open_at) + 1
        line_end = text.find("\n", close_at)
        line_end = length if line_end == -1 else line_end + 1
        spans.append((line_start, line_end))
        index = close_at + len(ITEM_CLOSE)
    return spans


def sole_item_text(path, version):
    """The one item's own bytes, whole lines, taken from a generated single-item feed."""
    text = read(path)
    spans = item_spans(text)
    if len(spans) != 1:
        raise FeedError(f"{path}: expected exactly one <item>, found {len(spans)}")
    start, end = spans[0]
    block = text[start:end]
    return block if block.endswith("\n") else block + "\n"


def splice_point(text, path):
    """Where new items go: before the newest existing item, else before </channel>."""
    spans = item_spans(text)
    if spans:
        return spans[0][0]
    anchor = text.find("</channel>")
    if anchor == -1:
        raise FeedError(f"{path}: no <item> and no </channel> to splice against")
    return text.rfind("\n", 0, anchor) + 1


def insert_items(base_text, path, items_text):
    """Inserts whole lines at a line boundary.

    The old check here compared the merged text minus the inserted slice against the base, which
    concatenation makes true by construction: it could never fail. The invariant worth asserting is
    the one `splice_point` promises and `sole_item_text` relies on, which is that both the cut and
    the inserted block land on line boundaries.
    """
    at = splice_point(base_text, path)
    if at != 0 and base_text[at - 1] != "\n":
        raise FeedError(f"{path}: the splice point is mid-line, so the inserted item would be merged into another")
    if items_text and not items_text.endswith("\n"):
        raise FeedError(f"{path}: the inserted items do not end on a line boundary")
    return base_text[:at] + items_text + base_text[at:]


def remove_version(base_text, path, version):
    """Every item advertising `version`, removed whole. Returns (text, count)."""
    root = parse_text(base_text)
    spans = item_spans(base_text)
    items = channel_items(root, path)
    if len(spans) != len(items):
        raise FeedError(
            f"{path}: found {len(spans)} item spans in the text but {len(items)} parsed items"
        )
    doomed = [span for span, item in zip(spans, items) if item_short_version(item) == version]
    if not doomed:
        return base_text, 0
    result = base_text
    for start, end in reversed(doomed):
        result = result[:start] + result[end:]
    return result, len(doomed)
