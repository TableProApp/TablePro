#!/bin/bash
set -u
xcodebuild build-for-testing \
  -project "$XCODE_PROJECT" -scheme "$XCODE_SCHEME" -destination "$TEST_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath ~/.spm-cache \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO > build.log 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
  sleep 10
  for p in $(pgrep -f 'swift-frontend -frontend -c'); do
    if ps -ww -o args= -p "$p" | grep -q -- '-module-name TablePro '; then
      python3 -c "import sys; sys.path.insert(0, '.github/diag'); import replay; print('\n'.join(replay.argv_of($p)))" > batch-argv.txt || continue
      grep -q -- '-module-name' batch-argv.txt || continue
      echo "== captured TablePro batch $p ($(wc -l < batch-argv.txt) args)"
      kill "$pid"; pkill -f swift-frontend; sleep 5
      python3 .github/diag/fnbisect.py batch-argv.txt 240
      exit 1
    fi
  done
done
echo "xcodebuild exited before a TablePro batch was captured"
tail -30 build.log
exit 1
