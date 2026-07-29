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
cargo clippy --all-targets -- -D warnings

echo "==> cargo build --workspace"
cargo build --workspace

echo "==> cargo test --workspace --lib --bins"
# --bins matters: tablepro-app has no lib.rs, so --lib alone skips its tests.
cargo test --workspace --lib --bins

echo "All fast checks passed."
echo "Driver integration tests are a separate CI job; see docs/testing.md to run them locally."
