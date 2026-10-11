#!/usr/bin/env bash
# Local CI mirror for the repository.
#
# Modes:
#   ./scripts/ci-local.sh           # default: full fast checks (GTK included)
#   ./scripts/ci-local.sh quick     # alias for ./scripts/preflight.sh (no GTK app)
#   ./scripts/ci-local.sh full      # fmt + clippy + build + unit tests (GTK)
#   ./scripts/ci-local.sh integration  # driver docker integration tests
#   ./scripts/ci-local.sh release      # automated gates; manual package/soak approval remains separate
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-full}"
if [[ "${BOOKIE_CI_REPORT_ACTIVE:-0}" != 1 ]]; then
  export BOOKIE_CI_REPORT_ACTIVE=1
  exec python3 "$ROOT/scripts/ci-report.py" "$MODE" bash "$0" "$MODE"
fi

if [[ -f "$ROOT/scripts/dev-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/dev-env.sh"
fi

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
case "$CARGO_TARGET_DIR" in
  /tmp/*) export CARGO_TARGET_DIR="$ROOT/target" ;;
esac

run_full() {
  bash scripts/test-harness.sh
  echo "==> file size guardrail"
  "$ROOT/scripts/check-file-size.sh"

  echo "==> bounded database operations in the GUI"
  "$ROOT/scripts/check-bounded-operations.sh"

  echo "==> panic sites in production code"
  "$ROOT/scripts/check-panic-sites.sh"

  echo "==> function sizes"
  python3 scripts/check-function-size.py

  echo "==> cargo fmt --check"
  cargo fmt --all -- --check

  echo "==> cargo clippy"
  cargo clippy --workspace --exclude tablepro-driver-duckdb --all-targets -- -D warnings

  echo "==> cargo test --workspace --lib --bins"
  # Compiling tests already builds the crates; a separate `cargo build`
  # beforehand doubles wall time for little signal.
  # DuckDB is optional (--features duckdb) and expensive to compile.
  cargo test --workspace --exclude tablepro-driver-duckdb --lib --bins

  echo "==> sandbox integration tier"
  "$ROOT/scripts/test-sandbox.sh"

  echo "Full fast checks passed."
  echo "Driver integration: ./scripts/ci-local.sh integration"
}

run_integration() {
  export TABLEPRO_TEST_RUN_ID="ci-${$}-${RANDOM}"
  cleanup_testcontainers() {
    python3 "$ROOT/scripts/cleanup-testcontainers.py" "$TABLEPRO_TEST_RUN_ID"
  }
  trap cleanup_testcontainers EXIT
  trap 'cleanup_testcontainers; exit 143' TERM
  trap 'cleanup_testcontainers; exit 130' INT
  echo "==> SQL and document/key-value driver integration"
  cargo test --locked --test integration \
    -p tablepro-driver-postgres -p tablepro-driver-mysql -p tablepro-driver-mssql \
    -p tablepro-driver-clickhouse -p tablepro-driver-redis -p tablepro-driver-mongodb \
    -- --include-ignored --test-threads=1
  cargo test --locked -p tablepro-mcp --test mongodb_extended_json -- --include-ignored --test-threads=1
  cargo test --locked -p tablepro-policy --test session_postgres -- --include-ignored --test-threads=1
  cargo test --locked -p tablepro-policy --test session_mssql -- --include-ignored --test-threads=1
  echo "==> PostgreSQL Unix-socket integration"
  ./scripts/test-postgres-socket.sh
  bash ./scripts/test-ssh.sh
  echo "Integration checks passed."
}

run_release() {
  run_full
  bash "$ROOT/scripts/test-gtk-widgets.sh"
  run_integration
  python3 scripts/run-isolated-tests.py app-server
  "$ROOT/scripts/test-driver-tls.sh"
  "$ROOT/scripts/test-secret-service.sh"
  echo "==> PostgreSQL release fixture"
  "$ROOT/scripts/test-postgres-release.sh"
  echo "==> Installed GTK safety flows"
  "$ROOT/scripts/test-gtk-safety.sh"
  echo "==> ClickHouse Enum16 GTK edit"
  python3 scripts/run-test-layer.py gtk-clickhouse
  echo "==> MySQL-backed GTK approval dialog"
  python3 scripts/run-test-layer.py gtk-mysql-approval
  echo "==> MongoDB-backed GTK cursor and edit contract"
  python3 scripts/run-test-layer.py gtk-mongodb
  cargo test --locked -p tablepro-driver-duckdb
  cargo build --locked -p tablepro-app --features duckdb
  cargo deny check
  cargo audit
  echo "Automated release gates passed. Package install/upgrade/rollback, Wayland and candidate soak remain separate."
}

case "$MODE" in
  quick | preflight)
    exec "$ROOT/scripts/preflight.sh"
    ;;
  full | "")
    run_full
    ;;
  integration)
    run_integration
    ;;
  widgets)
    bash "$ROOT/scripts/test-gtk-widgets.sh"
    ;;
  release)
    run_release
    ;;
  *)
    echo "usage: $0 [quick|full|widgets|integration|release]" >&2
    exit 2
    ;;
esac
