#!/usr/bin/env bash
#
# Claude Code hook guards for TablePro.
#
# Each subcommand reads the hook payload as JSON on stdin and writes a hook JSON result on
# stdout. Every rule here was previously prose in a skill file that something violated anyway;
# a hook makes the mistake impossible instead of forbidden.
#
# Usage: guard.sh <check>
#
#   no-blanket-add    PreToolUse/Bash   deny git add -A, -u, --all, .
#   no-xcstrings-add  PreToolUse/Bash   deny staging Localizable.xcstrings
#   no-commit-push    PreToolUse/Bash   deny chaining git commit into git push
#   regenerate-note   PostToolUse/Write remind to regenerate after a new .swift file
#   changelog-intact  PostToolUse/Edit  block when a CHANGELOG version heading disappeared
#   writing-style     PostToolUse/Edit  warn on em dashes and banned filler in written text
#
# Exit 0 always. A guard that crashes must never block the session, so every check fails open
# except the two that deliberately emit a deny decision.

set -u

CHECK="${1:-}"
PAYLOAD="$(cat)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# These are TablePro's project rules, so they apply to TablePro's files. A session also writes
# outside the repo (scratchpad files, the auto-memory index, notes), and those carry their own
# conventions: the memory index, for one, separates its title from its hook with an em dash.
in_repo() {
    case "$1" in
        "$REPO_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

field() {
    printf '%s' "$PAYLOAD" | jq -r "$1 // \"\"" 2>/dev/null || printf ''
}

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' \
        "$(printf '%s' "$1" | jq -Rs .)"
    exit 0
}

note() {
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}' \
        "$(printf '%s' "$1" | jq -Rs .)"
    exit 0
}

block() {
    printf '{"decision":"block","reason":%s}' "$(printf '%s' "$1" | jq -Rs .)"
    exit 0
}

case "$CHECK" in
    no-blanket-add)
        cmd="$(field '.tool_input.command')"
        if printf '%s' "$cmd" | grep -qE '\bgit\b.*\badd\b[[:space:]]+(-A|-u|--all|\.)([[:space:]]|$)'; then
            deny "Blanket git add is banned in this repository. Other sessions leave files in this tree, so -A, -u, --all, and . stage work that is not yours. Stage the explicit paths your change touches, then re-read git status --short."
        fi
        ;;

    no-xcstrings-add)
        cmd="$(field '.tool_input.command')"
        if printf '%s' "$cmd" | grep -qE '\bgit\b.*\badd\b.*Localizable\.xcstrings'; then
            deny "TablePro/Resources/Localizable.xcstrings is shared and frequently dirty from other work, and new keys fall back to the English key until a build regenerates it. Leave it out unless your change is the reason it moved; if it is, stage it in its own call and say so."
        fi
        ;;

    no-commit-push)
        cmd="$(field '.tool_input.command')"
        if printf '%s' "$cmd" | grep -qE '\bgit\b[^;&|]*\bcommit\b.*(&&|\|\||;).*\bgit\b[^;&|]*\bpush\b'; then
            deny "Never chain git commit into git push. That chain removed the last chance to notice a checkout sitting on main after a squash merge, and it pushed straight to the default branch. Commit first, read the result, then push as its own call."
        fi
        ;;

    regenerate-note)
        path="$(field '.tool_input.file_path')"
        in_repo "$path" || exit 0
        case "$path" in
            *.swift) ;;
            *) exit 0 ;;
        esac
        note "New Swift file written: $path. TablePro.xcodeproj is generated and XcodeGen globs sources at generation time, so this file is not compiled until scripts/generate-project.sh runs. Run .claude/skills/fix-issue/scripts/verify.sh generate before the next build. The failure mode if you skip it is misleading: the build reports 'cannot find X in scope' from the callers, as if the code were never written."
        ;;

    changelog-intact)
        path="$(field '.tool_input.file_path')"
        case "$path" in
            *CHANGELOG.md) ;;
            *) exit 0 ;;
        esac
        [ -f "$path" ] || exit 0
        dir="$(dirname "$path")"
        base="$(basename "$path")"
        was="$(git -C "$dir" show "HEAD:./$base" 2>/dev/null | grep -c '^## \[')" || exit 0
        [ "${was:-0}" -gt 0 ] || exit 0
        now="$(grep -c '^## \[' "$path")"
        if [ "$now" -lt "$was" ]; then
            block "A CHANGELOG version heading disappeared in that edit: HEAD has $was headings matching '^## [', the file now has $now. This is the failure where an Edit whose new_string drops the trailing context swallows a released version heading and folds that release into [Unreleased]. Release notes are extracted from [Unreleased], so the next release would re-ship it, and no build catches it. Re-read the file and restore the heading."
        fi
        ;;

    writing-style)
        path="$(field '.tool_input.file_path')"
        in_repo "$path" || exit 0
        written="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.content // .tool_input.new_string // "")' 2>/dev/null)"
        [ -n "$written" ] || exit 0
        hits="$(printf '%s' "$written" \
            | grep -noE '—|seamless|robust|comprehensive|intuitive|effortless|streamlined|leverage|elevate|delve|utilize|facilitate' \
            | sort -u -t: -k2 | head -12)"
        [ -n "$hits" ] || exit 0
        note "Writing-style hits in what you just wrote to $path. The repository style rule bans em dashes and promotional filler in UI text, docs, changelogs, commit subjects, PR text, and agent-authored guidance. Rewrite these on the lines you added:
$hits"
        ;;

    *)
        echo "guard.sh: unknown check '${CHECK}'" >&2
        exit 0
        ;;
esac

exit 0
