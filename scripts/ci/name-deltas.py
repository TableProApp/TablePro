#!/usr/bin/env python3
"""Renames the deltas generate_appcast wrote for one architecture and moves them out for upload.

generate_appcast names a delta after the bundle and the two build numbers (Appcast.swift:261 in
2.10.0). Both architectures share a build number, so without the suffix their deltas collide as
release assets. It drops a delta larger than 7/8 of the full archive, or one it failed to build,
and still exits 0, so a shortfall against the staged archives is reported as a warning.

Run: python3 scripts/ci/name-deltas.py --staging <dir> --version 0.81.0 --arch arm64 \
        --download-prefix https://.../download/v0.81.0/ --expect 5 --out-dir artifacts
"""

import argparse
import pathlib
import shutil
import sys
import urllib.parse
from xml.sax.saxutils import quoteattr

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from appcast_feed import (  # noqa: E402
    DELTAS,
    SPARKLE_NS,
    FeedError,
    channel_items,
    item_short_version,
    parse_text,
    read,
)

DELTA_FROM = f"{{{SPARKLE_NS}}}deltaFrom"


def delta_name(version, delta_from, arch):
    return f"TablePro-{version}-from-{delta_from}-{arch}.delta"


def name_deltas(staging, version, arch, download_prefix, out_dir):
    staging = pathlib.Path(staging)
    out_dir = pathlib.Path(out_dir)
    appcast = staging / "appcast.xml"
    text = read(appcast)

    items = channel_items(parse_text(text), appcast)
    if len(items) != 1 or item_short_version(items[0]) != version:
        raise FeedError(f"{appcast}: expected exactly one item, for {version}")
    deltas = items[0].find(DELTAS)
    enclosures = [] if deltas is None else deltas.findall("enclosure")

    moves = []
    for enclosure in enclosures:
        url = enclosure.get("url", "")
        delta_from = enclosure.get(DELTA_FROM)
        if not url.startswith(download_prefix):
            raise FeedError(f"the {arch} delta {url!r} is not under {download_prefix!r}")
        if not delta_from:
            raise FeedError(f"the {arch} delta {url!r} carries no sparkle:deltaFrom")
        source = staging / urllib.parse.unquote(url[len(download_prefix):])
        if not source.is_file():
            raise FeedError(f"the {arch} feed advertises {source.name}, which generate_appcast did not write")
        target = out_dir / delta_name(version, delta_from, arch)
        if target.exists() or target in (move[1] for move in moves):
            raise FeedError(f"{target} would be written twice")

        attribute = f"url={quoteattr(url)}"
        if text.count(attribute) != 1:
            raise FeedError(f"{appcast}: {url!r} does not appear exactly once")
        text = text.replace(attribute, f"url={quoteattr(download_prefix + target.name)}")
        moves.append((source, target))

    out_dir.mkdir(parents=True, exist_ok=True)
    for source, target in moves:
        # The staging directory is under $TMPDIR, which need not share a volume with the output.
        shutil.move(source, target)
    appcast.write_text(text, encoding="utf-8")
    return [target for _, target in moves]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--staging", required=True, help="the directory generate_appcast ran in")
    parser.add_argument("--version", required=True, help="marketing version being released")
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    parser.add_argument("--download-prefix", required=True, help="every delta URL must start with this")
    parser.add_argument("--expect", required=True, type=int, help="how many earlier archives were staged")
    parser.add_argument("--out-dir", required=True, help="where the renamed deltas go for upload")
    args = parser.parse_args(argv)

    try:
        moved = name_deltas(args.staging, args.version, args.arch, args.download_prefix, args.out_dir)
    except (FeedError, OSError) as error:
        print(f"::error::name-deltas: {error}", file=sys.stderr)
        return 1
    for target in moved:
        print(f"{args.arch} delta: {target}")
    if len(moved) > args.expect:
        print(f"::error::name-deltas: {len(moved)} {args.arch} deltas from {args.expect} staged releases", file=sys.stderr)
        return 1
    if len(moved) < args.expect:
        print(
            f"::warning::generate_appcast wrote {len(moved)} of {args.expect} {args.arch} deltas; "
            "the rest download the full archive. Its log says which it skipped."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
