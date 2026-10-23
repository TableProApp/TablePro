#!/usr/bin/env bash
# Build and test the GTK crate on the supported distro stack.
# Usage: bash scripts/test-distro-floor.sh [debian:testing ...]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
images=("$@")
[ ${#images[@]} -gt 0 ] || images=(debian:testing)

for base in "${images[@]}"; do
  tag="bookie-floor-${base//[:\/]/-}"
  echo "== $base"
  package_mount=()
  package_env=()
  build_mounts=()
  build_environment=()
  if [ -n "${DISTRO_FLOOR_PACKAGE:-}" ]; then
    test -s "$DISTRO_FLOOR_PACKAGE"
    package_mount=(-v "$(dirname "$(realpath "$DISTRO_FLOOR_PACKAGE")"):/package:ro")
    package_env=(-e "DISTRO_FLOOR_DEB_NAME=$(basename "$DISTRO_FLOOR_PACKAGE")")
    dockerfile=scripts/distro-floor/Dockerfile.runtime
  else
    dockerfile=scripts/distro-floor/Dockerfile
    build_mounts=(-v "${tag}-target:/target" -v "${tag}-cargo:/opt/cargo/registry" -v "${tag}-git:/opt/cargo/git")
    build_environment=(-e CARGO_TARGET_DIR=/target)
  fi
  docker build -q -t "$tag" --build-arg "BASE=$base" -f "$dockerfile" scripts/distro-floor >/dev/null
  docker run --rm "${package_mount[@]}" "${package_env[@]}" -e DISTRO_FLOOR_INSTALLED="${DISTRO_FLOOR_INSTALLED:-0}" ${TABLEPRO_GTK_Y_OFFSET:+-e TABLEPRO_GTK_Y_OFFSET="$TABLEPRO_GTK_Y_OFFSET"} ${TABLEPRO_GTK_WAIT_SECONDS:+-e TABLEPRO_GTK_WAIT_SECONDS="$TABLEPRO_GTK_WAIT_SECONDS"} ${TABLEPRO_GTK_SCENARIO_RETRIES:+-e TABLEPRO_GTK_SCENARIO_RETRIES="$TABLEPRO_GTK_SCENARIO_RETRIES"} -v "$PWD:/src:ro" "${build_mounts[@]}" "${build_environment[@]}" "$tag" bash -ceu -o pipefail '
    if [ -n "${DISTRO_FLOOR_DEB_NAME:-}" ]; then
      apt-get update -qq
      apt-get install -y -qq "/package/$DISTRO_FLOOR_DEB_NAME" >/dev/null
      status=0
      TABLEPRO_GTK_BINARY=/usr/bin/bookie bash /src/scripts/test-gtk-safety.sh >/tmp/gtk-safety.log 2>&1 || status=$?
      if [ "$status" -ne 0 ]; then
        bash /src/scripts/report-gtk-failure.sh /tmp/gtk-safety.log "$status"
      fi
      grep -aE "^passed:|^gtk: .*executed successfully" /tmp/gtk-safety.log | tail -14
    else
      pkg-config --modversion gtk4 libadwaita-1 gtksourceview-5
      cargo test --manifest-path /src/Cargo.toml -p tablepro-app --lib 2>&1 | grep -E -A1 "^test result|FAILED|failed|panicked" | sed -n 1,60p
      if bash /src/scripts/test-gtk-widgets.sh >/tmp/gtk-widgets.log 2>&1; then
        tail -4 /tmp/gtk-widgets.log
      else
        cat /tmp/gtk-widgets.log
        exit 1
      fi
      if [ "${DISTRO_FLOOR_INSTALLED:-0}" = 1 ]; then
        status=0
        bash /src/scripts/test-gtk-safety.sh >/tmp/gtk-safety.log 2>&1 || status=$?
        if [ "$status" -ne 0 ]; then
          bash /src/scripts/report-gtk-failure.sh /tmp/gtk-safety.log "$status"
        fi
        grep -aE "^passed:|^gtk: .*executed successfully" /tmp/gtk-safety.log | tail -14
      fi
    fi
  '
done
