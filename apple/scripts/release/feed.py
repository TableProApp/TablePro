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

ROOT = Path(__file__).resolve().parents[3]
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = "{" + SPARKLE_NAMESPACE + "}"
APPCAST = "appcast.xml"
MANIFEST = "plugins/v3.json"
MANIFEST_SIGNATURE = MANIFEST + ".sig"
SIGN_UNSIGNED_FLAG = "--sign-unsigned-manifest"
SIGN_UNSIGNED_HELP = f"sign a published {MANIFEST} that has no signature that verifies, after checking it by hand"
METADATA = ".github/plugin-registry.json"
APP_INFO_PLIST = "apple/TablePro/Info.plist"
MANIFEST_PUBLIC_KEY = "TableProPluginRegistryPublicEDKey"
PUBLIC_KEY_SCRIPT = Path(__file__).resolve().with_name("ed25519-public-key.swift")
CHANGELOG_URL = "https://docs.tablepro.app/changelog"
PHASED_ROLLOUT_SECONDS = 21600
INTEGER = re.compile(r"[0-9]+")
# Sparkle takes the first of two items with the same version, so the gated arm64 item goes first and the
# ungated x86_64 item is what an Intel Mac falls back to.
ARCHES = ("arm64", "x86_64")


def archive_name(release: version.Version, arch: str) -> str:
    return f"TablePro-{release}-{arch}.tar.xz"


def release_notes_name(release: version.Version, arch: str) -> str:
    return f"TablePro-{release}-{arch}.md"


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
    hardware_requirements: Optional[str]
    published: Optional[str]

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
            hardware_requirements=_sparkle_value(element, "hardwareRequirements"),
            published=(element.findtext("pubDate") or "").strip() or None,
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


def new_item_problems(items: List[Item], release: version.Version, url_base: str) -> List[str]:
    channel = "beta" if release.is_beta else None
    found = [item for item in items if item.build == str(release.build) and item.short_version == str(release)
             and item.channel == channel]
    expected = {url_base + archive_name(release, arch): arch for arch in ARCHES}
    problems = [f"{APPCAST} has an unexpected {release.channel} enclosure for {release} ({release.build}) "
                f"at {item.url}" for item in found if item.url not in expected]
    for url, arch in expected.items():
        matches = [item for item in found if item.url == url]
        if len(matches) != 1:
            problems.append(f"{APPCAST} has {len(matches)} {release.channel} items for "
                            f"{release} ({release.build}) at {url}, not one")
            continue
        item = matches[0]
        # arm64-only binary gets gated; the x86_64 build is ungated so it runs on Intel and on arm64.
        requirement = arch if arch == "arm64" else None
        if item.hardware_requirements != requirement:
            problems.append(f"{release}'s {arch} item has sparkle:hardwareRequirements "
                            f"{item.hardware_requirements!r}, not {requirement!r}")
        if not item.signature:
            problems.append(f"{release}'s {arch} enclosure has no sparkle:edSignature; "
                            "SPARKLE_PRIVATE_KEY does not match the archive's SUPublicEDKey")
    paired = [item for item in found if item.url in expected]
    order = [expected[item.url] for item in paired]
    if sorted(order) == sorted(ARCHES) and order != list(ARCHES):
        problems.append(f"{release}'s items run {', '.join(order)}, not {', '.join(ARCHES)}; Sparkle takes the "
                        "first of two equal versions, so Apple silicon would install the Intel build")
    if sorted(order) == sorted(ARCHES) and len({item.published for item in paired}) != 1:
        problems.append(f"{release}'s items carry the pubDates {', '.join(repr(item.published) for item in paired)}; "
                        "a phased rollout would offer the x86_64 build alone between them")
    return problems


def _text(element: minidom.Element) -> str:
    return "".join(node.data for node in element.childNodes if node.nodeType == node.TEXT_NODE).strip()


def _channel(data: bytes) -> Tuple[minidom.Document, minidom.Element]:
    try:
        document = minidom.parseString(data)
    except ExpatError as error:
        raise FeedError(f"{APPCAST} is not well-formed XML: {error}") from error
    channels = document.getElementsByTagName("channel")
    if not channels:
        raise FeedError(f"{APPCAST} has no rss channel")
    return document, channels[0]


def _child(node: minidom.Element, name: str) -> Optional[minidom.Element]:
    return next((each for each in node.childNodes if each.nodeType == each.ELEMENT_NODE and each.tagName == name),
                None)


