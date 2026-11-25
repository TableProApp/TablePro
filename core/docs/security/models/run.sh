#!/usr/bin/env bash
#
# Prove the sync key theories: one prover run per lemma, each under its own time limit and heap cap.
#
# Usage: run.sh [-t seconds] [-j jobs] [-m memory] [-o dir] [filter...]
#   -t  time limit per lemma, default 1200
#   -j  lemmas proved at once, default 1
#   -m  heap cap per prover, as GHC's -M takes it, default 3G
#   -o  where the prover's output for each lemma goes, default a new temporary folder
#   filter  keeps the lines of runs.txt that contain any filter given, such as a theory or a lemma name
#
# RUN_BEFORE_PROOF, when set, is a command run before each proof, such as one that waits for free memory.
#
# runs.txt lists every run: theory, flag ("-" for none), lemma and the expected result. Each run prints one line with
# the result, the prover's step count, the seconds it took and whether it matches the expected result. A result is
# verified, falsified, timeout, out-of-memory, stopped (a signal ended the prover) or error.
# Exit: 0 when every run matches, 1 otherwise.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
limit=1200
jobs=1
heap=3G
out=""

while getopts "t:j:m:o:" opt; do
    case "$opt" in
        t) limit="$OPTARG" ;;
        j) jobs="$OPTARG" ;;
        m) heap="$OPTARG" ;;
        o) out="$OPTARG" ;;
        *) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

command -v tamarin-prover > /dev/null || { echo "tamarin-prover is not installed: brew install tamarin-prover/tap/tamarin-prover" >&2; exit 2; }
[ -n "$out" ] || out="$(mktemp -d)"
mkdir -p "$out"

tamarin-prover --version 2>&1 | grep -m1 -o 'tamarin-prover [0-9.]*'
maude --version
echo "time limit ${limit}s and heap ${heap} per lemma, ${jobs} at once, output in $out"

runs="$out/runs.selected"
grep -v '^\s*#' "$here/runs.txt" | grep -v '^\s*$' > "$runs"
if [ $# -gt 0 ]; then
    patterns=()
    for f in "$@"; do patterns+=(-e "$f"); done
    grep -F "${patterns[@]}" "$runs" > "$runs.tmp"
    mv "$runs.tmp" "$runs"
fi

prove_one() {
    local theory=$1 flag=$2 lemma=$3 expected=$4
    local tag="${theory%.spthy}-${lemma}"
    local args=(--prove="$lemma" --derivcheck-timeout=0)
    if [ "$flag" != "-" ]; then
        args+=("-D=$flag")
        tag="$tag-$flag"
    fi
    local start end line result steps rc
    [ -z "${RUN_BEFORE_PROOF:-}" ] || sh -c "$RUN_BEFORE_PROOF"
    start=$(date +%s)
    # alarm kills only the prover's own process when the limit passes.
    perl -e 'alarm shift; exec @ARGV' "$LIMIT" tamarin-prover "$HERE/$theory" "${args[@]}" +RTS -M"$HEAP" -N2 -RTS > "$OUT/$tag.log" 2>&1
    rc=$?
    end=$(date +%s)
    line=$(grep -m1 -E "^  $lemma \((all-traces|exists-trace)\): " "$OUT/$tag.log")
    case "$line" in
        *": verified"*) result=verified ;;
        *": falsified"*) result=falsified ;;
        *)
            if grep -q -i 'heap overflow' "$OUT/$tag.log"; then
                result=out-of-memory
            elif [ "$rc" -eq 142 ]; then
                result=timeout
            elif [ "$rc" -gt 128 ]; then
                result=stopped
            else
                result=error
            fi
            ;;
    esac
    steps=$(printf '%s' "$line" | grep -o '([0-9]* steps)' | tr -d '()')
    local verdict=OK
    [ "$result" = "$expected" ] || verdict=DIFF
    printf '%-26s %-13s %-52s %-13s %-10s %5ss  %s\n' "$theory" "$flag" "$lemma" "$result" "${steps:--}" "$((end - start))" "$verdict"
}
export -f prove_one
export LIMIT="$limit" HEAP="$heap" HERE="$here" OUT="$out"

printf '%-26s %-13s %-52s %-13s %-10s %6s  %s\n' theory flag lemma result steps time expected
xargs -P "$jobs" -L 1 bash -c 'prove_one "$@"' _ < "$runs" | tee "$out/summary.txt"
! grep -q ' DIFF$' "$out/summary.txt"
