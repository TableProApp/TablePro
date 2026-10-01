#!/usr/bin/env bash
#
# The house style rules that a grep can settle, plus the UI vocabulary the app
# itself defines. Every rule here passes on the corpus today, so a failure is a
# regression rather than a backlog item.
#
# The banned filler comes from scripts/banned-words.txt, the list the other
# writing checks read, and matches case-insensitively at the start of a word.
#
# changelog.mdx is excluded throughout. It is 116 releases of shipped history and
# what 0.41.0's notes called a button cannot be rewritten now.
#
# Heading case is checked by check-docs-against-source.py, which needs the app's own
# UI strings to tell a Title Case slip from a control's real name.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BANNED_WORDS="../scripts/banned-words.txt"

fail=0

report() {
    local name="$1" hits="$2"
    if [ -n "$hits" ]; then
        echo "FAIL  $name"
        echo "$hits" | sed 's/^/        /'
        fail=1
    else
        echo "  ok  $name"
    fi
}

check() {
    report "$1" "$(grep -rnE "$2" --include='*.mdx' --exclude=changelog.mdx . || true)"
}

check_ignoring_case() {
    report "$1" "$(grep -rniE "$2" --include='*.mdx' --exclude=changelog.mdx . || true)"
}

banned_filler_pattern() {
    local term alternatives=""
    while IFS= read -r term || [ -n "$term" ]; do
        case "$term" in
            [[:alnum:]]*) ;;
            *) continue ;;
        esac
        term="$(printf '%s' "$term" | sed -e 's/[[:space:]]*$//' -e 's/[][\.*^$+?(){}|/]/\\&/g')"
        alternatives="${alternatives:+$alternatives|}$term"
    done < "$BANNED_WORDS"
    printf '(^|[^[:alnum:]_-])(%s)' "$alternatives"
}

if [ ! -f "$BANNED_WORDS" ]; then
    echo "FAIL  banned filler: $BANNED_WORDS is missing"
    exit 1
fi

check "em dash" '—'
check_ignoring_case "banned filler" "$(banned_filler_pattern)"
check "hedge" '\b(simply|in order to|please note|and\/or)\b'
check "allows, enables, lets you" 'allows you to|enables you to|lets you|helps you'
check "British spelling" 'colour|behaviour|honour|recognis'
check "split menu path" '\*\*[^*]+\*\* > \*\*'
check "bold keyboard shortcut" '\*\*(Cmd|Ctrl|Option|Shift)\+'
check "modifier glyph" '[⌘⌥⇧⌃]'
check "greyed out" 'greyed out|grayed out'
check "welcome screen" '[a-z] welcome screen'
check "H4 heading" '^#### '
check "New Connection button" '\*\*New Connection\*\*'
check "filter panel" 'filter panel'

if [ "$fail" -ne 0 ]; then
    echo
    echo "docs/ breaks the house style. See docs/scripts/check-writing-style.sh."
    exit 1
fi

echo
echo "docs/ matches the house style."
