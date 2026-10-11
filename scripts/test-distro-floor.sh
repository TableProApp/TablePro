#!/usr/bin/env bash
# Build and test the GTK crate on the oldest supported distro stacks.
# Usage: bash scripts/test-distro-floor.sh [ubuntu:24.04|debian:13 ...]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
images=("$@")
[ ${#images[@]} -gt 0 ] || images=(ubuntu:24.04 debian:13)

for base in "${images[@]}"; do
  tag="bookie-floor-${base//[:\/]/-}"
  echo "== $base"
  offset=19
  [ "$base" = ubuntu:24.04 ] && offset=5
  docker build -q -t "$tag" --build-arg "BASE=$base" scripts/distro-floor >/dev/null
  docker run --rm -e DISTRO_FLOOR_INSTALLED="${DISTRO_FLOOR_INSTALLED:-0}" -e TABLEPRO_GTK_Y_OFFSET="${TABLEPRO_GTK_Y_OFFSET:-$offset}" -e TABLEPRO_GTK_OLD_ADW=1 ${TABLEPRO_GTK_WAIT_SECONDS:+-e TABLEPRO_GTK_WAIT_SECONDS="$TABLEPRO_GTK_WAIT_SECONDS"} ${TABLEPRO_GTK_SCENARIO_RETRIES:+-e TABLEPRO_GTK_SCENARIO_RETRIES="$TABLEPRO_GTK_SCENARIO_RETRIES"} -v "$PWD:/src:ro" -v "${tag}-target:/target" -v "${tag}-cargo:/opt/cargo/registry" -v "${tag}-git:/opt/cargo/git" -e CARGO_TARGET_DIR=/target "$tag" bash -ceu -o pipefail '
    pkg-config --modversion gtk4 libadwaita-1 gtksourceview-5
    cargo test --manifest-path /src/Cargo.toml -p tablepro-app --lib 2>&1 | grep -E -A1 "^test result|FAILED|failed|panicked" | sed -n 1,60p
    bash /src/scripts/test-gtk-widgets.sh 2>&1 | tail -4
    if [ "${DISTRO_FLOOR_INSTALLED:-0}" = 1 ]; then
      status=0
      bash /src/scripts/test-gtk-safety.sh >/tmp/gtk-safety.log 2>&1 || status=$?
      grep -aE "^passed:|^AssertionError|^  File .*gtk_[a-z]*\.py\", line [0-9]+, in " /tmp/gtk-safety.log | tail -14
      echo "installed GTK suite exit status: $status"
      [ "$status" = 0 ]
    fi
  '
done
