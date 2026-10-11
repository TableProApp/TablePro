#!/usr/bin/env bash
#
# Measure the Data Files engine on generated CSV files.
#
# Compiles the TableProTabularIO and TableProTabular package sources with -O into one
# executable, generates CSV files of the requested sizes with a fixed seed, and prints wall and
# CPU time for opening, filtering, searching and sorting each one. Run it on a quiet machine:
# wall time under load says more about other processes than about the engine.
#
# Usage:
#   scripts/benchmark-data-files.sh [size-in-MB …]     # default: 100 1024
#   KEEP_DATA=1 scripts/benchmark-data-files.sh 100      # keep the generated files

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE="$ROOT/scripts/benchmark/data-files"
PACKAGE="$ROOT/Packages/TableProCore/Sources"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/data-files-benchmark.XXXXXX")"

cleanup() {
    if [ "${KEEP_DATA:-0}" = "1" ]; then
        echo "kept $WORK"
        return
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

clang -O2 -o "$WORK/gencsv" "$HERE/gencsv.c"

compile_module() {
    local name="$1"
    shift
    xcrun swiftc -O -wmo -parse-as-library -emit-library -emit-module -module-name "$name" \
        -I "$WORK" -L "$WORK" "$@" \
        -emit-module-path "$WORK/$name.swiftmodule" -o "$WORK/lib$name.dylib" 2>> "$WORK/compile.log"
}

if ! compile_module TableProTabularIO "$PACKAGE"/TableProTabularIO/*.swift \
    || ! compile_module TableProTabular -lTableProTabularIO "$PACKAGE"/TableProTabular/*.swift \
    || ! xcrun swiftc -O -parse-as-library -module-name DataFilesBenchmark -I "$WORK" -L "$WORK" \
        -lTableProTabularIO -lTableProTabular -Xlinker -rpath -Xlinker "$WORK" \
        "$HERE/main.swift" -o "$WORK/benchmark" 2>> "$WORK/compile.log"; then
    cat "$WORK/compile.log" >&2
    exit 1
fi

sizes=("$@")
if [ "${#sizes[@]}" -eq 0 ]; then
    sizes=(100 1024)
fi

for size in "${sizes[@]}"; do
    file="$WORK/data-${size}m.csv"
    "$WORK/gencsv" "$file" $((size * 1024 * 1024))
    "$WORK/benchmark" "$file"
    rm -f "$file"
done
