#!/usr/bin/env bash
#
# Create an isolated worktree that can actually build.
#
# A fresh TablePro worktree fails before compiling until four untracked, gitignored paths are
# linked from the main checkout. The first failure is "Unable to open base configuration reference
# file", which reads like a broken toolchain. Symlinks work fine for the linker, so this beats
# re-running scripts/download-libs.sh per worktree.
#
# Usage:
#   worktree.sh <branch>            # new branch off the current main checkout's HEAD
#   worktree.sh <branch> <base>     # new branch off an explicit base
#   worktree.sh --remove <branch>   # remove the worktree, keeping the branch
#
# Prints the worktree path on success. Pass it to verify.sh as --root.

set -uo pipefail

MAIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORKTREE_HOME="$MAIN_ROOT/.claude/worktrees"

usage() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 3
}

[ $# -ge 1 ] || usage
case "$1" in
    -h | --help) usage ;;
esac

if [ "$1" = "--remove" ]; then
    [ $# -ge 2 ] || usage
    target="$WORKTREE_HOME/${2//\//-}"
    git -C "$MAIN_ROOT" worktree remove "$target" 2> /dev/null || git -C "$MAIN_ROOT" worktree remove --force "$target"
    git -C "$MAIN_ROOT" worktree prune
    echo "removed $target"
    exit 0
fi

BRANCH="$1"
BASE="${2:-HEAD}"
DIR="$WORKTREE_HOME/${BRANCH//\//-}"

if [ -e "$DIR" ]; then
    echo "already exists: $DIR" >&2
    exit 1
fi

mkdir -p "$WORKTREE_HOME"
git -C "$MAIN_ROOT" worktree add -b "$BRANCH" "$DIR" "$BASE" || exit 1

link() {
    [ -e "$1" ] || return 0
    ln -sfn "$1" "$2"
}

# The build reads Configs/Secrets.xcconfig. A stale empty Secrets.xcconfig at the repo root
# used to be linked instead, so every fresh worktree failed with "Unable to open base
# configuration reference file" until it was linked by hand.
link "$MAIN_ROOT/Configs/Secrets.xcconfig" "$DIR/Configs/Secrets.xcconfig"
mkdir -p "$DIR/Libs"
for archive in "$MAIN_ROOT"/Libs/*.a; do
    [ -e "$archive" ] && ln -sf "$archive" "$DIR/Libs/$(basename "$archive")"
done
link "$MAIN_ROOT/Libs/dylibs" "$DIR/Libs/dylibs"
link "$MAIN_ROOT/Libs/ios" "$DIR/Libs/ios"
link "$MAIN_ROOT/Native/DamengBridge/lib" "$DIR/Native/DamengBridge/lib"

missing=""
[ -e "$DIR/Configs/Secrets.xcconfig" ] || missing="$missing Configs/Secrets.xcconfig"
[ -e "$DIR/Libs/dylibs" ] || missing="$missing Libs/dylibs"
[ -e "$DIR/Native/DamengBridge/lib" ] || missing="$missing Native/DamengBridge/lib"
ls "$DIR"/Libs/*.a > /dev/null 2>&1 || missing="$missing Libs/*.a"
if [ -n "$missing" ]; then
    echo "warning: not linked, the main checkout does not have them:$missing" >&2
fi

echo "$DIR"
echo "note: Libs/dylibs and Libs/ios show as untracked here because the .gitignore entries end in a slash and these are symlinks. Stage explicit paths." >&2
