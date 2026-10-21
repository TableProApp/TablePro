#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <remote-branch> <remote-branch>..." >&2
  exit 64
fi

root="$(git rev-parse --show-toplevel)"
original_head="$(git -C "$root" rev-parse HEAD)"
if [ -n "$(git -C "$root" status --porcelain)" ]; then
  echo "train: current checkout must be clean" >&2
  exit 1
fi

restore_checkout() {
  local result=$?
  trap - EXIT
  git -C "$root" merge --abort >/dev/null 2>&1 || true
  if ! git -C "$root" reset --hard "$original_head" >/dev/null; then
    echo "train: failed to restore the original checkout at $original_head" >&2
    exit 1
  fi
  exit "$result"
}
trap restore_checkout EXIT

bookie_remote() {
  if [ -n "${FORGEJO_TRAIN_REMOTE:-}" ]; then
    printf '%s\n' "$FORGEJO_TRAIN_REMOTE"
    return
  fi
  git -C "$root" remote -v | awk '$3 == "(fetch)" && $2 ~ /github\.com[:\/]cozyGarage\/BookiE(\.git)?$/ { print $1; exit }'
}

remote="$(bookie_remote)"
if [ -z "$remote" ]; then
  echo "train: no remote tracks github.com/cozyGarage/BookiE; set FORGEJO_TRAIN_REMOTE to the one that does" >&2
  exit 1
fi

git -C "$root" fetch --quiet "$remote" linux "$@"
git -C "$root" reset --hard "${FORGEJO_TRAIN_BASE:-$remote/linux}" >/dev/null

merged=()
for branch in "$@"; do
  if ! git -C "$root" merge --quiet --no-ff -m "train: $branch" "$remote/$branch" >/dev/null 2>&1; then
    git -C "$root" merge --abort
    echo "train: $branch conflicts with the train so far; stop and resolve the conflict" >&2
    exit 1
  fi
  merged+=("$branch")
done
[ "${#merged[@]}" -gt 0 ] || { echo "train: nothing to gate" >&2; exit 1; }

format_union_merges() {
  (cd "$root" && cargo fmt --all)
  local changed outside
  changed="$(git -C "$root" diff --name-only)"
  [ -n "$changed" ] || return 0
  outside="$(printf '%s\n' "$changed" | git -C "$root" check-attr --stdin merge | awk -F': ' '$3 != "union" { print $1 }')"
  if [ -n "$outside" ]; then
    echo "train: a merged branch is not formatted; gate it on its own to find which:" >&2
    printf '%s\n' "$outside" | sed 's/^/  /' >&2
    return 1
  fi
  git -C "$root" commit --quiet -am "train: format union-merged files"
}
format_union_merges

sha="$(git -C "$root" rev-parse HEAD)"
target="train/$sha"
[ -z "${FORGEJO_TRAIN_DRY:-}" ] || { echo "train: dry run, would gate ${merged[*]} ($sha)"; exit 0; }
echo "train: gating ${merged[*]} as one run ($sha)"
cd "$root"
scripts/forgejo-gate.sh "$sha" "$target"
echo "train passed for: ${merged[*]}"
