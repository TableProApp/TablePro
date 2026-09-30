#!/usr/bin/env python3
"""Fail when currentPluginKitVersion has moved more than one past the newest release tag.

Only the value at release time ever ships, so every PluginKit change in one release cycle reuses
the number the first one took. The registry keeps binaries for the three newest kit versions, and
each extra bump pushes one more shipped release out of that window: v0.74.0 shipped kit 30, two
bumps before v0.75.0 took main to 32, and the next registry publish at kit 33 kept 31 to 33, which
left v0.74.0 with nothing to install.

The newest release is the highest vX.Y.Z tag by version number. With --remote the tag list comes
from that remote and the one tag is fetched when it is missing, so a shallow CI checkout with no tags
works. The fetch is at depth 1 only in a checkout that is already shallow: in a full clone it would
cut the history every worktree shares down to that one commit.
test_check_pluginkit_bump_cadence.py pins what it must and must not report.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN_MANAGER = "TablePro/Core/Plugins/PluginManager.swift"
KIT_DECLARATION = re.compile(r"\bstatic\s+let\s+currentPluginKitVersion\s*=\s*(\d+)\b")
RELEASE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"ERROR: git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def kit_version(source: str, origin: str) -> int:
    match = KIT_DECLARATION.search(source)
    if match is None:
        raise SystemExit(f"ERROR: no currentPluginKitVersion declaration in {origin}")
    return int(match.group(1))


def newest_release_tag(names: list[str]) -> str | None:
    releases = [
        (tuple(int(part) for part in match.groups()), name)
        for name in names
        if (match := RELEASE_TAG.match(name))
    ]
    return max(releases)[1] if releases else None


def local_tag_names(repo: Path) -> list[str]:
    return git(repo, "tag", "--list", "v*").split()


def remote_tag_names(repo: Path, remote: str) -> list[str]:
    output = git(repo, "ls-remote", "--tags", "--refs", remote, "refs/tags/v*")
    return [line.split("refs/tags/", 1)[1] for line in output.splitlines() if "refs/tags/" in line]


def has_commit(repo: Path, ref: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--quiet", "--verify", f"{ref}^{{commit}}"],
        capture_output=True,
    )
    return result.returncode == 0


def fetch_tag(repo: Path, remote: str, tag: str) -> None:
    if has_commit(repo, f"refs/tags/{tag}"):
        return
    shallow = git(repo, "rev-parse", "--is-shallow-repository").strip() == "true"
    depth = ["--depth=1"] if shallow else []
    git(repo, "fetch", "--quiet", "--no-tags", *depth, remote, f"+refs/tags/{tag}:refs/tags/{tag}")


def cadence_violation(tag: str, released: int, current: int) -> str | None:
    if current <= released + 1:
        return None
    return (
        f"currentPluginKitVersion is {current}, but {tag} shipped {released}. It moves at most once "
        f"per release cycle, so every PluginKit change until the next release reuses {released + 1}."
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--remote", help="read the release tags from this remote and fetch the newest")
    args = parser.parse_args(argv)

    names = remote_tag_names(args.repo, args.remote) if args.remote else local_tag_names(args.repo)
    tag = newest_release_tag(names)
    if tag is None:
        raise SystemExit("ERROR: no vX.Y.Z release tag to compare currentPluginKitVersion against")
    if args.remote:
        fetch_tag(args.repo, args.remote, tag)

    released = kit_version(git(args.repo, "show", f"{tag}:{PLUGIN_MANAGER}"), f"{tag}:{PLUGIN_MANAGER}")
    current_path = args.repo / PLUGIN_MANAGER
    current = kit_version(current_path.read_text(encoding="utf-8"), PLUGIN_MANAGER)

    violation = cadence_violation(tag, released, current)
    if violation:
        print(violation, file=sys.stderr)
        return 1
    print(f"currentPluginKitVersion {current}; {tag} shipped {released}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
