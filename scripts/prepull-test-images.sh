#!/usr/bin/env bash
set -euo pipefail

group=${1:?usage: prepull-test-images.sh <group>}
list=${PREPULL_IMAGE_LIST:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci/test-images.txt"}
backoff=${PREPULL_BACKOFF_SECONDS:-5}

mapfile -t images < <(awk -v group="$group" '$1 == group { print $2 }' "$list")
if [ "${#images[@]}" -eq 0 ]; then
  echo "no test images listed for group '$group' in $list" >&2
  exit 1
fi

failed=()
for image in "${images[@]}"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    continue
  fi
  pulled=0
  for attempt in 1 2 3; do
    if docker pull --quiet "$image" >/dev/null; then
      pulled=1
      break
    fi
    echo "pull of $image failed (attempt $attempt of 3)" >&2
    sleep $((backoff * attempt))
  done
  [ "$pulled" -eq 1 ] || failed+=("$image")
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "could not pull: ${failed[*]}" >&2
  exit 1
fi