def _item_nodes(channel: minidom.Element, matches: Callable[[str, str], bool]) -> List[minidom.Element]:
    def value(node: minidom.Element, name: str) -> str:
        return " ".join(_text(each) for each in node.getElementsByTagNameNS(SPARKLE_NAMESPACE, name))
    return [node for node in channel.childNodes
            if node.nodeType == node.ELEMENT_NODE and node.tagName == "item"
            and matches(value(node, "shortVersionString"), value(node, "version"))]


def remove_items(data: bytes, short_version: str) -> Tuple[bytes, int]:
    document, channel = _channel(data)
    doomed = _item_nodes(channel, lambda short, build: short == short_version)
    for item in doomed:
        channel.removeChild(item)
    return document.toxml(encoding="utf-8", standalone=True), len(doomed)


# generate_appcast refuses two archives of one bundle version, so each arch gets its own run over the same feed.
# The x86_64 run's feed is kept, since it prunes exactly as the universal feed did, and the arm64 run's item goes in
# just before the x86_64 one. None when Sparkle's per-branch limit left the release out.
def pair_items(intel: bytes, arm: bytes, release: version.Version) -> Optional[bytes]:
    def ours(short: str, build: str) -> bool:
        return short == str(release) and build == str(release.build)
    document, channel = _channel(intel)
    intel_items = _item_nodes(channel, ours)
    arm_items = _item_nodes(_channel(arm)[1], ours)
    if not intel_items:
        return None
    if len(intel_items) != 1 or len(arm_items) != 1:
        raise FeedError(f"generate_appcast wrote {len(arm_items)} arm64 and {len(intel_items)} x86_64 items for "
                        f"{release} ({release.build}), not one each")
    target = intel_items[0]
    arm_item = document.importNode(arm_items[0], True)
    # generate_appcast dates each item by its archive's creation time, and a phased rollout counts from that date.
    # One date keeps the arm64 item eligible whenever the x86_64 one is.
    published, arm_published = _child(target, "pubDate"), _child(arm_item, "pubDate")
    if published is not None and arm_published is not None:
        for each in list(arm_published.childNodes):
            arm_published.removeChild(each)
        arm_published.appendChild(document.createTextNode(_text(published)))
    spacing = target.previousSibling
    channel.insertBefore(arm_item, target)
    if spacing is not None and spacing.nodeType == spacing.TEXT_NODE:
        channel.insertBefore(document.createTextNode(spacing.data), target)
    return document.toxml(encoding="utf-8", standalone=True)


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


def verify_detached(path: Path, signature: str, key: str, tools: Path, run: Callable = subprocess.run) -> List[str]:
    try:
        _tool(tools, "sign_update", key, "--verify", "--ed-key-file", "-", str(path), signature, run=run)
    except FeedError as error:
        return [str(error)]
    return []


def public_key(private_key: str, run: Callable = subprocess.run) -> str:
    result = run(["xcrun", "swift", str(PUBLIC_KEY_SCRIPT)], input=private_key, capture_output=True, text=True)
    if result.returncode != 0:
        raise FeedError(f"PLUGIN_REGISTRY_ED_PRIVATE_KEY: {result.stderr.strip() or 'no public key'}")
    return result.stdout.strip()


# The manifest key is the app's own, apart from Sparkle's, so the secret is checked against what the app pins.
def check_manifest_key(root: Path, manifest_key: str, derive: Callable[[str], str] = public_key) -> None:
    plist = root / APP_INFO_PLIST
    try:
        pinned = plistlib.loads(plist.read_bytes()).get(MANIFEST_PUBLIC_KEY)
    except (plistlib.InvalidFileException, ValueError, OSError) as error:
        raise FeedError(f"{plist}: {error}") from error
    if not isinstance(pinned, str) or not pinned:
        raise FeedError(f"{APP_INFO_PLIST} has no {MANIFEST_PUBLIC_KEY}")
    if derive(manifest_key) != pinned:
        raise FeedError(f"PLUGIN_REGISTRY_ED_PRIVATE_KEY does not match the app's {MANIFEST_PUBLIC_KEY}")


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


