#!/usr/bin/env python3
"""Splices one release's two architecture items into the published Sparkle feed.

`generate_appcast` keeps only what it is handed, so the release used to hand it the whole
published feed as a seed. That is safe only while the staging directory holds nothing but the new
archive, and it stops being true as soon as anything else is staged, which generating deltas
requires. Verified in the pinned Sparkle 2.9.5 source: `FeedXML.swift:333-339` matches an existing
item by version, and two writes then run outside the resulting `if createNewItem` guard. Line 603
assigns the enclosure's attributes unconditionally, so a seeded item matched by a staged archive
has its download URL rewritten into the current release's directory, which is a permanent 404.
Lines 523-525 remove that item's `<description>` when the staged archive has no sibling notes
file. Neither is caught by the rewind guard in build.yml, which compares only version strings.

So generate_appcast now runs against a directory holding one release's archive and nothing else,
and this script merges its output into the feed. Items already published are never handed to a
generator at all; see appcast_feed for how they are moved.

This replaces an awk state machine that scanned for `<item>` and `</item>` line by line, on three
untested assumptions, one of which was that no release note ever contains the literal `</item>`.

Nothing pruned the feed, so it grew by two items per release forever: 155 items and 695 KB by
0.74.0, of which 84% was embedded release-note CDATA and 92% was items no install can ever be
offered. Every install downloads the whole file on every scheduled check, daily by default.
`--keep-releases` bounds it. Dropping an old item is safe because Sparkle picks the highest version
present (`SUAppcastDriver.bestItemFromAppcastItems`) and never looks for the host's own version in
the feed; what it cannot survive is losing the newest item, which is what the caller's rewind guard
still checks.

Run: python3 scripts/ci/merge-appcast.py --base appcast.xml --version 0.75.0 \
        --arm64 <dir>/appcast.xml --x86-64 <dir>/appcast.xml \
        --download-prefix https://.../download/v0.75.0/ --out appcast/appcast.xml
"""

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from appcast_feed import (  # noqa: E402
    ED_SIGNATURE,
    HARDWARE,
    FeedError,
    channel_items,
    insert_items,
    item_bundle_version,
    item_enclosures,
    item_short_version,
    parse,
    parse_text,
    read,
    remove_version,
    sole_item_text,
)

DEFAULT_KEEP_RELEASES = 5

MergeError = FeedError


def sole_item(path, version):
    items = channel_items(parse(path), path)
    matching = [item for item in items if item_short_version(item) == version]
    if len(items) != 1 or len(matching) != 1:
        raise FeedError(
            f"{path}: expected exactly one item for {version}, "
            f"found {len(items)} item(s) of which {len(matching)} match"
        )
    return matching[0]


def check_new_items(arm64_item, x86_64_item, version, download_prefix):
    if arm64_item.find(HARDWARE) is None:
        raise FeedError(
            f"the arm64 item for {version} carries no <sparkle:hardwareRequirements>; "
            "every install would be offered the Apple Silicon build"
        )
    hardware = (arm64_item.find(HARDWARE).text or "").strip()
    if hardware != "arm64":
        raise FeedError(f"the arm64 item declares hardwareRequirements '{hardware}', expected 'arm64'")
    if x86_64_item.find(HARDWARE) is not None:
        raise FeedError(f"the x86_64 item for {version} carries <sparkle:hardwareRequirements>")

    arm64_bundle = item_bundle_version(arm64_item)
    x86_64_bundle = item_bundle_version(x86_64_item)
    if not arm64_bundle or arm64_bundle != x86_64_bundle:
        raise FeedError(
            f"the two architectures disagree on <sparkle:version>: "
            f"arm64 {arm64_bundle!r}, x86_64 {x86_64_bundle!r}"
        )

    for label, item in (("arm64", arm64_item), ("x86_64", x86_64_item)):
        enclosures = item_enclosures(item)
        if not enclosures:
            raise FeedError(f"the {label} item for {version} advertises no enclosure")
        for enclosure in enclosures:
            url = enclosure.get("url", "")
            if not url.startswith(download_prefix):
                raise FeedError(
                    f"the {label} item advertises {url!r}, which is not under {download_prefix!r}"
                )
            # generate_appcast signs an archive only when the app's own Info.plist declares
            # SUPublicEDKey (Appcast.swift:199 in 2.9.5). Drop that key and it writes an unsigned
            # enclosure, reports "Wrote 1 new update" and exits 0, and every installed updater
            # then refuses the download with nothing said anywhere. Measured against the pinned
            # 2.9.5 generate_appcast with a bundle that omits the key.
            if not enclosure.get(ED_SIGNATURE):
                raise FeedError(
                    f"the {label} enclosure {url!r} carries no sparkle:edSignature; "
                    "check that TablePro/Info.plist still declares SUPublicEDKey"
                )
    return arm64_bundle


