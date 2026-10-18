#!/usr/bin/env python3

import argparse
import lzma
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional, Tuple
from xml.dom import minidom
from xml.parsers.expat import ExpatError

import registry
import version

ROOT = Path(__file__).resolve().parent.parent.parent
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = "{" + SPARKLE_NAMESPACE + "}"
APPCAST = "appcast.xml"
MANIFEST = "plugins/v3.json"
METADATA = ".github/plugin-registry.json"
CHANGELOG_URL = "https://docs.tablepro.app/changelog"
PHASED_ROLLOUT_SECONDS = 21600
INTEGER = re.compile(r"[0-9]+")


class FeedError(Exception):
    pass


@dataclass(frozen=True)
class Item:
    build: Optional[str]
    short_version: Optional[str]
    channel: Optional[str]
    is_critical: bool
    critical_version: Optional[str]
    url: Optional[str]
    signature: Optional[str]

    @property
    def label(self) -> str:
        return self.short_version or self.build or "an item"


def _sparkle_value(element: ET.Element, name: str) -> Optional[str]:
    child = element.find(SPARKLE + name)
    return (child.text or "").strip() if child is not None else None


def parse_items(data: bytes) -> List[Item]:
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise FeedError(f"{APPCAST} is not well-formed XML: {error}") from error
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise FeedError(f"{APPCAST} has no rss channel")
    items = []
    for element in channel.findall("item"):
        enclosure = element.find("enclosure")
        critical = element.find(f".//{SPARKLE}criticalUpdate")
        items.append(Item(
            build=_sparkle_value(element, "version"),
            short_version=_sparkle_value(element, "shortVersionString"),
            channel=_sparkle_value(element, "channel"),
            is_critical=critical is not None,
            critical_version=critical.get(SPARKLE + "version") if critical is not None else None,
            url=enclosure.get("url") if enclosure is not None else None,
            signature=enclosure.get(SPARKLE + "edSignature") if enclosure is not None else None,
        ))
    return items


def carried_critical(items: List[Item]) -> Optional[int]:
    builds = []
    for item in items:
        if item.channel is not None or not item.is_critical:
            continue
        # A critical update with no version is critical below its own build.
        text = item.critical_version or item.build
        if text is None or not INTEGER.fullmatch(text):
            raise FeedError(f"{item.label}: the critical update version {text!r} is not an integer")
        builds.append(int(text))
    return max(builds) if builds else None


def highest_stable(items: List[Item]) -> Optional[version.Version]:
    stables = []
    for item in items:
        if item.channel is not None:
            continue
        parsed = version.try_parse_tag(f"v{item.short_version}") if item.short_version else None
        if parsed is not None and not parsed.is_beta:
            stables.append(parsed)
    return max(stables, key=lambda candidate: candidate.build) if stables else None


def new_item_problems(items: List[Item], release: version.Version, url: str) -> List[str]:
    channel = "beta" if release.is_beta else None
    found = [item for item in items if item.build == str(release.build) and item.short_version == str(release)
             and item.channel == channel and item.url == url]
    if len(found) != 1:
        return [f"{APPCAST} has {len(found)} {release.channel} items for {release} ({release.build}) at {url}, not one"]
    if not found[0].signature:
        return [f"{release}'s enclosure has no sparkle:edSignature; "
                "SPARKLE_PRIVATE_KEY does not match the archive's SUPublicEDKey"]
    return []


def _text(element: minidom.Element) -> str:
    return "".join(node.data for node in element.childNodes if node.nodeType == node.TEXT_NODE).strip()


def remove_items(data: bytes, short_version: str) -> Tuple[bytes, int]:
    try:
        document = minidom.parseString(data)
    except ExpatError as error:
        raise FeedError(f"{APPCAST} is not well-formed XML: {error}") from error
    channels = document.getElementsByTagName("channel")
    if not channels:
        raise FeedError(f"{APPCAST} has no rss channel")
    channel = channels[0]
    doomed = [node for node in channel.childNodes
              if node.nodeType == node.ELEMENT_NODE and node.tagName == "item"
              and any(_text(each) == short_version
                      for each in node.getElementsByTagNameNS(SPARKLE_NAMESPACE, "shortVersionString"))]
    for item in doomed:
        channel.removeChild(item)
    return document.toxml(encoding="utf-8", standalone=True), len(doomed)