# The app verifies the exact bytes of v3.json against the detached signature beside it. A published manifest that
# no signature vouches for, or none at all, is signed only when the maintainer passes sign_unsigned after checking.
def _signed_manifest(site: Path, scratch: Path, edit: Callable[[Path], bool], key: str, tools: Path,
                     run: Callable, sign_unsigned: bool) -> Optional[Tuple[Path, str]]:
    published = site / MANIFEST
    signature = site / MANIFEST_SIGNATURE
    staged = scratch / Path(MANIFEST).name
    if not published.exists():
        problems = [f"{MANIFEST} does not exist"]
    elif not signature.is_file():
        problems = [f"{MANIFEST_SIGNATURE} does not exist"]
    else:
        problems = verify_detached(published, signature.read_text(encoding="utf-8").strip(), key, tools, run)
    if not sign_unsigned:
        _refuse(problems, f"no signature vouches for the published {MANIFEST}. Check it by hand, then rerun with "
                          f"{SIGN_UNSIGNED_FLAG} (in CI, set the repository variable PLUGIN_MANIFEST_RESIGN to true "
                          "for one run, then unset it)")
    unverified = bool(problems) and published.exists()
    if published.exists():
        shutil.copy2(published, staged)
    if not edit(staged):
        if not unverified:
            return None
        registry.restamp(staged)
    text = _tool(tools, "sign_update", key, "-p", "--ed-key-file", "-", str(staged), run=run)
    _refuse(verify_detached(staged, text, key, tools, run), f"the new {MANIFEST} fails its signature check")
    return staged, text


def _publish_manifest(site: Path, staged: Path, signature: str) -> None:
    (site / MANIFEST).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(staged, site / MANIFEST)
    (site / MANIFEST_SIGNATURE).write_text(signature + "\n", encoding="utf-8")


def add(root: Path, site: Path, tag: str, notes: Path, critical: bool, tools: Path, key: str, manifest_key: str,
        releases: Releases, repository: str, run: Callable = subprocess.run,
        log: Callable[[str], None] = print, sign_unsigned_manifest: bool = False,
        derive: Callable[[str], str] = public_key) -> bool:
    release = version.parse_tag(tag)
    if critical and release.is_beta:
        raise FeedError(f"{tag} is a beta, and a beta is never critical")
    if not notes.is_file():
        raise FeedError(f"{notes} does not exist")
    check_manifest_key(root, manifest_key, derive)
    appcast = _published_appcast(site, key, tools, run)
    metadata = registry.load_metadata(root / METADATA)
    plugins = [f"{target}-{release}.zip" for target in registry.publish_set(metadata)]
    kit = registry.pluginkit_version(root)
    archives = [archive_name(release, arch) for arch in ARCHES]
    url_base = f"https://github.com/{repository}/releases/download/{tag}/"
    items = parse_items(appcast.read_bytes())
    has_item = appcast_has(items, release)

    with tempfile.TemporaryDirectory(prefix="feed-") as scratch:
        downloads = Path(scratch) / "downloads"
        downloads.mkdir()
        names = plugins if has_item else [*archives, *plugins]
        releases.download(tag, names, downloads)
        for name in names:
            log(releases.verify(tag, downloads / name))
        entries = registry.describe(downloads, str(release), release.build, kit, metadata)

        staged_appcast = Path(scratch) / APPCAST
        new_appcast = False
        if has_item:
            log(f"{APPCAST} already has {release} ({release.build})")
        else:
            critical_build = release.build if critical else None
            if critical_build is None and not release.is_beta:
                critical_build = carried_critical(items)
            generated = {}
            for arch in ARCHES:
                archive = archive_name(release, arch)
                check_archive(downloads / archive, release)
                stage = Path(scratch) / f"stage-{arch}"
                stage.mkdir()
                (downloads / archive).rename(stage / archive)
                # generate_appcast embeds the notes whose name matches the archive's.
                shutil.copy2(notes, stage / release_notes_name(release, arch))
                shutil.copy2(appcast, stage / APPCAST)
                arguments = appcast_arguments(stage, tag, release, critical_build, repository)
                log(_tool(tools, "generate_appcast", key, *arguments, run=run))
                generated[arch] = (stage / APPCAST).read_bytes()
            paired = pair_items(generated["x86_64"], generated["arm64"], release)
            if paired is not None:
                staged_appcast.write_bytes(paired)
                log(sign(staged_appcast, key, tools, run))
                _refuse(new_item_problems(parse_items(paired), release, url_base)
                        + verify_signature(staged_appcast, key, tools, run))
                new_appcast = True
            else:
                # The archive matched the tag, so only Sparkle's per-branch limit left it out.
                log(f"generate_appcast keeps newer items on {release}'s branch, so {APPCAST} stays as it is")
        manifest = _signed_manifest(site, Path(scratch), lambda path: registry.add(
            path, entries, release.channel, url_base, metadata["retainFromPluginKit"], log), manifest_key, tools, run,
            sign_unsigned_manifest)
        if new_appcast:
            shutil.copy2(staged_appcast, appcast)
        if manifest is not None:
            _publish_manifest(site, *manifest)
    return new_appcast or manifest is not None


