#!/usr/bin/env bash
set -euo pipefail

# Prints the -skip-testing arguments for a quarantine file, one per line, after checking that every
# entry still names something.
#
# Usage: quarantine-args.sh <quarantine-file> <target> <sources-dir>
#
# The check is the point. xcodebuild accepts -skip-testing for a suite that does not exist and says
# nothing, so a renamed or deleted suite leaves an inert line behind: FreeTDSClassifierTests sat in
# the list for 479 commits after the suite was deleted. The same silence is what makes a rename
# dangerous, because the suite quietly rejoins the run and goes red on somebody else's pull request.
#
# Entries are trimmed in bash rather than through `echo ... | xargs`, which is not a trim: xargs
# applies shell quote and backslash processing, so an entry containing a quote aborted the step with
# `xargs: unterminated quote` and an entry containing a backslash was silently mangled into an
# inert skip.

QUARANTINE="${1:?Usage: quarantine-args.sh <quarantine-file> <target> <sources-dir>}"
TARGET="${2:?Usage: quarantine-args.sh <quarantine-file> <target> <sources-dir>}"
SOURCES="${3:?Usage: quarantine-args.sh <quarantine-file> <target> <sources-dir>}"

[ -f "$QUARANTINE" ] || { echo "quarantine-args.sh: no such file: $QUARANTINE" >&2; exit 1; }
[ -d "$SOURCES" ] || { echo "quarantine-args.sh: no such directory: $SOURCES" >&2; exit 1; }

status=0
line_number=0

while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    entry="${line%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -n "$entry" ] || continue

    if ! [[ "$entry" =~ ^[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)?$ ]]; then
        echo "$QUARANTINE:$line_number: '$entry' is not a suite or Suite/testMethod name" >&2
        status=1
        continue
    fi

    suite="${entry%%/*}"
    if ! grep -rqE "(struct|final class|class|enum|actor)[[:space:]]+${suite}\b" "$SOURCES"; then
        echo "$QUARANTINE:$line_number: '$suite' does not exist in $SOURCES; delete the line" >&2
        status=1
        continue
    fi

    printf -- '-skip-testing:%s/%s\n' "$TARGET" "$entry"
done < "$QUARANTINE"

exit "$status"