def appcast_has(items: List[Item], release: version.Version) -> bool:
    matches = [item for item in items if item.short_version == str(release) or item.build == str(release.build)]
    for item in matches:
        if item.short_version != str(release) or item.build != str(release.build):
            raise FeedError(f"{APPCAST} has {item.short_version} at build {item.build}, "
                            f"which clashes with {release} at {release.build}")
    return bool(matches)


def appcast_arguments(stage: Path, tag: str, release: version.Version, critical_build: Optional[int],
                      repository: str) -> List[str]:
    command = [
        "--ed-key-file", "-", "--embed-release-notes", "--maximum-deltas", "0",
        "--versions", str(release.build),
        "--download-url-prefix", f"https://github.com/{repository}/releases/download/{tag}/",
        "--full-release-notes-url", CHANGELOG_URL,
    ]
    if release.is_beta:
        command += ["--channel", "beta"]
    else:
        command += ["--phased-rollout-interval", str(PHASED_ROLLOUT_SECONDS)]
        if critical_build is not None:
            command += ["--critical-update-version", str(critical_build)]
    return command + [str(stage)]


def check_archive(path: Path, release: version.Version) -> None:
    name = "TablePro.app/Contents/Info.plist"
    try:
        with tarfile.open(path, "r:xz") as archive:
            member = archive.extractfile(name)
            info = plistlib.loads(member.read()) if member is not None else None
    except KeyError:
        info = None
    except (tarfile.TarError, lzma.LZMAError, plistlib.InvalidFileException, ValueError, OSError) as error:
        raise FeedError(f"{path.name}: {error}") from error
    if info is None:
        raise FeedError(f"{path.name} has no {name}")
    found = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
    if found != (str(release), str(release.build)):
        raise FeedError(f"{path.name} holds {found[0]} ({found[1]}), not {release} ({release.build})")


class Releases:
    def __init__(self, repository: str, run: Callable = subprocess.run):
        self.repository = repository
        self._run = run

    def _gh(self, *args: str) -> str:
        result = self._run(["gh", *args, "--repo", self.repository], capture_output=True, text=True)
        if result.returncode != 0:
            raise FeedError(f"gh {' '.join(args[:3])}: {result.stderr.strip()}")
        return result.stdout

    def download(self, tag: str, names: List[str], directory: Path) -> None:
        patterns = [argument for name in names for argument in ("--pattern", name)]
        self._gh("release", "download", tag, "--dir", str(directory), "--clobber", *patterns)
        missing = [name for name in names if not (directory / name).is_file()]
        if missing:
            raise FeedError(f"{tag} has no {', '.join(missing)}")

    def verify(self, tag: str, path: Path) -> str:
        return self._gh("release", "verify-asset", tag, str(path)).strip()


