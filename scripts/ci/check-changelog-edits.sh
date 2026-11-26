#!/usr/bin/env bash
set -euo pipefail

# Fails when the changes from <base> to HEAD edit apple/CHANGELOG.md, linux/CHANGELOG.md or windows/CHANGELOG.md and
# <title> is not a chore(release) title. A version heading added outside a release PR makes version.py refuse its betas
# and notes.py assemble refuse it.
# Usage: check-changelog-edits.sh <base> <title>

if [ $# -ne 2 ] || [ -z "$1" ]; then
    echo "Usage: check-changelog-edits.sh <base> <title>" >&2
    exit 2
fi
BASE="$1"
TITLE="$2"

cd "$(git rev-parse --show-toplevel)"
# --diff-filter=a excludes an added file: bootstrapping an app's empty CHANGELOG.md once carries no version heading, so
# any PR may add it; every later edit to it is caught.
edited="$(git diff --no-renames --diff-filter=a --name-only "$BASE" HEAD -- apple/CHANGELOG.md linux/CHANGELOG.md windows/CHANGELOG.md)"
[ -n "$edited" ] || exit 0
case "$TITLE" in 'chore(release)'*) exit 0 ;; esac
echo "::error title=Changelog::Only a chore(release) pull request edits ${edited//$'\n'/ or }. Add a changelog.d/<PR>.<type>.md fragment instead."
exit 1
