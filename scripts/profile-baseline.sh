#!/usr/bin/env bash
# Performance baseline for large results. Run on the Arch runner from the repository root:
#   bash scripts/profile-baseline.sh
# Prints driver-level time and peak memory, an allocation profile, binary size by crate,
# and the real app's memory with a large result in the grid (needs Xvfb, D-Bus and AT-SPI).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
target="${CARGO_TARGET_DIR:-$PWD/target}"

echo "== driver level: rows returned, time, peak memory"
cargo build --release -q -p tablepro-driver-sqlite --example materialize_profile
for rows in 10000 100000 500000 1000000; do
  /usr/bin/time -f 'wall_s=%e maxrss_kb=%M' "$target/release/examples/materialize_profile" "$rows" 2>&1 | tr '\n' ' '
  echo
done

echo "== allocation profile at 100000 rows"
(cd /tmp && heaptrack -o /tmp/heaptrack.profile "$target/release/examples/materialize_profile" 100000 >/dev/null 2>&1)
heaptrack_print /tmp/heaptrack.profile.zst 2>/dev/null |
  grep -E '^(calls to allocation functions|temporary memory allocations|peak heap memory consumption)'

echo "== binary size by crate"
ls -l "$target/release/tablepro-app" | awk '{print "binary_bytes=" $5}'
cargo bloat --release -p tablepro-app --crates -n 12 2>&1 | sed -n '3,16p'

echo "== app memory with a large result in the grid"
out="$(mktemp)"
for rows in 10000 100000 300000 1000000; do
  TABLEPRO_PROFILE_ROWS="$rows" TABLEPRO_PROFILE_OUT="$out" TABLEPRO_GTK_SCENARIO=profile_large_result_in_the_grid \
    TABLEPRO_GTK_BUILD_PROFILE=release bash scripts/test-gtk-safety.sh >/dev/null 2>&1
done
cat "$out"