def check_base(base_root, base_path, version, bundle_version):
    for item in channel_items(base_root, base_path):
        if item_short_version(item) == version:
            raise FeedError(f"{base_path} already advertises {version}")
        existing = item_bundle_version(item)
        if existing and int(existing) >= int(bundle_version):
            raise FeedError(
                f"{base_path} advertises build {existing}, which is not below the new build "
                f"{bundle_version}; Sparkle compares builds, so the release would not be offered"
            )


def releases_in_order(text, path):
    """Every distinct shortVersionString, newest first, in document order."""
    ordered = []
    for item in channel_items(parse_text(text), path):
        version = item_short_version(item)
        if version and version not in ordered:
            ordered.append(version)
    return ordered


def prune(text, path, keep_releases):
    """Drops every item belonging to a release outside the newest `keep_releases`."""
    if keep_releases <= 0:
        return text, []
    ordered = releases_in_order(text, path)
    doomed = ordered[keep_releases:]
    result = text
    for version in doomed:
        result, removed = remove_version(result, path, version)
        if removed == 0:
            raise FeedError(f"{path}: {version} was listed for pruning but no item carries it")
    return result, doomed


def merge(base_path, arm64_path, x86_64_path, version, download_prefix, out_path, keep_releases):
    base_text = read(base_path)
    base_root = parse(base_path)

    arm64_item = sole_item(arm64_path, version)
    x86_64_item = sole_item(x86_64_path, version)
    bundle_version = check_new_items(arm64_item, x86_64_item, version, download_prefix)
    try:
        int(bundle_version)
    except ValueError as error:
        raise FeedError(f"<sparkle:version> {bundle_version!r} is not an integer build number") from error
    check_base(base_root, base_path, version, bundle_version)

    # arm64 first: Sparkle offers the first item the host can run, so an x86_64 item ahead of it
    # would hand every Apple Silicon Mac the Intel build.
    insert = sole_item_text(arm64_path, version) + sole_item_text(x86_64_path, version)
    merged = insert_items(base_text, base_path, insert)

    merged_items = channel_items(parse_text(merged), "merged feed")
    if len(merged_items) != len(channel_items(base_root, base_path)) + 2:
        raise FeedError("the merged feed does not hold exactly two more items than the base")
    if [item_short_version(item) for item in merged_items[:2]] != [version, version]:
        raise FeedError("the two new items are not the first two in the merged feed")
    if merged_items[0].find(HARDWARE) is None:
        raise FeedError("the arm64 item is not first; Sparkle offers the first item the host can run")

    merged, dropped = prune(merged, "merged feed", keep_releases)
    if dropped:
        pruned_items = channel_items(parse_text(merged), "pruned feed")
        if not pruned_items:
            raise FeedError("pruning emptied the feed")
        if item_short_version(pruned_items[0]) != version:
            raise FeedError(f"pruning left {item_short_version(pruned_items[0])} newest instead of {version}")
        if pruned_items[0].find(HARDWARE) is None:
            raise FeedError("pruning left a non-arm64 item first")
        kept = releases_in_order(merged, "pruned feed")
        if len(kept) != keep_releases:
            raise FeedError(f"pruning left {len(kept)} releases, expected {keep_releases}")
        print(f"pruned {len(dropped)} release(s) below the newest {keep_releases}: {', '.join(dropped)}")

    pathlib.Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(out_path).write_text(merged, encoding="utf-8")
    return merged


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the published feed to splice into")
    parser.add_argument("--version", required=True, help="marketing version being released")
    parser.add_argument("--arm64", required=True, help="generate_appcast output for the arm64 archive")
    parser.add_argument("--x86-64", required=True, dest="x86_64", help="generate_appcast output for x86_64")
    parser.add_argument("--download-prefix", required=True, help="every enclosure URL must start with this")
    parser.add_argument("--out", required=True, help="where to write the merged feed")
    parser.add_argument(
        "--keep-releases",
        type=int,
        default=DEFAULT_KEEP_RELEASES,
        help=f"how many releases the published feed keeps, newest first (default: {DEFAULT_KEEP_RELEASES}; 0 keeps all)",
    )
    args = parser.parse_args(argv)

    try:
        merge(
            args.base,
            args.arm64,
            args.x86_64,
            args.version,
            args.download_prefix,
            args.out,
            args.keep_releases,
        )
    except FeedError as error:
        print(f"::error::merge-appcast: {error}", file=sys.stderr)
        return 1
    print(f"merged {args.version} into {args.base} -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
