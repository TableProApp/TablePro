#!/usr/bin/env bash
# Mirror .github/workflows/build-linux.yml "Fast checks" job locally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/scripts/dev-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/dev-env.sh"
fi

echo "==> cargo fmt --check"
cargo fmt --all -- --check

echo "==> cargo clippy"
cargo clippy --workspace --all-targets -- -D warnings

echo "==> cargo build --workspace --locked"
cargo build --workspace --locked

echo "==> GTK_A11Y=test dbus-run-session -- cargo test --workspace --locked"
GTK_A11Y=test dbus-run-session -- cargo test --workspace --locked

echo "All fast checks passed."
echo "Docker tests run per package in a separate CI job; see docs/testing.md to run them locally."
