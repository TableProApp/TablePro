#!/usr/bin/env bash
# Fast local gate before a full GTK build or .deb/.flatpak package.
# Intentionally skips tablepro-app (GTK) so you get signal in seconds-to-minutes
# instead of waiting on a full UI link.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/scripts/dev-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/dev-env.sh"
fi

# Keep builds on disk; agent environments sometimes point CARGO_TARGET_DIR at tmpfs.
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
  tablepro-driver-postgres
  tablepro-driver-mysql
  tablepro-driver-sqlite
  tablepro-driver-mssql
  tablepro-driver-clickhouse
  tablepro-driver-redis
  tablepro-driver-mongodb
  tablepro-release-tests
  tablepro-driver-tls-tests
)

PKG_ARGS=()
for c in "${CRATES[@]}"; do
  PKG_ARGS+=(-p "$c")
done

echo "==> script harness"
bash scripts/test-harness.sh

echo "==> file size guardrail"
"$ROOT/scripts/check-file-size.sh"

echo "==> bounded database operations in the GUI"
"$ROOT/scripts/check-bounded-operations.sh"

echo "==> panic sites in production code"
"$ROOT/scripts/check-panic-sites.sh"

echo "==> function sizes"
python3 scripts/check-function-size.py

echo "==> comment lines"
python3 scripts/check-comment-lines.py

echo "==> cargo fmt --check (workspace)"
cargo fmt --all -- --check

echo "==> cargo clippy (non-GTK crates)"
cargo clippy "${PKG_ARGS[@]}" --all-targets -- -D warnings

echo "==> cargo test --lib (non-GTK crates)"
cargo test "${PKG_ARGS[@]}" --lib

echo "==> sandbox integration tier"
"$ROOT/scripts/test-sandbox.sh"

echo "Preflight passed. Next:"
echo "  ./scripts/ci-local.sh        # full workspace incl. GTK app"
echo "  ./scripts/build-deb.sh       # only when you need a local package"
