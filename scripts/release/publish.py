#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional

import feed
import version

ROOT = Path(__file__).resolve().parent.parent.parent
FIND_ATTEMPTS = 5
FIND_DELAY_SECONDS = 2


class PublishError(Exception):
    pass


def draft_action(is_published: bool, has_draft: bool) -> str:
    if is_published:
        return "published"
    return "reuse" if has_draft else "create"


def should_be_latest(release: version.Version, latest_tag: Optional[str]) -> bool:
    if release.is_beta:
        return False
    latest = version.try_parse_tag(latest_tag) if latest_tag else None
    return latest is None or release.build > latest.build


def release_flags(release: version.Version, latest_tag: Optional[str]) -> List[str]:
    flags = ["--draft=false"]
    if release.is_beta:
        return flags + ["--prerelease", "--latest=false"]
    return flags + [f"--latest={'true' if should_be_latest(release, latest_tag) else 'false'}"]


def highest_stable(items: List[feed.Item]) -> Optional[version.Version]:
    stables = []
    for item in items:
        if item.channel is not None:
            continue
        parsed = version.try_parse_tag(f"v{item.short_version}") if item.short_version else None
        if parsed is not None and not parsed.is_beta:
            stables.append(parsed)
    return max(stables, key=lambda candidate: candidate.build) if stables else None


def asset_problems(files: Dict[str, str], assets: List[dict]) -> List[str]:
    found = {asset.get("name"): asset for asset in assets}
    problems = []
    for name, digest in sorted(files.items()):
        asset = found.get(name)
        if asset is None:
            problems.append(f"the release has no {name}")
        elif asset.get("state") != "uploaded":
            problems.append(f"{name} is {asset.get('state')}, not uploaded")
        elif asset.get("digest") != f"sha256:{digest}":
            found_digest = asset.get("digest") or "missing its digest"
            problems.append(f"{name} is {found_digest} on GitHub but sha256:{digest} here")
    return problems


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class GitHub:
    def __init__(self, repository: str, run: Callable = subprocess.run):
        self.repository = repository
        self._run = run

    def _gh(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        result = self._run(["gh", *args], capture_output=True, text=True)
        if check and result.returncode != 0:
            raise PublishError(f"gh {' '.join(args[:3])}: {result.stderr.strip()}")
        return result

    def _release(self, *args: str) -> List[str]:
        return ["release", *args, "--repo", self.repository]

    def is_published(self, tag: str) -> bool:
        result = self._gh("api", f"repos/{self.repository}/releases/tags/{tag}", "--jq", ".draft", check=False)
        if result.returncode == 0:
            return result.stdout.strip() == "false"
        if "HTTP 404" in result.stderr:
            return False
        raise PublishError(f"gh api releases/tags/{tag}: {result.stderr.strip()}")

    # gh races its published and draft lookups, so this runs only once no published release holds the tag.
    def draft(self, tag: str) -> Optional[dict]:
        result = self._gh(*self._release("view", tag, "--json", "isDraft,assets"), check=False)
        if result.returncode != 0:
            if "release not found" in result.stderr:
                return None
            raise PublishError(f"gh release view {tag}: {result.stderr.strip()}")
        release = json.loads(result.stdout)
        if not release.get("isDraft"):
            raise PublishError(f"{tag} was published while this ran")
        return release

    def create_draft(self, tag: str, notes: Path, files: List[Path], prerelease: bool) -> None:
        self._gh(*self._release("create", tag, "--draft", "--verify-tag", "--title", tag, "--notes-file", str(notes),
                                f"--prerelease={'true' if prerelease else 'false'}", *[str(path) for path in files]))

    def update_draft(self, tag: str, notes: Path, files: List[Path], prerelease: bool) -> None:
        self._gh(*self._release("edit", tag, "--title", tag, "--notes-file", str(notes),
                                f"--prerelease={'true' if prerelease else 'false'}"))
        self._gh(*self._release("upload", tag, "--clobber", *[str(path) for path in files]))

    def edit(self, tag: str, flags: List[str]) -> None:
        self._gh(*self._release("edit", tag, *flags))

    def latest_tag(self) -> Optional[str]:
        result = self._gh("api", f"repos/{self.repository}/releases/latest", "--jq", ".tag_name", check=False)
        if result.returncode == 0:
            return result.stdout.strip() or None
        if "HTTP 404" in result.stderr:
            return None
        raise PublishError(f"gh api releases/latest: {result.stderr.strip()}")


def draft(github: GitHub, tag: str, notes: Path, files: List[Path], sleep: Callable[[float], None] = time.sleep,
          log: Callable[[str], None] = print) -> str:
    parsed = version.parse_tag(tag)
    missing = [str(path) for path in [notes, *files] if not path.is_file()]
    if missing:
        raise PublishError(f"{', '.join(missing)} does not exist")
    names = [path.name for path in files]
    if len(set(names)) != len(names):
        raise PublishError("two assets share a file name")

    published = github.is_published(tag)
    existing = None if published else github.draft(tag)
    action = draft_action(published, existing is not None)
    if action == "published":
        log(f"{tag} is already published")
        return "published"
    if action == "create":
        github.create_draft(tag, notes, files, parsed.is_beta)
        log(f"created the draft for {tag}")
    else:
        github.update_draft(tag, notes, files, parsed.is_beta)
        log(f"reused the draft an earlier attempt left for {tag}")

    current = None
    for _ in range(FIND_ATTEMPTS):
        current = github.draft(tag)
        if current is not None:
            break
        sleep(FIND_DELAY_SECONDS)
    if current is None:
        raise PublishError(f"the draft for {tag} was created but cannot be found")
    problems = asset_problems({path.name: _sha256(path) for path in files}, current.get("assets", []))
    if problems:
        raise PublishError(f"the draft for {tag} does not hold this build, so it stays unpublished:\n  "
                           + "\n  ".join(problems))
    log(f"the draft for {tag} holds all {len(files)} assets")
    return "draft"


def release(github: GitHub, tag: str, log: Callable[[str], None] = print) -> None:
    parsed = version.parse_tag(tag)
    if github.is_published(tag):
        log(f"{tag} is already published")
        return
    if github.draft(tag) is None:
        raise PublishError(f"{tag} has no draft; run publish.py draft first")
    flags = release_flags(parsed, github.latest_tag())
    github.edit(tag, flags)
    log(f"published {tag} ({' '.join(flags[1:])})")


def latest(github: GitHub, items: List[feed.Item], log: Callable[[str], None] = print) -> str:
    highest = highest_stable(items)
    if highest is None:
        raise PublishError("the feed has no stable item")
    github.edit(highest.tag, ["--latest=true"])
    log(f"{highest.tag} is Latest")
    return highest.tag


def _stderr(message: str) -> None:
    print(message, file=sys.stderr)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Drafts, publishes and marks GitHub releases.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("draft", help="put every asset on a draft and check its digests")
    command.add_argument("tag")
    command.add_argument("--notes", type=Path, required=True)
    command.add_argument("files", type=Path, nargs="+")
    commands.add_parser("release", help="publish the draft").add_argument("tag")
    commands.add_parser("latest", help="mark the highest stable left in the feed as Latest")
    args = parser.parse_args(argv)

    github = GitHub(os.environ.get("GITHUB_REPOSITORY", version.REPOSITORY))
    try:
        if args.command == "draft":
            print(f"state={draft(github, args.tag, args.notes, args.files, log=_stderr)}")
        elif args.command == "release":
            release(github, args.tag, _stderr)
        else:
            latest(github, feed.published_items(ROOT), _stderr)
    except (PublishError, feed.FeedError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
