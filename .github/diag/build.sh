#!/bin/bash
set -u
OUT="$PWD/diag-out"
mkdir -p "$OUT"
python3 -u .github/diag/sample.py "$OUT" > "$OUT/sampler.log" 2>&1 &
sampler=$!

echo "build start $(date -u +%H:%M:%S)"
set -o pipefail
xcodebuild build-for-testing \
  -project "$XCODE_PROJECT" -scheme "$XCODE_SCHEME" -destination "$TEST_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath ~/.spm-cache \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO 2>&1 \
  | python3 -u -c 'import sys, time
for line in sys.stdin:
    sys.stdout.write(time.strftime("%H:%M:%S ", time.gmtime()) + line)' > "$OUT/build.raw.log"
status=$?
set +o pipefail
echo "build end $(date -u +%H:%M:%S) exit $status"
touch "$OUT/build.done"
wait "$sampler"
tail -5 "$OUT/sampler.log"
grep -E " error: |BUILD (SUCCEEDED|FAILED)|\*\* " "$OUT/build.raw.log" | tail -20
python3 .github/diag/log_events.py "$OUT/build.raw.log"

python3 .github/diag/report.py "$OUT" 120 150

echo "== replay TablePro batches"
python3 -u .github/diag/replay_batches.py "$OUT" 900 2700 TablePro
cp "$OUT/replay-results.json" "$OUT/replay-results-TablePro.json" 2>/dev/null

git fetch --depth=1 origin diag/ci-compile-tail && git checkout FETCH_HEAD -- .github/diag/ && git log -1 --format='diag scripts at %h %s' FETCH_HEAD
if [ -x .github/diag/phase3.sh ]; then
  .github/diag/phase3.sh "$OUT"
fi
exit 0
