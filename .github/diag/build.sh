#!/bin/bash
set -u
OUT="$PWD/diag-out"
mkdir -p "$OUT"
BACKUP="${RUNNER_TEMP:-/tmp}/orig-TableProTests"
python3 .github/diag/suites.py TableProTests "$BACKUP"
git diff --stat | tail -1
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

echo "== emit-module A/B on this runner: display-name-only @Suite removed (fixed) vs the original sources"
python3 -u .github/diag/emit_ab.py "$OUT" "$PWD/TableProTests" "$BACKUP" 1500
exit 0
