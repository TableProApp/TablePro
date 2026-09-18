#!/usr/bin/env bash
set -euo pipefail

# Decides whether a workflow's suites need to run for this event. Prints "true" or "false".
#
# Usage:
#   detect-changed-paths.sh --event <name> [--base <sha>] [--ref <ref>] [--skip-release-commit] \
#                           <path-regex> [<path-regex>...]
#
# The path arguments are alternatives in one anchored regex, so pass prefixes like "TablePro/" or
# anchored files like 'project\.yml$'.
#
# This lived twice, inline in macos-tests.yml and ios-tests.yml, with a comment asking a human to
# keep the two copies in step and nothing enforcing it. The reasoning below is the part worth not
# duplicating.

EVENT=""
BASE=""
REF=""
SKIP_RELEASE_COMMIT=0
PATTERNS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --event) EVENT="${2:?--event needs a value}"; shift 2 ;;
        --base) BASE="${2:-}"; shift 2 ;;
        --ref) REF="${2:-}"; shift 2 ;;
        --skip-release-commit) SKIP_RELEASE_COMMIT=1; shift ;;
        --) shift; PATTERNS+=("$@"); break ;;
        -*) echo "detect-changed-paths.sh: unknown flag $1" >&2; exit 2 ;;
        *) PATTERNS+=("$1"); shift ;;
    esac
done

[ -n "$EVENT" ] || { echo "detect-changed-paths.sh: --event is required" >&2; exit 2; }
[ "${#PATTERNS[@]}" -gt 0 ] || { echo "detect-changed-paths.sh: at least one path pattern is required" >&2; exit 2; }

# A release pushes the version commit to main and then tags that same commit, so the push and the
# tag both reach the workflow: once directly, once through build.yml's workflow_call. That tests one
# SHA twice, and because the account runs five macOS jobs at a time, the duplicate is what leaves
# the release's own suite queued behind it. The tag run is the one that gates the release, so the
# push to main stands down. github.ref belongs to the caller, so a workflow_call reads refs/tags/v*
# here and can never match this guard, which is what keeps "a release that skipped its tests"
# impossible.
#
# The subject goes into a variable instead of a pipe into grep. grep -q exits on the first match,
# and the SIGPIPE that then kills git log would surface through pipefail as a skipped guard (the
# same trap scripts/check-freetds-fedauth.sh documents).
if [ "$SKIP_RELEASE_COMMIT" -eq 1 ] && [ "$EVENT" = "push" ] && [ "$REF" = "refs/heads/main" ]; then
    SUBJECT="$(git log -1 --format=%s HEAD)"
    if [[ "$SUBJECT" =~ ^release:\ v[0-9] ]]; then
        echo "false"
        exit 0
    fi
fi

# Anything that is not a pull request runs everything: a release calls the suite with
# workflow_call, and a release that skipped its tests is the failure this exists to prevent.
if [ "$EVENT" != "pull_request" ]; then
    echo "true"
    exit 0
fi

[ -n "$BASE" ] || { echo "detect-changed-paths.sh: --base is required for a pull request" >&2; exit 2; }

# core.quotePath defaults to true, which wraps any path holding a non-ASCII byte or a control
# character in double quotes and C-escapes it, so `TablePro/Café.swift` arrives as
# `"TablePro/Caf\303\251.swift"` and the leading quote defeats the `^` anchor. This detector fails
# open, so a misread means every suite skips behind a green gate. Reading raw NUL-separated records
# removes both that and any embedded-newline trick.
#
# A file, not a variable: bash drops NUL bytes from "$(...)", which would run every path together
# into one record. It also keeps grep out of a pipeline, so the SIGPIPE noted above cannot come back.
CHANGED="$(mktemp)"
trap 'rm -f "$CHANGED"' EXIT
git -c core.quotePath=false diff --no-renames --name-only -z "$BASE" HEAD > "$CHANGED"

JOINED="$(IFS='|'; echo "${PATTERNS[*]}")"
if LC_ALL=C grep -zqE "^($JOINED)" "$CHANGED"; then
    echo "true"
else
    echo "false"
fi