def withdraw(site: Path, text: str, tools: Path, key: str, manifest_key: str, run: Callable = subprocess.run,
             log: Callable[[str], None] = print, sign_unsigned_manifest: bool = False, root: Path = ROOT,
             derive: Callable[[str], str] = public_key) -> bool:
    release = version.parse_version(text)
    check_manifest_key(root, manifest_key, derive)
    appcast = _published_appcast(site, key, tools, run)
    previous = appcast.read_bytes()
    edited, removed = remove_items(previous, str(release))
    if removed and any(item.channel is None for item in parse_items(previous)) \
            and not any(item.channel is None for item in parse_items(edited)):
        raise FeedError(f"withdrawing {release} would leave the feed with no default-channel item")
    with tempfile.TemporaryDirectory(prefix="withdraw-") as scratch:
        manifest = _signed_manifest(site, Path(scratch), lambda path: path.exists() and registry.withdraw(
            path, str(release), log), manifest_key, tools, run, sign_unsigned_manifest)
        if removed:
            appcast.write_bytes(edited)
            log(sign(appcast, key, tools, run))
            log(f"removed {removed} {release} item(s) from {APPCAST}")
        else:
            log(f"{APPCAST} has no {release} item")
        if manifest is not None:
            _publish_manifest(site, *manifest)
    return bool(removed) or manifest is not None


def latest(site: Path) -> version.Version:
    highest = highest_stable(parse_items((site / APPCAST).read_bytes()))
    if highest is None:
        raise FeedError(f"{site / APPCAST} has no stable item")
    return highest


def _environment() -> Tuple[Path, str, str]:
    tools = os.environ.get("SPARKLE_BIN")
    key = os.environ.get("SPARKLE_PRIVATE_KEY")
    manifest_key = os.environ.get("PLUGIN_REGISTRY_ED_PRIVATE_KEY")
    if not tools:
        raise FeedError("SPARKLE_BIN is not set; run the setup-sparkle action first")
    if not key:
        raise FeedError("SPARKLE_PRIVATE_KEY is not set")
    if not manifest_key:
        raise FeedError("PLUGIN_REGISTRY_ED_PRIVATE_KEY is not set")
    return Path(tools), key, manifest_key


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Edits the appcast and the plugin manifest in a gh-pages checkout.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("add", help="add a published release to the feed and the manifest")
    command.add_argument("tag")
    command.add_argument("--site", type=Path, required=True)
    command.add_argument("--notes", type=Path, required=True)
    command.add_argument("--critical", action="store_true")
    command.add_argument(SIGN_UNSIGNED_FLAG, action="store_true", help=SIGN_UNSIGNED_HELP)
    command = commands.add_parser("withdraw", help="remove a version from the feed and the manifest")
    command.add_argument("version")
    command.add_argument("--site", type=Path, required=True)
    command.add_argument(SIGN_UNSIGNED_FLAG, action="store_true", help=SIGN_UNSIGNED_HELP)
    command = commands.add_parser("latest", help="print the highest stable version in the feed")
    command.add_argument("--site", type=Path, required=True)
    args = parser.parse_args(argv)

    repository = os.environ.get("GITHUB_REPOSITORY", version.REPOSITORY)
    try:
        if args.command == "latest":
            print(latest(args.site))
            return 0
        tools, key, manifest_key = _environment()
        if args.command == "add":
            add(ROOT, args.site, args.tag, args.notes, args.critical, tools, key, manifest_key, Releases(repository),
                repository, sign_unsigned_manifest=args.sign_unsigned_manifest)
        else:
            withdraw(args.site, args.version, tools, key, manifest_key,
                     sign_unsigned_manifest=args.sign_unsigned_manifest)
    except (FeedError, registry.RegistryError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
