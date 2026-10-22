#!/usr/bin/env python3

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional, Tuple

import notes

REPOSITORY = "TableProApp/TablePro"
MAX_MINOR = 999
MAX_PATCH = 99
MAX_BETA = 98
STABLE_RANK = 99
MAX_LEAD_LINES = 6

# [0-9], not \d: \d also matches non-ASCII digits.
GRAMMAR = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-beta\.(0|[1-9][0-9]*))?")

CI_WORKFLOW = ".github/workflows/ci.yml"
# A job of a called workflow is named "<ci.yml job> / <its own job>".
TEST_JOBS = ("macos / macOS Tests", "ios / iOS and Package Tests")
DETECTOR = "scripts/ci/detect-changed-paths.sh"
SHIPPED = "shipped"
FRAGMENTS = "changelog.d/"


@dataclass(frozen=True)
class Version:
    major: int
    minor: int
    patch: int
    beta: Optional[int] = None

    @property
    def is_beta(self) -> bool:
        return self.beta is not None

    @property
    def channel(self) -> str:
        return "beta" if self.is_beta else "stable"

    @property
    def line(self) -> str:
        return f"{self.major}.{self.minor}"

    @property
    def build(self) -> int:
        rank = self.beta if self.beta is not None else STABLE_RANK
        return ((self.major * 1000 + self.minor) * 100 + self.patch) * 100 + rank

    @property
    def tag(self) -> str:
        return f"v{self}"

    def __str__(self) -> str:
        text = f"{self.major}.{self.minor}.{self.patch}"
        return f"{text}-beta.{self.beta}" if self.beta is not None else text


def parse_version(text: str) -> Version:
    match = GRAMMAR.fullmatch(text)
    if not match:
        raise ValueError(f"{text!r} is not X.Y.Z or X.Y.0-beta.N")
    major, minor, patch = (int(group) for group in match.group(1, 2, 3))
    beta = int(match.group(4)) if match.group(4) is not None else None
    if minor > MAX_MINOR:
        raise ValueError(f"{text}: MINOR is above {MAX_MINOR}")
    if patch > MAX_PATCH:
        raise ValueError(f"{text}: PATCH is above {MAX_PATCH}")
    if beta is not None and not 1 <= beta <= MAX_BETA:
        raise ValueError(f"{text}: the beta number is outside 1 to {MAX_BETA}")
    if beta is not None and patch != 0:
        raise ValueError(f"{text}: a beta exists only on PATCH 0")
    return Version(major, minor, patch, beta)


def parse_tag(tag: str) -> Version:
    if not tag.startswith("v"):
        raise ValueError(f"{tag!r} does not start with v")
    return parse_version(tag[1:])


def try_parse_tag(tag: str) -> Optional[Version]:
    try:
        return parse_tag(tag)
    except ValueError:
        return None


def has_heading(changelog: str, version: Version) -> bool:
    return re.search(rf"^## \[{re.escape(str(version))}\]", changelog, re.MULTILINE) is not None


class Git:
    def __init__(self, root: Path, run: Callable = subprocess.run):
        self.root = root
        self._run = run

    def _git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        result = self._run(["git", "-C", str(self.root), *args], capture_output=True, text=True)
        if check and result.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()}")
        return result

    def commit(self, ref: str) -> str:
        return self._git("rev-parse", "--verify", f"{ref}^{{commit}}").stdout.strip()

    def exists(self, ref: str) -> bool:
        return self._git("rev-parse", "--quiet", "--verify", f"{ref}^{{commit}}", check=False).returncode == 0

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        result = self._git("merge-base", "--is-ancestor", ancestor, descendant, check=False)
        if result.returncode not in (0, 1):
            raise RuntimeError(f"git merge-base {ancestor} {descendant}: {result.stderr.strip()}")
        return result.returncode == 0

    def tags(self, pattern: str) -> List[str]:
        return self._git("tag", "--list", pattern).stdout.split()

    def tags_at(self, commit: str, pattern: str) -> List[str]:
        return self._git("tag", "--points-at", commit, "--list", pattern).stdout.split()

    def show(self, ref: str, path: str) -> Optional[str]:
        result = self._git("show", f"{ref}:{path}", check=False)
        return result.stdout if result.returncode == 0 else None

    def list_tree(self, ref: str, path: str) -> List[str]:
        return self._git("ls-tree", "--name-only", ref, "--", path).stdout.splitlines()


@dataclass(frozen=True)
class Run:
    id: str
    path: str
    status: str
    conclusion: str
    url: str


