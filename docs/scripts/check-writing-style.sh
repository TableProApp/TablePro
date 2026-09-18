#!/usr/bin/env bash
#
# The house style rules from CLAUDE.md that a grep can settle, plus the UI
# vocabulary the app itself defines. Every rule here passes on the corpus today,
# so a failure is a regression rather than a backlog item.
#
# changelog.mdx is excluded throughout. It is 116 releases of shipped history and
# what 0.41.0's notes called a button cannot be rewritten now.
#
# Heading case is checked by check-docs-against-source.py, which needs the app's own
# UI strings to tell a Title Case slip from a control's real name.

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

check() {
    local name="$1" pattern="$2"
    local hits
    hits=$(grep -rnE "$pattern" --include='*.mdx' --exclude=changelog.mdx . || true)
    if [ -n "$hits" ]; then
        echo "FAIL  $name"
        echo "$hits" | sed 's/^/        /'
        fail=1
    else
        echo "  ok  $name"
    fi
}

check "em dash" '—'
check "banned filler" 'seamless|robust|comprehensive|intuitive|effortless|streamlined|leverage|elevate|delve|utilize|facilitate|supercharge|unleash|game-chang'
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
