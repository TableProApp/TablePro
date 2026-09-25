#!/bin/bash
set -u
BACKUP="${RUNNER_TEMP:-/tmp}/orig-TableProTests"

run_build() {
  local label="$1"
  local out="$PWD/diag-out/$label"
  mkdir -p "$out"
  python3 -u .github/diag/sample.py "$out" > "$out/sampler.log" 2>&1 &
  local sampler=$!
  local start
  start=$(date +%s)
  echo "== $label build start $(date -u +%H:%M:%S)"
  set -o pipefail
  xcodebuild build-for-testing \
    -project "$XCODE_PROJECT" -scheme "$XCODE_SCHEME" -destination "$TEST_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath ~/.spm-cache \
    -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO 2>&1 \
    | python3 -u -c 'import sys, time
for line in sys.stdin:
    sys.stdout.write(time.strftime("%H:%M:%S ", time.gmtime()) + line)' > "$out/build.raw.log"
  local status=$?
  set +o pipefail
  echo "== $label build end $(date -u +%H:%M:%S) exit $status after $(( $(date +%s) - start ))s"
  touch "$out/build.done"
  wait "$sampler"
  grep -E "BUILD (SUCCEEDED|FAILED)" "$out/build.raw.log" | tail -2
  python3 .github/diag/log_events.py "$out/build.raw.log" | grep -E "SwiftCompile lines|SwiftDriver +TableProTests|Ld .*TableProTests|Compilation Requirements +TableProTests"
  python3 .github/diag/report.py "$out" 120 100000 | sed -n '1,8p'
  gzip -f "$out/build.raw.log"
  rm -rf "$out/argv" "$out/files"
}

run_build 1-original-full
python3 .github/diag/suites.py TableProTests "$BACKUP"
run_build 2-fixed-incremental
rsync -a --delete "$BACKUP/" TableProTests/
find TableProTests -name '*.swift' -exec touch {} +
git status --short TableProTests | head -3
run_build 3-original-incremental
exit 0