class GitHub:
    def __init__(self, repository: str = REPOSITORY, run: Callable = subprocess.run):
        self.repository = repository
        self._run = run

    def _api(self, path: str, jq: str, paginate: bool = False) -> List[str]:
        command = ["gh", "api", *(["--paginate"] if paginate else []), path, "--jq", jq]
        result = self._run(command, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"gh api {path}: {result.stderr.strip()}")
        return result.stdout.splitlines()

    def releases(self) -> List[Tuple[str, bool]]:
        lines = self._api(f"repos/{self.repository}/releases?per_page=100",
                          ".[] | [.tag_name, .draft] | @tsv", paginate=True)
        return [(tag, draft == "true") for tag, draft in (line.split("\t") for line in lines if line)]

    def push_runs(self, sha: str, branch: str) -> List[Run]:
        lines = self._api(f"repos/{self.repository}/actions/runs?head_sha={sha}&event=push&branch={branch}"
                          "&per_page=100",
                          ".workflow_runs[] | [.id, .path, .status, .conclusion // \"\", .html_url] | @tsv")
        return [Run(*line.split("\t")) for line in lines if line]

    def job_conclusions(self, run_id: str, job: str) -> List[str]:
        return self._api(f"repos/{self.repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100",
                         f".jobs[] | select(.name == \"{job}\") | .conclusion // \"\"", paginate=True)


def detector(root: Path, run: Callable = subprocess.run) -> Callable[[str, str, str], bool]:
    def changed(base: str, head: str, suite: str) -> bool:
        result = run([str(root / DETECTOR), "--base", base, "--head", head, suite],
                     cwd=root, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"{DETECTOR} --base {base} --head {head} {suite}: {result.stderr.strip()}")
        return result.stdout.strip() != "false"

    return changed


def published_stables(releases: List[Tuple[str, bool]]) -> List[Version]:
    versions = [try_parse_tag(tag) for tag, draft in releases if not draft]
    return [version for version in versions if version is not None and not version.is_beta]


def published_betas(releases: List[Tuple[str, bool]], line: str) -> List[Version]:
    versions = [try_parse_tag(tag) for tag, draft in releases if not draft]
    return [version for version in versions if version is not None and version.is_beta and version.line == line]


def previous_on_line(git: Git, version: Version) -> Optional[Version]:
    earlier = [
        candidate for candidate in (try_parse_tag(tag) for tag in git.tags(f"v{version.line}.*"))
        if candidate is not None and candidate.line == version.line and candidate.build < version.build
    ]
    return max(earlier, key=lambda candidate: candidate.build) if earlier else None


def branch_errors(git: Git, version: Version) -> List[str]:
    tag = version.tag
    branch = f"origin/release/{version.line}"
    errors = []
    if not git.exists(branch):
        errors.append(f"{branch} does not exist")
    elif not git.is_ancestor(tag, branch):
        errors.append(f"{tag} is not reachable from {branch}")
    previous = previous_on_line(git, version)
    if previous is not None and not git.is_ancestor(previous.tag, tag):
        errors.append(f"{previous.tag}, the previous tag on {version.line}, is not an ancestor of {tag}")
    return errors


def shared_commit_errors(git: Git, version: Version) -> List[str]:
    others = [tag for tag in git.tags_at(git.commit(version.tag), "v*") if tag != version.tag]
    if not others:
        return []
    return [f"{version.tag} is on the same commit as {', '.join(others)}: one v* tag per commit"]


def beta_errors(git: Git, version: Version, releases: List[Tuple[str, bool]]) -> List[str]:
    stable_zero = Version(version.major, version.minor, 0)
    if version.is_beta:
        if git.exists(f"refs/tags/{stable_zero.tag}"):
            return [f"{stable_zero.tag} is already tagged, so no beta of it can follow"]
        return []
    if version.patch != 0 or published_betas(releases, version.line):
        return []
    return [f"{version.tag} needs a published {version.tag}-beta.N release first"]


def earlier_stables(git: Git, version: Version) -> List[Version]:
    tags = (try_parse_tag(tag) for tag in git.tags(f"v{version.line}.*"))
    return [tag for tag in tags
            if tag is not None and not tag.is_beta and tag.line == version.line and tag.build < version.build]


def stable_tree_errors(git: Git, version: Version, releases: List[Tuple[str, bool]],
                       changed: Callable[[str, str, str], bool]) -> List[str]:
    betas = published_betas(releases, version.line)
    if version.is_beta or not betas:
        return []
    newest = max(betas, key=lambda beta: beta.build)
    # No beta can follow a stable tag, so a fix after one that matched the beta ships as a patch.
    if any(not changed(newest.tag, stable.tag, SHIPPED) for stable in earlier_stables(git, version)):
        return []
    if not changed(newest.tag, version.tag, SHIPPED):
        return []
    return [f"{version.tag} changes shipped source since {newest.tag}, the newest published beta: "
            f"revert that on release/{version.line}, then tag the next number"]


