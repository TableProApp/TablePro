#!/usr/bin/env bash
#
# Check text against scripts/banned-words.txt, the writing-style list every check shares.
#
# Usage:
#   scripts/check-banned-words.sh --staged         the lines a staged change adds
#   scripts/check-banned-words.sh --base <ref>     the lines HEAD adds since its merge base with <ref>
#   scripts/check-banned-words.sh <file>...        every line of each file, such as a PR body
#
# A term matches case-insensitively at the start of a word, so a capitalized or suffixed form is a
# hit and a word that only ends in a term is not. A term that starts with punctuation, the em dash,
# matches anywhere. Each hit prints as file:line: term. Exits 1 on a hit, 0 when clean and 2 on a
# usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIST="$SCRIPT_DIR/banned-words.txt"
LIST_PATH_IN_REPO="scripts/banned-words.txt"

usage() {
    sed -n "5,8s/^#   //p" "${BASH_SOURCE[0]}"
    exit "${1:-2}"
}

[ -f "$LIST" ] || {
    echo "check-banned-words.sh: $LIST is missing" >&2
    exit 2
}

BANNED_TERMS="$(sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$LIST")"
export BANNED_TERMS

MATCHER='
BEGIN {
    count = split(ENVIRON["BANNED_TERMS"], original, "\n")
    for (i = 1; i <= count; i++) {
        term[i] = tolower(original[i])
        anchored[i] = substr(term[i], 1, 1) ~ /[a-z0-9]/
    }
    hits = 0
}

function starts_word(text, position) {
    return position == 1 || substr(text, position - 1, 1) !~ /[a-z0-9_-]/
}

function contains(text, needle, at_word_start,    rest, offset, position) {
    rest = text
    offset = 0
    while ((position = index(rest, needle)) > 0) {
        if (!at_word_start || starts_word(text, offset + position)) {
            return 1
        }
        offset += position
        rest = substr(rest, position + 1)
    }
    return 0
}

function check(text, location,    lowered, i) {
    lowered = tolower(text)
    for (i = 1; i <= count; i++) {
        if (contains(lowered, term[i], anchored[i])) {
            print location ": " original[i]
            hits++
        }
    }
}
'

DIFF_READER='
/^diff --git / { in_header = 1; file = ""; next }
in_header && /^\+\+\+ / {
    file = substr($0, 5)
    sub(/^b\//, "", file)
    sub(/\t$/, "", file)
    if (file == "/dev/null" || file == skip) {
        file = ""
    }
    next
}
/^@@ / {
    in_header = 0
    match($0, /\+[0-9]+/)
    line = substr($0, RSTART + 1, RLENGTH - 1) + 0
    next
}
in_header { next }
/^\+/ {
    if (file != "") {
        check(substr($0, 2), file ":" line)
    }
    line++
    next
}
/^ / { line++ }
END { exit(hits > 0 ? 1 : 0) }
'

FILE_READER='
{ check($0, FILENAME ":" FNR) }
END { exit(hits > 0 ? 1 : 0) }
'

check_diff() {
    git rev-parse --show-toplevel > /dev/null 2>&1 || {
        echo "check-banned-words.sh: not inside a git repository" >&2
        exit 2
    }
    git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --diff-filter=ACMR \
        --src-prefix=a/ --dst-prefix=b/ "$@" |
        LC_ALL=C awk -v skip="$LIST_PATH_IN_REPO" "$MATCHER$DIFF_READER"
}

check_files() {
    local file resolved
    local texts=()
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            echo "check-banned-words.sh: no such file: $file" >&2
            exit 2
        fi
        resolved="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
        [ "$resolved" = "$LIST" ] && continue
        grep -Iq . "$file" || continue
        texts+=("$file")
    done
    [ "${#texts[@]}" -gt 0 ] || return 0
    LC_ALL=C awk "$MATCHER$FILE_READER" "${texts[@]}"
}

case "${1:-}" in
    --staged)
        [ "$#" -eq 1 ] || usage >&2
        check_diff --cached
        ;;
    --base)
        [ "$#" -eq 2 ] || usage >&2
        git rev-parse --verify --quiet "$2^{commit}" > /dev/null || {
            echo "check-banned-words.sh: not a commit: $2" >&2
            exit 2
        }
        check_diff "$2...HEAD"
        ;;
    -h | --help)
        usage 0
        ;;
    "" | -*)
        usage >&2
        ;;
    *)
        check_files "$@"
        ;;
esac
status=$?

if [ "$status" -eq 1 ]; then
    echo "Rewrite each line above; $LIST_PATH_IN_REPO is the list." >&2
fi
exit "$status"
