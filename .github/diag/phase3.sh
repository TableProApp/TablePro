#!/bin/bash
set -u
OUT="$1"
echo "== heaviest stacks of the long frontends"
python3 .github/diag/stacks.py "$OUT"
python3 .github/diag/pick.py "$OUT" > "$OUT/picked.tsv"
cat "$OUT/picked.tsv"
nocache_argv=""
while IFS=$'\t' read -r file argv probe seconds status; do
  [ -n "$file" ] || continue
  control=$(( seconds * 3 / 2 + 60 ))
  [ "$control" -gt 1500 ] && control=1500
  work="/tmp/bisect-$(basename "$file" .swift)"
  echo "== bisect $file (replayed ${seconds}s $status), probe $(basename "$probe")"
  if [ -z "$nocache_argv" ]; then
    python3 -u .github/diag/declbisect.py "$argv" "$file" --nocache --probe "$probe" --control "$control" --work "$work" < /dev/null
    code=$?
    if [ "$code" -eq 3 ]; then
      echo "== stripping -cache-compile-job is not enough; capturing a TablePro command line from a build without compilation caching"
      python3 -u .github/diag/nocache_argv.py "$OUT" < /dev/null && nocache_argv="$OUT/nocache-argv.txt"
    else
      continue
    fi
  fi
  [ -n "$nocache_argv" ] || { echo "no usable command line for the bisect"; break; }
  python3 -u .github/diag/declbisect.py "$nocache_argv" "$file" --probe "$probe" --control "$control" --work "$work" < /dev/null
done < "$OUT/picked.tsv"

echo "== replay the long TableProTests batches"
python3 -u .github/diag/replay_batches.py "$OUT" 900 900 TableProTests
cp "$OUT/replay-results.json" "$OUT/replay-results-TableProTests.json" 2>/dev/null
exit 0
