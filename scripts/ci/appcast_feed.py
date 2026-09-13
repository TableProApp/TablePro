"""Text-level primitives for editing the published Sparkle feed.

Two scripts change appcast.xml: merge-appcast.py adds a release's items, pull-release.py removes
them again when a build has to be withdrawn. They have to agree on where an item starts and ends,
so that lives here rather than in both.

Everything works on the file's text. A full ElementTree round trip of the feed would rewrite
namespace prefixes and re-encode 640 KB of CDATA, so items that are not being touched are moved
byte for byte and only parsed to be understood.
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


def item_spans(text):
    """Whole-line (start, end) offsets of every <item> in document order.

    Release-note CDATA can hold either literal tag, so the scan tracks nesting from the opening
    tag it is currently inside rather than matching tags pairwise across the whole document. An
    item never nests inside another item, so the first `</item>` after an opening tag closes it,
    except where a CDATA section intervenes; CDATA is therefore skipped whole.
    """
    spans = []
    index = 0
    length = len(text)
    while index < length:
        open_at = text.find("<item", index)
        if open_at == -1:
            break
        cursor = open_at
        close_at = -1
        while cursor < length:
            cdata_at = text.find("<![CDATA[", cursor)
            candidate = text.find("</item>", cursor)
            if candidate == -1:
                break
            if cdata_at != -1 and cdata_at < candidate:
                cdata_end = text.find("]]>", cdata_at)
                if cdata_end == -1:
                    raise FeedError("unterminated CDATA section in the feed")
                cursor = cdata_end + 3
                continue
            close_at = candidate
            break
        if close_at == -1:
            raise FeedError("an <item> is never closed in the feed")
        line_start = text.rfind("\n", 0, open_at) + 1
        line_end = text.find("\n", close_at)
        line_end = length if line_end == -1 else line_end + 1
        spans.append((line_start, line_end))
        index = close_at + len("</item>")
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
    at = splice_point(base_text, path)
    merged = base_text[:at] + items_text + base_text[at:]
    if merged[:at] + merged[at + len(items_text):] != base_text:
        raise FeedError("the splice altered bytes outside the inserted items")
    return merged


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
