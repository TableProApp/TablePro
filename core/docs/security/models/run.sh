#!/usr/bin/env bash
#
# Prove the sync key theories: one prover run per lemma, each under its own time limit.
#
# Usage: run.sh [-t seconds] [-j jobs] [-o dir] [filter...]
#   -t  time limit per lemma, default 1200
#   -j  lemmas proved at once, default 4
#   -o  where the prover's output for each lemma goes, default a new temporary folder
#   filter  keeps the lines of runs.txt that contain any filter given, such as a theory or a lemma name
#
# runs.txt lists every run: theory, flag ("-" for none), lemma and the expected result. Each run prints one line
# with the result (verified, falsified, timeout, or error when the prover stopped early), the prover's step count,
# the seconds it took and whether it matches the expected result.
# Exit: 0 when every run matches, 1 otherwise.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
limit=1200
jobs=4
out=""

while getopts "t:j:o:" opt; do
    case "$opt" in
        t) limit="$OPTARG" ;;
        j) jobs="$OPTARG" ;;
        o) out="$OPTARG" ;;
        *) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

command -v tamarin-prover > /dev/null || { echo "tamarin-prover is not installed: brew install tamarin-prover/tap/tamarin-prover" >&2; exit 2; }
[ -n "$out" ] || out="$(mktemp -d)"
mkdir -p "$out"

tamarin-prover --version 2>&1 | grep -m1 -o 'tamarin-prover [0-9.]*'
maude --version
echo "time limit ${limit}s per lemma, ${jobs} at once, output in $out"

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
    local start end line result steps
    start=$(date +%s)
    # alarm kills only the prover's own process when the limit passes.
    perl -e 'alarm shift; exec @ARGV' "$LIMIT" tamarin-prover "$HERE/$theory" "${args[@]}" > "$OUT/$tag.log" 2>&1
    end=$(date +%s)
    line=$(grep -m1 -E "^  $lemma \((all-traces|exists-trace)\): " "$OUT/$tag.log")
    case "$line" in
        *": verified"*) result=verified ;;
        *": falsified"*) result=falsified ;;
        *) if [ $((end - start)) -ge "$LIMIT" ]; then result=timeout; else result=error; fi ;;
    esac
    steps=$(printf '%s' "$line" | grep -o '([0-9]* steps)' | tr -d '()')
    local verdict=OK
    [ "$result" = "$expected" ] || verdict=DIFF
    printf '%-26s %-13s %-52s %-9s %-10s %5ss  %s\n' "$theory" "$flag" "$lemma" "$result" "${steps:--}" "$((end - start))" "$verdict"
}
export -f prove_one
export LIMIT="$limit" HERE="$here" OUT="$out"

printf '%-26s %-13s %-52s %-9s %-10s %6s  %s\n' theory flag lemma result steps time expected
xargs -P "$jobs" -L 1 bash -c 'prove_one "$@"' _ < "$runs" | tee "$out/summary.txt"
! grep -q ' DIFF$' "$out/summary.txt"
