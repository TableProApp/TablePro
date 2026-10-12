#!/usr/bin/env python3
"""Withdraws a released version from the Sparkle feed.

Removing an item from appcast.xml is how a Sparkle release is withdrawn. There is no API for it
and no other mechanism, so the only question is whether the operator has a rehearsed tool or edits
a 640 KB XML file by hand under time pressure.

This became necessary the moment updates started installing without being accepted first. Before
that a bad build was contained by the user, who saw a dialog and could decline it. Phased rollout
bounds the first wave, but it does not stop the cohorts behind it.

The GitHub Release is deliberately left in place: people who downloaded the DMG directly still
need their link to resolve, and the corrective release is what supersedes the build. Only the feed
entry goes, so no updater offers it again.

The items are removed with the same primitives merge-appcast.py uses to insert them, so the two
cannot disagree about where an item begins and ends.

The push target is checked rather than assumed. SUFeedURL names main, so a withdrawal pushed to
any other branch leaves every install downloading the bad build while this script reports success.
`git push origin HEAD` from one of this repo's worktrees did exactly that.

Run: python3 scripts/ci/pull-release.py 0.75.0 [--dry-run] [--feed appcast.xml] [--no-push]
"""

import argparse
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from appcast_feed import (  # noqa: E402
    FeedError,
    channel_items,
    item_short_version,
    parse_text,
    read,
    remove_version,
)


PUBLISHED_BRANCH = "main"


def git(*arguments, check=True):
    return subprocess.run(["git", *arguments], check=check, capture_output=True, text=True)


def checked_out_branch():
    """The current branch name, or None on a detached HEAD."""
    result = git("symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    return result.stdout.strip() or None


def require_publishable_checkout():
    """The feed every install polls is `main`, so nothing else may be pushed as a withdrawal."""
    branch = checked_out_branch()
    if branch is None:
        raise FeedError(
            "HEAD is detached, so there is no branch to push. Check out "
            f"{PUBLISHED_BRANCH} and run this again"
        )
    if branch != PUBLISHED_BRANCH:
        raise FeedError(
            f"on branch {branch!r}, but SUFeedURL serves {PUBLISHED_BRANCH}. Pushing here would "
            f"report the build withdrawn while every install kept downloading it. Check out "
            f"{PUBLISHED_BRANCH} and run this again"
        )
    return branch


def withdraw(feed_path, version):
    """Returns (new_text, removed_count). Raises FeedError when the result would be wrong."""
    text = read(feed_path)
    before = channel_items(parse_text(text), feed_path)
    if not any(item_short_version(item) == version for item in before):
        raise FeedError(f"{feed_path} does not advertise {version}, so there is nothing to withdraw")

    result, removed = remove_version(text, feed_path, version)
    after = channel_items(parse_text(result), feed_path)
    if len(after) != len(before) - removed:
        raise FeedError("removing the items changed the number of other items in the feed")
    if any(item_short_version(item) == version for item in after):
        raise FeedError(f"{version} is still advertised after the removal")
    if not after:
        raise FeedError(
            f"withdrawing {version} would empty the feed, and an empty feed tells every install "
            "it is up to date forever"
        )
    return result, removed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("version", help="the marketing version to withdraw, without the leading v")
    parser.add_argument("--feed", default="appcast.xml", help="path to the feed (default: appcast.xml)")
    parser.add_argument("--dry-run", action="store_true", help="report what would change, write nothing")
    parser.add_argument("--no-push", action="store_true", help="commit but do not push")
    args = parser.parse_args(argv)

    try:
        if not args.dry_run and not args.no_push:
            require_publishable_checkout()
        result, removed = withdraw(args.feed, args.version)
    except FeedError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    remaining = channel_items(parse_text(result), args.feed)
    newest = item_short_version(remaining[0])
    print(f"{args.version}: {removed} item(s) to remove, {len(remaining)} left, newest becomes {newest}")

    if args.dry_run:
        print("dry run, nothing written")
        return 0

    pathlib.Path(args.feed).write_text(result, encoding="utf-8")

    status = git("status", "--porcelain", "--", args.feed)
    if not status.stdout.strip():
        print(f"{args.feed} is unchanged on disk, nothing to commit")
        return 0

    git("add", "--", args.feed)
    git("commit", "-m", f"release: withdraw v{args.version} from the update feed")
    if args.no_push:
        print("committed, not pushed")
        return 0

    push = git("push", "origin", f"HEAD:{PUBLISHED_BRANCH}", check=False)
    if push.returncode != 0:
        print(push.stdout, file=sys.stderr)
        print(push.stderr, file=sys.stderr)
        print("error: the commit is local; push it before telling anyone the build is pulled", file=sys.stderr)
        return 1
    print(f"withdrawn: v{args.version} is no longer offered to any install")
    return 0


if __name__ == "__main__":
    sys.exit(main())
