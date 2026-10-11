#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/dev-env.sh"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
exec python3 "$ROOT/scripts/test-value-contracts.py" "$@"
