#!/usr/bin/env bash
set -euo pipefail

# Prints the -skip-testing arguments for a quarantine file, one per line, after checking that every
# entry still names something xcodebuild will actually skip.
#
# Usage: quarantine-args.sh <quarantine-file> <target> <xctestrun> <destination>
#
# The check is the point. xcodebuild accepts -skip-testing for a case that does not exist and says
# nothing, so a renamed or deleted entry leaves an inert line behind: FreeTDSClassifierTests sat in
# the list for 479 commits after the suite was deleted. The same silence is what makes a rename
# dangerous, because the suite quietly rejoins the run and goes red on somebody else's pull request.
#
# Entries are checked against the test identifiers xcodebuild enumerates, not against a grep of the
# sources, because a grep cannot see the one thing that matters most here: a Swift Testing case is
# only skipped when the entry carries its parentheses. Measured on this suite,
# `-skip-testing:TableProTests/EtcdPrefixRangeEndTests/allMaxBytes` runs all 7 cases and
# `...allMaxBytes()` runs 6. The bare form is accepted, silently does nothing, and reads in the file
# exactly like a working entry. Enumeration takes 2 seconds for 13,199 identifiers.
#
# Entries are trimmed in bash rather than through `echo ... | xargs`, which is not a trim: xargs
# applies shell quote and backslash processing, so an entry containing a quote aborted the step with
# `xargs: unterminated quote` and an entry containing a backslash was silently mangled into an
# inert skip.

QUARANTINE="${1:?Usage: quarantine-args.sh <quarantine-file> <target> <xctestrun> <destination>}"
TARGET="${2:?Usage: quarantine-args.sh <quarantine-file> <target> <xctestrun> <destination>}"
XCTESTRUN="${3:?Usage: quarantine-args.sh <quarantine-file> <target> <xctestrun> <destination>}"
DESTINATION="${4:?Usage: quarantine-args.sh <quarantine-file> <target> <xctestrun> <destination>}"

[ -f "$QUARANTINE" ] || { echo "quarantine-args.sh: no such file: $QUARANTINE" >&2; exit 1; }
[ -f "$XCTESTRUN" ] || { echo "quarantine-args.sh: no such file: $XCTESTRUN" >&2; exit 1; }

# A directory, not a file: xcodebuild refuses to write the enumeration to a path that already
# exists, and `mktemp` creates the file it names.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "$DESTINATION" \
    "-only-testing:$TARGET" \
    -enumerate-tests \
    -test-enumeration-style flat \
    -test-enumeration-format json \
    -test-enumeration-output-path "$WORK/tests.json" > "$WORK/enumerate.log" 2>&1; then
    echo "quarantine-args.sh: could not enumerate $TARGET" >&2
    tail -20 "$WORK/enumerate.log" >&2
    exit 1
fi

QUARANTINE="$QUARANTINE" TARGET="$TARGET" python3 "$(dirname "$0")/quarantine_args.py" "$WORK/tests.json"
