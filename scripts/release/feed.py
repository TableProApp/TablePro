#!/usr/bin/env python3

import argparse
import hashlib
import json
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
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Iterator, List, Optional, Tuple

import registry
import version

ROOT = Path(__file__).resolve().parent.parent.parent
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
BRANCH = "feeds"
REMOTE_BRANCH = f"refs/remotes/origin/{BRANCH}"
APPCAST = "appcast.xml"
MANIFEST = "plugins/v3.json"
METADATA = ".github/plugin-registry.json"
PROJECT = "project.yml"
PLUGINKIT_CONFIG = "Configs/PluginKit.xcconfig"
PHASED_ROLLOUT_SECONDS = 21600
PUSH_ATTEMPTS = 3
BOT_NAME = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"
ITEM_TEXT = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.DOTALL)
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
    length: Optional[str]

    @property
    def label(self) -> str:
        return self.short_version or self.build or "an item"


@dataclass(frozen=True)
class Expected:
    release: version.Version
    url: str


def _sparkle_value(element: ET.Element, name: str) -> Optional[str]:
    child = element.find(SPARKLE + name)
    if child is not None:
        return (child.text or "").strip()
    enclosure = element.find("enclosure")
    return enclosure.get(SPARKLE + name) if enclosure is not None else None


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
        name = element.find(SPARKLE + "channel")
        items.append(Item(
            build=_sparkle_value(element, "version"),
            short_version=_sparkle_value(element, "shortVersionString"),
            channel=(name.text or "").strip() if name is not None else None,
            is_critical=critical is not None,
            critical_version=critical.get(SPARKLE + "version") if critical is not None else None,
            url=enclosure.get("url") if enclosure is not None else None,
            signature=enclosure.get(SPARKLE + "edSignature") if enclosure is not None else None,
            length=enclosure.get("length") if enclosure is not None else None,
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


def feed_problems(data: bytes, previous: Optional[bytes] = None, expected: Optional[Expected] = None) -> List[str]:
    items = parse_items(data)
    problems = []
    if previous is not None and any(item.channel is None for item in parse_items(previous)) \
            and not any(item.channel is None for item in items):
        problems.append("the feed no longer has a default-channel item")

    versions: Dict[int, set] = {}
    for item in items:
        if item.url is None:
            problems.append(f"{item.label} has no enclosure")
        if not item.signature:
            problems.append(f"{item.label}'s enclosure has no sparkle:edSignature")
        if item.length is None or not INTEGER.fullmatch(item.length):
            problems.append(f"{item.label}'s enclosure has no length")
        if item.channel is not None and item.channel != "beta":
            problems.append(f"{item.label} is on channel {item.channel!r}; the only channel is beta")
        if item.channel == "beta" and item.is_critical:
            problems.append(f"{item.label} is a beta marked critical")
        if item.build is None or not INTEGER.fullmatch(item.build):
            problems.append(f"{item.label}: sparkle:version {item.build!r} is not an integer")
            continue
        try:
            parsed = version.parse_version(item.short_version or "")
        except ValueError:
            problems.append(f"build {item.build}: shortVersionString {item.short_version!r} is not a release version")
            continue
        versions.setdefault(int(item.build), set()).add(parsed)

    ordered = []
    for build, found in sorted(versions.items()):
        if len(found) > 1:
            problems.append(f"build {build} carries {', '.join(sorted(str(each) for each in found))}")
        else:
            ordered.append((build, found.pop()))
    for (low_build, low), (high_build, high) in zip(ordered, ordered[1:]):
        if not low.build < high.build:
            problems.append(f"{high} has the higher build ({high_build} over {low_build}) but not the higher version")

    if expected is not None:
        release = expected.release
        channel = "beta" if release.is_beta else None
        if not any(item.build == str(release.build) and item.short_version == str(release)
                   and item.channel == channel and item.url == expected.url for item in items):
            problems.append(f"no {release.channel} item for {release} ({release.build}) at {expected.url}")
    return problems


def remove_items(text: str, short_version: str) -> Tuple[str, int]:
    items = parse_items(text.encode("utf-8"))
    spans = list(ITEM_TEXT.finditer(text))
    if len(spans) != len(items):
        raise FeedError(f"{APPCAST} has {len(items)} items but {len(spans)} <item> blocks in its text; edit it by hand")
    doomed = [span for span, item in zip(spans, items) if item.short_version == short_version]
    for span in reversed(doomed):
        text = text[:span.start()] + text[span.end():]
    left = [item for item in items if item.short_version != short_version]
    if parse_items(text.encode("utf-8")) != left:
        raise FeedError(f"removing {short_version} from the text of {APPCAST} changed other items; edit it by hand")
    return text, len(doomed)


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
        "--full-release-notes-url", f"https://github.com/{repository}/releases/tag/{tag}",
    ]
    if release.is_beta:
        command += ["--channel", "beta"]
    else:
        command += ["--phased-rollout-interval", str(PHASED_ROLLOUT_SECONDS)]
        if critical_build is not None:
            command += ["--critical-update-version", str(critical_build)]
    return command + [str(stage)]


def pluginkit_version(root: Path) -> int:
    path = root / PLUGINKIT_CONFIG
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise FeedError(f"{PLUGINKIT_CONFIG}: {error}") from error
    found = re.search(r"^TABLEPRO_PLUGINKIT_VERSION\s*=\s*([0-9]+)\s*$", text, re.MULTILINE)
    if found is None:
        raise FeedError(f"{PLUGINKIT_CONFIG} sets no TABLEPRO_PLUGINKIT_VERSION")
    return int(found.group(1))


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


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Releases:
    def __init__(self, repository: str, run: Callable = subprocess.run):
        self.repository = repository
        self._run = run

    def _gh(self, *args: str) -> str:
        result = self._run(["gh", *args, "--repo", self.repository], capture_output=True, text=True)
        if result.returncode != 0:
            raise FeedError(f"gh {' '.join(args[:3])}: {result.stderr.strip()}")
        return result.stdout

    def digests(self, tag: str) -> Dict[str, str]:
        release = json.loads(self._gh("release", "view", tag, "--json", "isDraft,assets"))
        if release.get("isDraft"):
            raise FeedError(f"{tag} is a draft; the feed only points at a published release")
        return {asset["name"]: asset.get("digest") or "" for asset in release.get("assets", [])}

    def download(self, tag: str, names: List[str], directory: Path) -> None:
        patterns = [argument for name in names for argument in ("--pattern", name)]
        self._gh("release", "download", tag, "--dir", str(directory), "--clobber", *patterns)


def fetch_assets(releases: Releases, tag: str, names: List[str], directory: Path) -> None:
    wanted = [name for name in names if not (directory / name).is_file()]
    if not wanted:
        return
    digests = releases.digests(tag)
    missing = [name for name in wanted if name not in digests]
    if missing:
        raise FeedError(f"{tag} has no {', '.join(missing)}")
    directory.mkdir(parents=True, exist_ok=True)
    releases.download(tag, wanted, directory)
    for name in wanted:
        path = directory / name
        if not path.is_file():
            raise FeedError(f"gh did not download {name} from {tag}")
        found = f"sha256:{_sha256(path)}"
        if digests[name] != found:
            path.unlink()
            raise FeedError(f"{name} downloaded as {found}, but {tag} lists {digests[name] or 'no digest'}")


def _git(root: Path, *args: str, run: Callable = subprocess.run, check: bool = True,
         env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
    result = run(["git", "-C", str(root), *args], capture_output=True, text=True,
                 env={**os.environ, **env} if env else None)
    if check and result.returncode != 0:
        raise FeedError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result


@contextmanager
def feeds_worktree(root: Path, run: Callable = subprocess.run) -> Iterator[Path]:
    _git(root, "fetch", "--quiet", "--no-tags", "origin", f"+refs/heads/{BRANCH}:{REMOTE_BRANCH}", run=run)
    parent = Path(tempfile.mkdtemp(prefix="feeds-"))
    tree = parent / BRANCH
    _git(root, "worktree", "add", "--quiet", "--detach", str(tree), REMOTE_BRANCH, run=run)
    try:
        yield tree
    finally:
        _git(root, "worktree", "remove", "--force", str(tree), run=run, check=False)
        shutil.rmtree(parent, ignore_errors=True)


def commit(tree: Path, message: str, run: Callable = subprocess.run) -> bool:
    paths = [path for path in (APPCAST, MANIFEST) if (tree / path).exists()]
    _git(tree, "add", "--", *paths, run=run)
    if _git(tree, "diff", "--cached", "--quiet", run=run, check=False).returncode == 0:
        return False
    identity = {f"GIT_{role}_{field}": value for role in ("AUTHOR", "COMMITTER")
                for field, value in (("NAME", BOT_NAME), ("EMAIL", BOT_EMAIL))}
    _git(tree, "commit", "--quiet", "-m", message, run=run, env=identity)
    return True


def push(tree: Path, run: Callable = subprocess.run) -> bool:
    result = _git(tree, "push", "--quiet", "origin", f"HEAD:refs/heads/{BRANCH}", run=run, check=False)
    if result.returncode == 0:
        return True
    # A rejected fast-forward or a lost ref lock means another run pushed first.
    if "[rejected]" in result.stderr or ("[remote rejected]" in result.stderr and "cannot lock ref" in result.stderr):
        return False
    raise FeedError(f"git push origin {BRANCH}: {result.stderr.strip()}")


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


def _refuse(problems: List[str]) -> None:
    if problems:
        raise FeedError("the feed fails its checks, so nothing was pushed:\n  " + "\n  ".join(problems))


def _publish(tree: Path, message: str, run: Callable, log: Callable[[str], None]) -> Optional[bool]:
    if not commit(tree, message, run):
        log(f"origin/{BRANCH} already has everything from '{message}'")
        return False
    if push(tree, run):
        log(f"pushed '{message}' to origin/{BRANCH}")
        return True
    return None


def add(root: Path, tag: str, build: int, channel: str, notes: Path, critical: bool, tools: Path, key: str,
        releases: Releases, repository: str, run: Callable = subprocess.run,
        log: Callable[[str], None] = print) -> bool:
    release = version.parse_tag(tag)
    if build != release.build or channel != release.channel:
        raise FeedError(f"{tag} is build {release.build} on {release.channel}, not build {build} on {channel}")
    if critical and release.is_beta:
        raise FeedError(f"{tag} is a beta, and a beta is never critical")
    if not notes.is_file():
        raise FeedError(f"{notes} does not exist")
    metadata = registry.load_metadata(root / METADATA)
    bundled = registry.bundled_targets((root / PROJECT).read_text(encoding="utf-8"))
    plugins = [f"{target}-{release}.zip" for target in registry.publish_set(metadata, bundled)]
    kit = pluginkit_version(root)
    archive = f"TablePro-{release}.tar.xz"
    url_base = f"https://github.com/{repository}/releases/download/{tag}/"
    expected = Expected(release, url_base + archive)

    with tempfile.TemporaryDirectory(prefix="feed-") as scratch:
        downloads = Path(scratch) / "downloads"
        entries = None
        for attempt in range(1, PUSH_ATTEMPTS + 1):
            wanted: Optional[Expected] = expected
            with feeds_worktree(root, run) as tree:
                appcast = tree / APPCAST
                if not appcast.is_file():
                    raise FeedError(f"origin/{BRANCH} has no {APPCAST}; seed the branch first (RELEASING.md)")
                previous = appcast.read_bytes()
                items = parse_items(previous)
                if appcast_has(items, release):
                    log(f"{APPCAST} already has {release} ({release.build})")
                else:
                    fetch_assets(releases, tag, [archive], downloads)
                    check_archive(downloads / archive, release)
                    stage = Path(scratch) / f"stage-{attempt}"
                    stage.mkdir()
                    shutil.copy2(downloads / archive, stage / archive)
                    shutil.copy2(notes, stage / f"TablePro-{release}.md")
                    shutil.copy2(appcast, stage / APPCAST)
                    critical_build = release.build if critical else None
                    if critical_build is None and not release.is_beta:
                        critical_build = carried_critical(items)
                    arguments = appcast_arguments(stage, tag, release, critical_build, repository)
                    log(_tool(tools, "generate_appcast", key, *arguments, run=run))
                    if appcast_has(parse_items((stage / APPCAST).read_bytes()), release):
                        shutil.copy2(stage / APPCAST, appcast)
                        # generate_appcast signs the feed only once an archive sets SURequireSignedFeed.
                        log(sign(appcast, key, tools, run))
                    else:
                        # The archive matched the tag, so only Sparkle's per-branch limit left it out.
                        log(f"generate_appcast keeps newer items on {release}'s branch, so {APPCAST} stays as it is")
                        wanted = None
                if entries is None:
                    fetch_assets(releases, tag, plugins, downloads)
                    entries = registry.describe(downloads, str(release), release.build, kit, metadata, bundled)
                registry.add(tree / MANIFEST, entries, release.channel, url_base, metadata["retainFromPluginKit"], log)
                _refuse(feed_problems(appcast.read_bytes(), previous, wanted)
                        + verify_signature(appcast, key, tools, run))
                pushed = _publish(tree, f"release: {tag}", run, log)
                if pushed is not None:
                    return pushed
            log(f"origin/{BRANCH} moved (attempt {attempt} of {PUSH_ATTEMPTS}); starting again from a fresh fetch")
    raise FeedError(f"origin/{BRANCH} moved during each of {PUSH_ATTEMPTS} attempts")


def withdraw(root: Path, text: str, tools: Path, key: str, run: Callable = subprocess.run,
             log: Callable[[str], None] = print) -> bool:
    release = version.parse_version(text)
    for attempt in range(1, PUSH_ATTEMPTS + 1):
        with feeds_worktree(root, run) as tree:
            appcast = tree / APPCAST
            previous = appcast.read_bytes()
            edited, removed = remove_items(previous.decode("utf-8"), str(release))
            if removed:
                if any(item.channel is None for item in parse_items(previous)) \
                        and not any(item.channel is None for item in parse_items(edited.encode("utf-8"))):
                    raise FeedError(f"withdrawing {release} would leave the feed with no default-channel item")
                appcast.write_text(edited, encoding="utf-8")
                log(sign(appcast, key, tools, run))
                log(f"removed {removed} {release} item(s) from {APPCAST}")
            else:
                log(f"{APPCAST} has no {release} item")
            if (tree / MANIFEST).exists():
                registry.withdraw(tree / MANIFEST, str(release), log)
            _refuse(feed_problems(appcast.read_bytes(), previous) + verify_signature(appcast, key, tools, run))
            pushed = _publish(tree, f"withdraw: v{release}", run, log)
            if pushed is not None:
                return pushed
        log(f"origin/{BRANCH} moved (attempt {attempt} of {PUSH_ATTEMPTS}); starting again from a fresh fetch")
    raise FeedError(f"origin/{BRANCH} moved during each of {PUSH_ATTEMPTS} attempts")


def check(root: Path, tools: Path, key: str, run: Callable = subprocess.run) -> List[str]:
    with feeds_worktree(root, run) as tree:
        appcast = tree / APPCAST
        if not appcast.is_file():
            return [f"origin/{BRANCH} has no {APPCAST}"]
        problems = feed_problems(appcast.read_bytes()) + verify_signature(appcast, key, tools, run)
        try:
            if registry.load_manifest(tree / MANIFEST) is None:
                problems.append(f"origin/{BRANCH} has no {MANIFEST}")
        except registry.RegistryError as error:
            problems.append(str(error))
    return problems


def published_items(root: Path, run: Callable = subprocess.run) -> List[Item]:
    _git(root, "fetch", "--quiet", "--no-tags", "origin", f"+refs/heads/{BRANCH}:{REMOTE_BRANCH}", run=run)
    result = run(["git", "-C", str(root), "show", f"{REMOTE_BRANCH}:{APPCAST}"], capture_output=True)
    if result.returncode != 0:
        raise FeedError(f"origin/{BRANCH} has no {APPCAST}: {result.stderr.decode(errors='replace').strip()}")
    return parse_items(result.stdout)


def _environment() -> Tuple[Path, str]:
    tools = os.environ.get("SPARKLE_BIN")
    key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not tools:
        raise FeedError("SPARKLE_BIN is not set; run the setup-sparkle action first")
    if not key:
        raise FeedError("SPARKLE_PRIVATE_KEY is not set")
    for name in ("generate_appcast", "sign_update"):
        if not os.access(Path(tools) / name, os.X_OK):
            raise FeedError(f"{tools} has no {name}")
    return Path(tools), key


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Writes the appcast and the plugin manifest on the feeds branch.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("add", help="add a published release to the feed and the manifest")
    command.add_argument("tag")
    command.add_argument("--build", type=int, required=True)
    command.add_argument("--channel", choices=registry.CHANNELS, required=True)
    command.add_argument("--notes", type=Path, required=True)
    command.add_argument("--critical", action="store_true")
    commands.add_parser("withdraw", help="remove a version from the feed and the manifest").add_argument("version")
    commands.add_parser("check", help="check the published feed")
    args = parser.parse_args(argv)

    repository = os.environ.get("GITHUB_REPOSITORY", version.REPOSITORY)
    try:
        tools, key = _environment()
        if args.command == "add":
            add(ROOT, args.tag, args.build, args.channel, args.notes, args.critical, tools, key,
                Releases(repository), repository)
        elif args.command == "withdraw":
            withdraw(ROOT, args.version, tools, key)
        else:
            problems = check(ROOT, tools, key)
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            if problems:
                return 1
            print(f"origin/{BRANCH} passes its checks")
    except (FeedError, registry.RegistryError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
