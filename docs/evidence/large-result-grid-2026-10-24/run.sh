#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
EVIDENCE="$ROOT/docs/evidence/large-result-grid-2026-10-24"
BINARY="${TABLEPRO_GTK_BINARY:-$ROOT/target/installed-ci/usr/bin/tablepro}"
RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/bookie-stream-pager.XXXXXX")"
mkdir -p "$RUNTIME/runtime" "$EVIDENCE/screenshots"
chmod 0700 "$RUNTIME/runtime"
cleanup() {
  if command -v fusermount3 >/dev/null 2>&1; then
    for mount in "$RUNTIME/runtime/doc" "$RUNTIME/runtime/gvfs"; do
      fusermount3 -uz -- "$mount" >/dev/null 2>&1 || true
    done
  fi
  rm -rf -- "$RUNTIME"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$RUNTIME/runtime"
export TABLEPRO_PROFILE_REPO="$ROOT"
export TABLEPRO_GTK_ARTIFACT_DIR="$EVIDENCE/screenshots"
export TABLEPRO_GTK_BINARY="$BINARY"
export TABLEPRO_GTK_SCENARIO=profile_large_result_in_the_grid
export TABLEPRO_GTK_SCENARIO_RETRIES=0
export TABLEPRO_PROFILE_SCROLL_STEPS=1000
export TABLEPRO_GTK_KEYRING_READY=1
export ATSPI_DBUS_IMPLEMENTATION=dbus-daemon
unset NO_AT_BRIDGE

dbus-run-session -- xvfb-run --auto-servernum \
  --server-args="-screen 0 1280x1024x24 -nolisten tcp" \
  bash "$EVIDENCE/capture-session.sh"