def changelog_errors(changelog: Optional[str], version: Version, stables: List[Version]) -> List[str]:
    if changelog is None:
        return [f"CHANGELOG.md is missing at {version.tag}"]
    errors = []
    if version.is_beta:
        stable_zero = Version(version.major, version.minor, 0)
        if has_heading(changelog, stable_zero):
            errors.append(f"CHANGELOG.md at {version.tag} already has ## [{stable_zero}]")
    elif not has_heading(changelog, version):
        errors.append(f"CHANGELOG.md at {version.tag} has no ## [{version}]")

    lines = sorted({(stable.major, stable.minor) for stable in stables})
    own = (version.major, version.minor)
    below = [line for line in lines if line < own]
    covered = {own, below[-1]} if below else {own}
    for stable in sorted(stables, key=lambda candidate: candidate.build):
        if (stable.major, stable.minor) in covered and stable.build < version.build \
                and not has_heading(changelog, stable):
            errors.append(f"CHANGELOG.md at {version.tag} has no ## [{stable}]: forward-port that release first")
    return errors


# With a lead, the Sparkle notes, What's New and the Telegram post show only the lead.
def lead_errors(changelog: Optional[str], version: Version) -> List[str]:
    if changelog is None or version.is_beta:
        return []
    section = notes.find_section(changelog, str(version))
    if section is None or not section.lead:
        return []
    where = f"CHANGELOG.md at {version.tag}"
    errors = []
    if version.patch != 0:
        errors.append(f"{where}: ## [{version}] has a lead, and only an X.Y.0 takes one")
    if len(section.lead) > MAX_LEAD_LINES:
        errors.append(f"{where}: the {version} lead has {len(section.lead)} lines, over {MAX_LEAD_LINES}")
    errors += [f"{where}: the {version} lead line `{line}` is not plain text"
               for line in section.lead if line.startswith(("#", "- "))]
    return errors


def fragment_errors(paths: List[str], version: Version) -> List[str]:
    if version.is_beta:
        return []
    fragments = [Path(path).name for path in paths if Path(path).name != ".gitkeep"]
    if not fragments:
        return []
    return [f"{version.tag} still has {', '.join(fragments)} in {FRAGMENTS}; assemble again on the line head"]


def run_errors(github: GitHub, run: Run) -> List[str]:
    if run.status != "completed":
        return [f"CI is {run.status} at {run.url}: re-run Verify once it is green"]
    if run.conclusion != "success":
        return [f"CI ended '{run.conclusion}' at {run.url}"]
    errors = []
    for job in TEST_JOBS:
        conclusions = github.job_conclusions(run.id, job)
        if conclusions != ["success"]:
            errors.append(f"{job} ran no tests at {run.url} (job: {', '.join(conclusions) or 'none'})")
    return errors


def push_run_errors(github: GitHub, sha: str, line: str) -> List[str]:
    branch = f"release/{line}"
    runs = [run for run in github.push_runs(sha, branch) if run.path == CI_WORKFLOW]
    if not runs:
        return [f"no CI push run on {branch} at {sha}"]
    return [error for run in runs for error in run_errors(github, run)]


def check(tag: str, git: Git, github: GitHub, changed: Callable[[str, str, str], bool]) -> List[str]:
    try:
        version = parse_tag(tag)
    except ValueError as error:
        return [str(error)]
    if not git.exists(f"refs/tags/{tag}"):
        return [f"tag {tag} does not exist here"]
    releases = github.releases()
    errors = branch_errors(git, version)
    errors += shared_commit_errors(git, version)
    errors += beta_errors(git, version, releases)
    errors += stable_tree_errors(git, version, releases, changed)
    changelog = git.show(tag, "./CHANGELOG.md")
    errors += changelog_errors(changelog, version, published_stables(releases))
    errors += lead_errors(changelog, version)
    errors += fragment_errors(git.list_tree(tag, FRAGMENTS), version)
    if errors:
        return errors
    return push_run_errors(github, git.commit(tag), version.line)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Release tag grammar, build number and pre-build checks.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("parse", help="print version, build, channel and line as key=value").add_argument("tag")
    commands.add_parser("check", help="refuse a tag that must not build").add_argument("tag")
    args = parser.parse_args(argv)

    if args.command == "parse":
        try:
            version = parse_tag(args.tag)
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        print(f"version={version}\nbuild={version.build}\nchannel={version.channel}\nline={version.line}")
        return 0

    # Git runs in apple/, so ./ paths and ls-tree read the Apple changelog; the detector is repo-wide.
    apple = Path(__file__).resolve().parents[2]
    repository = os.environ.get("GITHUB_REPOSITORY", REPOSITORY)
    try:
        errors = check(args.tag, Git(apple), GitHub(repository), detector(apple.parent))
    except RuntimeError as error:
        errors = [str(error)]
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if not errors:
        print(f"{args.tag} can build")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
