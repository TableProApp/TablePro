#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <remote-branch> <remote-branch>..." >&2
  exit 64
fi

root="$(git rev-parse --show-toplevel)"
work="$(mktemp -d)"
trap 'git -C "$root" worktree remove --force "$work" 2>/dev/null || true' EXIT
git -C "$root" fetch --quiet origin linux "$@"
git -C "$root" worktree add --quiet --detach "$work" "${FORGEJO_TRAIN_BASE:-origin/linux}"

merged=()
for branch in "$@"; do
  if git -C "$work" merge --quiet --no-ff -m "train: $branch" "origin/$branch" >/dev/null 2>&1; then
    merged+=("$branch")
  else
    git -C "$work" merge --abort
    echo "train: $branch conflicts with the train so far; gate it on its own" >&2
  fi
done
[ "${#merged[@]}" -gt 0 ] || { echo "train: nothing to gate" >&2; exit 1; }

sha="$(git -C "$work" rev-parse HEAD)"
git -C "$root" update-ref "refs/heads/train/gate" "$sha"
[ -z "${FORGEJO_TRAIN_DRY:-}" ] || { echo "train: dry run, would gate ${merged[*]} ($sha)"; exit 0; }
echo "train: gating ${merged[*]} as one run ($sha)"
cd "$root"
scripts/forgejo-gate.sh train/gate "train/$(date +%m%d-%H%M)"
echo "train passed for: ${merged[*]}"
