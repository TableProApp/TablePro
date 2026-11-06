#!/usr/bin/env bash
set -euo pipefail

# Fails when the changes from <base> to HEAD edit apple/CHANGELOG.md or linux/CHANGELOG.md and <title> is not a
# chore(release) title. A version heading added outside a release PR makes version.py refuse its betas and notes.py
# assemble refuse it.
# Usage: check-changelog-edits.sh <base> <title>

if [ $# -ne 2 ] || [ -z "$1" ]; then
    echo "Usage: check-changelog-edits.sh <base> <title>" >&2
    exit 2
fi
BASE="$1"
TITLE="$2"

cd "$(git rev-parse --show-toplevel)"
edited="$(git diff --no-renames --name-only "$BASE" HEAD -- apple/CHANGELOG.md linux/CHANGELOG.md)"
[ -n "$edited" ] || exit 0
case "$TITLE" in 'chore(release)'*) exit 0 ;; esac
echo "::error title=Changelog::Only a chore(release) pull request edits ${edited//$'\n'/ or }. Add a changelog.d/<PR>.<type>.md fragment instead."
exit 1
