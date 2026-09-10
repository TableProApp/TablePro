#!/usr/bin/env bash
set -euo pipefail

# Writes a test-duration summary from an .xcresult to $GITHUB_STEP_SUMMARY, or to stdout locally.
#
# Usage: summarize-xcresult.sh <path.xcresult> [title]
#
# Nothing in this repo measured how long tests take. The two result bundles were uploaded as
# artifacts and never read, so finding out which of 85 UI tests took ninety seconds meant
# downloading one and opening Xcode. That is why a ten second XCUITest retry sat in every
# sample-database test, 30% of the UI job, until somebody went looking.
#
# Never fails the job: a summary that can break a green run is worse than no summary.

RESULT="${1:?Usage: summarize-xcresult.sh <path.xcresult> [title]}"
TITLE="${2:-Test durations}"
OUT="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ ! -d "$RESULT" ]; then
    echo "summarize-xcresult.sh: no result bundle at $RESULT" >&2
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! xcrun xcresulttool get test-results tests --path "$RESULT" --format json > "$WORK/tests.json" 2> "$WORK/err"; then
    echo "summarize-xcresult.sh: could not read $RESULT" >&2
    head -3 "$WORK/err" >&2
    exit 0
fi

TITLE="$TITLE" python3 - "$WORK/tests.json" >> "$OUT" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

cases = []


def walk(node, suite):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind == "Test Case":
        cases.append((suite, name, node.get("durationInSeconds") or 0.0, node.get("result")))
        return
    for child in node.get("children") or []:
        walk(child, name if kind == "Test Suite" else suite)


for root in payload.get("testNodes") or []:
    walk(root, "")

title = os.environ.get("TITLE", "Test durations")
if not cases:
    print(f"### {title}\n\nNo test cases in the result bundle.")
    raise SystemExit

total = sum(case[2] for case in cases)
failed = [case for case in cases if case[3] not in (None, "Passed", "Skipped")]

print(f"### {title}\n")
print(f"{len(cases)} cases in {total / 60:.1f} min"
      + (f", {len(failed)} not passing" if failed else ""))

by_suite = {}
for suite, _, duration, _ in cases:
    entry = by_suite.setdefault(suite or "(none)", [0, 0.0])
    entry[0] += 1
    entry[1] += duration

print("\n<details><summary>Slowest 20 suites</summary>\n")
print("| suite | cases | seconds |")
print("| --- | ---: | ---: |")
for suite, (count, seconds) in sorted(by_suite.items(), key=lambda item: -item[1][1])[:20]:
    print(f"| {suite} | {count} | {seconds:.1f} |")
print("\n</details>\n")

print("<details><summary>Slowest 20 cases</summary>\n")
print("| case | suite | seconds |")
print("| --- | --- | ---: |")
for suite, name, duration, _ in sorted(cases, key=lambda case: -case[2])[:20]:
    print(f"| {name} | {suite} | {duration:.1f} |")
print("\n</details>")
PY
