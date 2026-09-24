#!/bin/bash
set -u
xcodebuild build-for-testing \
  -project "$XCODE_PROJECT" -scheme "$XCODE_SCHEME" -destination "$TEST_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath ~/.spm-cache \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO > build.log 2>&1 &
pid=$!
start=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
  sleep 30
  now=$(( $(date +%s) - start ))
  echo "== ${now}s"
  for p in $(pgrep -f 'swift-frontend -frontend -c'); do
    et=$(ps -o etime= -p "$p" | tr -d ' ')
    mod=$(ps -ww -o args= -p "$p" | grep -oE -- '-module-name [^ ]+' | head -1)
    echo "  $p $et $mod"
    secs=$(echo "$et" | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }')
    if [ "$mod" = "-module-name TablePro" ] && [ "$secs" -gt 480 ]; then
      echo "== stuck batch $p after ${secs}s"
      python3 -c "import sys; sys.path.insert(0, '.github/diag'); import replay; print('\n'.join(replay.argv_of($p)))" > stuck-argv.txt
      wc -l stuck-argv.txt
      kill "$pid"; pkill -f swift-frontend; sleep 5
      python3 .github/diag/replay.py stuck-argv.txt 300
      exit 1
    fi
  done
done
wait "$pid"; echo "xcodebuild exited $?"
grep -E "error:" build.log | sort -u | head -50
