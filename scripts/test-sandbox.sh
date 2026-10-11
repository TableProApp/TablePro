#!/usr/bin/env bash
# Sandbox regression tier: every integration target that needs no Docker,
# no database service, and no GTK display. Targets are selected with
# `--tests` so a newly added integration file is gated the moment it lands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/scripts/dev-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/dev-env.sh"
fi

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
case "$CARGO_TARGET_DIR" in
  /tmp/*) export CARGO_TARGET_DIR="$ROOT/target" ;;
esac

CRATES=(
  tablepro-core
  tablepro-policy
  tablepro-storage
  tablepro-transport
  tablepro-ssh
  tablepro-mcp
  tablepro-agentd
  tablepro-driver-sqlite
)

PKG_ARGS=()
for c in "${CRATES[@]}"; do
  PKG_ARGS+=(-p "$c")
done

echo "==> sandbox tier: cargo test --tests"
cargo test "${PKG_ARGS[@]}" --tests
cargo test -p tablepro-driver-redis --test cancellation
