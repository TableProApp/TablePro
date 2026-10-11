#!/usr/bin/env bash
# Profile RowStore retention while GtkColumnView is scrolled through results.
# Run from anywhere with the local GTK/AT-SPI prerequisites installed:
#   bash scripts/profile-row-retention.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

target="${CARGO_TARGET_DIR:-$ROOT/target}"
rows_list="${TABLEPRO_PROFILE_ROWS_LIST:-10000 100000 300000}"
repetitions="${TABLEPRO_PROFILE_REPETITIONS:-3}"
scroll_steps="${TABLEPRO_PROFILE_SCROLL_STEPS:-1000}"
cell_bytes="${TABLEPRO_PROFILE_CELL_BYTES:-0}"
out="${TABLEPRO_PROFILE_OUT:-/tmp/bookie-row-retention-$(date +%Y%m%d-%H%M%S).jsonl}"

cargo build --release --locked -p tablepro-app --bin tablepro-app
install -Dm755 "$target/release/tablepro-app" "$target/installed/usr/bin/tablepro"
: > "$out"

for rows in $rows_list; do
  for repetition in $(seq 1 "$repetitions"); do
    TABLEPRO_PROFILE_ROWS="$rows" \
    TABLEPRO_PROFILE_REPETITION="$repetition" \
    TABLEPRO_PROFILE_SCROLL_STEPS="$scroll_steps" \
    TABLEPRO_PROFILE_CELL_BYTES="$cell_bytes" \
    TABLEPRO_PROFILE_OUT="$out" \
    TABLEPRO_GTK_SCENARIO=profile_large_result_in_the_grid \
    TABLEPRO_GTK_BINARY="$target/installed/usr/bin/tablepro" \
      bash scripts/test-gtk-safety.sh
  done
done

cat "$out"