def _tool(tools: Path, name: str, key: str, *args: str, run: Callable = subprocess.run) -> str:
    result = run([str(tools / name), *args], input=key, capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        raise FeedError(f"{name} failed: {output}")
    return output


def sign(path: Path, key: str, tools: Path, run: Callable = subprocess.run) -> str:
    return _tool(tools, "sign_update", key, "--ed-key-file", "-", str(path), run=run)


def verify_signature(path: Path, key: str, tools: Path, run: Callable = subprocess.run) -> List[str]:
    try:
        _tool(tools, "sign_update", key, "--verify", "--ed-key-file", "-", str(path), run=run)
    except FeedError as error:
        return [str(error)]
    return []


def _refuse(problems: List[str], reason: str = "the feed fails its checks") -> None:
    if problems:
        raise FeedError(f"{reason}, so nothing was written:\n  " + "\n  ".join(problems))


def _published_appcast(site: Path, key: str, tools: Path, run: Callable) -> Path:
    appcast = site / APPCAST
    if not appcast.is_file():
        raise FeedError(f"{site} has no {APPCAST}")
    _refuse(verify_signature(appcast, key, tools, run),
            f"the published {APPCAST}'s signature does not verify; it changed outside CI")
    return appcast


def add(root: Path, site: Path, tag: str, notes: Path, critical: bool, tools: Path, key: str,
        releases: Releases, repository: str, run: Callable = subprocess.run,
        log: Callable[[str], None] = print) -> bool:
    release = version.parse_tag(tag)
    if critical and release.is_beta:
        raise FeedError(f"{tag} is a beta, and a beta is never critical")
    if not notes.is_file():
        raise FeedError(f"{notes} does not exist")
    appcast = _published_appcast(site, key, tools, run)
    metadata = registry.load_metadata(root / METADATA)
    plugins = [f"{target}-{release}.zip" for target in registry.publish_set(metadata)]
    kit = registry.pluginkit_version(root)
    archive = f"TablePro-{release}.tar.xz"
    url_base = f"https://github.com/{repository}/releases/download/{tag}/"
    items = parse_items(appcast.read_bytes())
    has_item = appcast_has(items, release)

    with tempfile.TemporaryDirectory(prefix="feed-") as scratch:
        downloads = Path(scratch) / "downloads"
        downloads.mkdir()
        names = plugins if has_item else [archive, *plugins]
        releases.download(tag, names, downloads)
        for name in names:
            log(releases.verify(tag, downloads / name))
        entries = registry.describe(downloads, str(release), release.build, kit, metadata)

        changed = False
        if has_item:
            log(f"{APPCAST} already has {release} ({release.build})")
        else:
            check_archive(downloads / archive, release)
            stage = Path(scratch) / "stage"
            stage.mkdir()
            (downloads / archive).rename(stage / archive)
            shutil.copy2(notes, stage / f"TablePro-{release}.md")
            shutil.copy2(appcast, stage / APPCAST)
            critical_build = release.build if critical else None
            if critical_build is None and not release.is_beta:
                critical_build = carried_critical(items)
            arguments = appcast_arguments(stage, tag, release, critical_build, repository)
            log(_tool(tools, "generate_appcast", key, *arguments, run=run))
            staged = parse_items((stage / APPCAST).read_bytes())
            if appcast_has(staged, release):
                _refuse(new_item_problems(staged, release, url_base + archive)
                        + verify_signature(stage / APPCAST, key, tools, run))
                shutil.copy2(stage / APPCAST, appcast)
                changed = True
            else:
                # The archive matched the tag, so only Sparkle's per-branch limit left it out.
                log(f"generate_appcast keeps newer items on {release}'s branch, so {APPCAST} stays as it is")
        manifest = site / MANIFEST
        if registry.add(manifest, entries, release.channel, url_base, metadata["retainFromPluginKit"], log):
            changed = True
    return changed


def withdraw(site: Path, text: str, tools: Path, key: str, run: Callable = subprocess.run,
             log: Callable[[str], None] = print) -> bool:
    release = version.parse_version(text)
    appcast = _published_appcast(site, key, tools, run)
    previous = appcast.read_bytes()
    edited, removed = remove_items(previous, str(release))
    changed = False
    if removed:
        if any(item.channel is None for item in parse_items(previous)) \
                and not any(item.channel is None for item in parse_items(edited)):
            raise FeedError(f"withdrawing {release} would leave the feed with no default-channel item")
        appcast.write_bytes(edited)
        log(sign(appcast, key, tools, run))
        log(f"removed {removed} {release} item(s) from {APPCAST}")
        changed = True
    else:
        log(f"{APPCAST} has no {release} item")
    manifest = site / MANIFEST
    if manifest.exists() and registry.withdraw(manifest, str(release), log):
        changed = True
    return changed


def latest(site: Path) -> version.Version:
    highest = highest_stable(parse_items((site / APPCAST).read_bytes()))
    if highest is None:
        raise FeedError(f"{site / APPCAST} has no stable item")
    return highest


def _environment() -> Tuple[Path, str]:
    tools = os.environ.get("SPARKLE_BIN")
    key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not tools:
        raise FeedError("SPARKLE_BIN is not set; run the setup-sparkle action first")
    if not key:
        raise FeedError("SPARKLE_PRIVATE_KEY is not set")
    return Path(tools), key


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Edits the appcast and the plugin manifest in a gh-pages checkout.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("add", help="add a published release to the feed and the manifest")
    command.add_argument("tag")
    command.add_argument("--site", type=Path, required=True)
    command.add_argument("--notes", type=Path, required=True)
    command.add_argument("--critical", action="store_true")
    command = commands.add_parser("withdraw", help="remove a version from the feed and the manifest")
    command.add_argument("version")
    command.add_argument("--site", type=Path, required=True)
    command = commands.add_parser("latest", help="print the highest stable version in the feed")
    command.add_argument("--site", type=Path, required=True)
    args = parser.parse_args(argv)

    repository = os.environ.get("GITHUB_REPOSITORY", version.REPOSITORY)
    try:
        if args.command == "latest":
            print(latest(args.site))
            return 0
        tools, key = _environment()
        if args.command == "add":
            add(ROOT, args.site, args.tag, args.notes, args.critical, tools, key, Releases(repository), repository)
        else:
            withdraw(args.site, args.version, tools, key)
    except (FeedError, registry.RegistryError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
