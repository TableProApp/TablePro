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
#   worktree.sh <branch>            # new branch off a freshly fetched origin/main
#   worktree.sh <branch> <base>     # new branch off an explicit base
#   worktree.sh --remove <branch>   # remove a clean worktree, keeping the branch
#   worktree.sh --prune-merged [--dry-run]
#                                   # remove every clean worktree whose pull requests are all
#                                   # merged or closed, with its DerivedData folder
#
# Prints the worktree path on success. Pass it to verify.sh as --root.

set -uo pipefail

# The main checkout, even when this script runs from a worktree's copy of the skill: the common git
# directory is shared by every worktree and sits inside the main checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(cd "$SCRIPT_DIR" && git rev-parse --path-format=absolute --git-common-dir)" || exit 1
MAIN_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
WORKTREE_HOME="$MAIN_ROOT/.claude/worktrees"

usage() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 3
}

[ $# -ge 1 ] || usage
case "$1" in
    -h | --help) usage ;;
esac

# A worktree is only reclaimed when nothing can be lost: every pull request for its branch is
# merged or closed, `git status` is empty, and no process has its working directory inside it.
# Each one holds about 7 GB of DerivedData, and a full disk has stopped sessions mid-build.
prune_merged() {
    local dry_run="$1" finished cwds dir branch derived plist
    finished="$(gh pr list --repo TableProApp/TablePro --state all --limit 2000 --json headRefName,state \
        --jq 'group_by(.headRefName)[] | select(all(.[]; .state != "OPEN")) | .[0].headRefName')" \
        || { echo "could not list pull requests; nothing removed" >&2; exit 1; }
    cwds="$(lsof -a -d cwd -Fn 2> /dev/null | sed -n 's/^n//p')"

    while IFS=$'\t' read -r dir branch; do
        case "$dir" in "$WORKTREE_HOME"/*) ;; *) continue ;; esac
        grep -qxF -- "$branch" <<< "$finished" || continue
        if [ -n "$(git -C "$dir" status --porcelain 2> /dev/null)" ]; then
            echo "kept, uncommitted changes: $dir"
            continue
        fi
        if printf '%s\n' "$cwds" | awk -v d="$dir" '$0 == d || index($0, d "/") == 1 { found = 1 } END { exit !found }'; then
            echo "kept, a process is working in it: $dir"
            continue
        fi
        derived=""
        for plist in "$HOME"/Library/Developer/Xcode/DerivedData/TablePro-*/info.plist; do
            [ -f "$plist" ] || continue
            case "$(/usr/libexec/PlistBuddy -c 'Print WorkspacePath' "$plist" 2> /dev/null)" in
                "$dir"/*) derived="$(dirname "$plist")" ;;
            esac
        done
        if [ "$dry_run" = 1 ]; then
            echo "would remove: $dir${derived:+ and $derived}"
            continue
        fi
        git -C "$MAIN_ROOT" worktree remove "$dir" || { echo "kept, git refused: $dir"; continue; }
        [ -n "$derived" ] && rm -rf "$derived"
        echo "removed: $dir${derived:+ and $derived}"
    done < <(git -C "$MAIN_ROOT" worktree list --porcelain | awk '
        /^worktree / { dir = substr($0, 10) }
        /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch); print dir "\t" branch }')

    [ "$dry_run" = 1 ] || git -C "$MAIN_ROOT" worktree prune
}

if [ "$1" = "--prune-merged" ]; then
    dry_run=0
    [ "${2:-}" = "--dry-run" ] && dry_run=1
    prune_merged "$dry_run"
    exit 0
fi

if [ "$1" = "--remove" ]; then
    [ $# -ge 2 ] || usage
    target="$WORKTREE_HOME/${2//\//-}"
    # Never --force: it deletes uncommitted work in the tree along with the tree.
    if ! git -C "$MAIN_ROOT" worktree remove "$target"; then
        echo "not removed: $target has uncommitted or untracked changes. Commit them, or remove it by hand." >&2
        exit 1
    fi
    git -C "$MAIN_ROOT" worktree prune
    echo "removed $target"
    exit 0
fi

BRANCH="$1"
BASE="${2:-}"
# A fix branch starts from what main is now, not from whatever the main checkout has checked out.
if [ -z "$BASE" ]; then
    git -C "$MAIN_ROOT" fetch --quiet origin main || { echo "could not fetch origin main" >&2; exit 1; }
    BASE="origin/main"
fi
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
# Libs/ios/checksums.sha256 is tracked, so git already created Libs/ios as a real directory and
# a symlink named after it would land inside as Libs/ios/ios. Link the xcframeworks themselves.
mkdir -p "$DIR/Libs/ios"
for framework in "$MAIN_ROOT"/Libs/ios/*.xcframework; do
    [ -e "$framework" ] && ln -sfn "$framework" "$DIR/Libs/ios/$(basename "$framework")"
done
link "$MAIN_ROOT/Native/DamengBridge/lib" "$DIR/Native/DamengBridge/lib"
link "$MAIN_ROOT/Native/HanaBridge/bin" "$DIR/Native/HanaBridge/bin"

missing=""
[ -e "$DIR/Configs/Secrets.xcconfig" ] || missing="$missing Configs/Secrets.xcconfig"
[ -e "$DIR/Libs/dylibs" ] || missing="$missing Libs/dylibs"
[ -e "$DIR/Native/DamengBridge/lib" ] || missing="$missing Native/DamengBridge/lib"
[ -e "$DIR/Native/HanaBridge/bin" ] || missing="$missing Native/HanaBridge/bin"
ls "$DIR"/Libs/*.a > /dev/null 2>&1 || missing="$missing Libs/*.a"
ls "$DIR"/Libs/ios/*.xcframework > /dev/null 2>&1 || missing="$missing Libs/ios/*.xcframework"
if [ -n "$missing" ]; then
    echo "warning: not linked, the main checkout does not have them:$missing" >&2
fi

echo "$DIR"
echo "note: Libs/dylibs shows as untracked here because its .gitignore entry ends in a slash and it is a symlink. Stage explicit paths." >&2
