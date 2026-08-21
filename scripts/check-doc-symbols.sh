#!/usr/bin/env bash
#
# Check that the agent-facing docs still describe a repository that exists.
#
# Prose does not fail a build when the code moves underneath it. An audit on 2026-08-18 found 16
# claims in CLAUDE.md naming symbols, paths and counts that had all drifted: `SQLCompletionAdapter`
# had been renamed to `QueryCompletionAdapter`, `saveOrClearAggregatedSync` had been renamed and
# its behaviour inverted, `TabPersistenceService` and `TabStateStorage` had been deleted outright.
# Correcting those by hand without this check only resets the clock.
#
# Scope: the documents that describe THIS repository.
#   CLAUDE.md, .claude/rules/*.md, .claude/skills/fix-issue/**/*.md
# The swiftui and swiftdata skills are about framework APIs rather than this tree, so they are
# not checked here; a symbol check would be measuring the SDK, not the repo.
#
# What is checked. Only mechanical claims, because those are the ones that rot silently:
#   paths    a backticked repo-relative path must exist
#   symbols  a backticked CamelCase identifier must exist in this tree or in the macOS SDK
#   scripts  every .sh named must exist and be executable
#   skills   every Skill(name) and $name reference must resolve
#   counts   a stated plugin-bundle count must match the tree
#
# Fenced code blocks are stripped before scanning. A claim in prose is a claim; a symbol inside
# an example is an example. Behavioural claims ("CI does X") still need a human or a probe.
#
# Usage:
#   scripts/check-doc-symbols.sh          # exit 1 if anything is stale
#   scripts/check-doc-symbols.sh --list   # also print what passed

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 3

LIST=0
[ "${1:-}" = "--list" ] && LIST=1

DOCS=()
[ -f CLAUDE.md ] && DOCS+=(CLAUDE.md)
while IFS= read -r f; do DOCS+=("$f"); done < <(
    find .claude/rules .claude/skills/fix-issue -name '*.md' -type f 2> /dev/null | sort
)

BUILTIN_SKILLS="code-review security-review simplify swiftui-pro run init update-config loop schedule"

# Claude Code tool names. They are backticked CamelCase in these docs and are not Swift types,
# so without this list every mention of the harness reads as a stale symbol.
HARNESS_TOOLS="Read Write Edit Bash Glob Grep Agent Skill Workflow Task TodoWrite WebSearch WebFetch
AskUserQuestion ExitPlanMode EnterPlanMode SendMessage ListAgents Monitor NotebookEdit LSP
ReportFindings Artifact PushNotification TaskOutput TaskStop"

# Environment variables that read as CamelCase rather than ALL_CAPS, so the ALL_CAPS filter
# below does not catch them. XCTest sets these and the UI-test notes name them.
ENV_NAMES="XCTestConfigurationFilePath XCTestSessionIdentifier XCTestBundlePath"

findings=0
checked=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

report() {
    findings=$((findings + 1))
    printf '%s: %s\n' "$1" "$2"
}

pass() {
    checked=$((checked + 1))
    [ "$LIST" -eq 1 ] && printf '  ok    %-52s %s\n' "$1" "$2"
    return 0
}

# ------------------------------------------------------------------ symbol index

# A symbol resolves if this tree declares or uses it, or if the SDK we compile against does.
# Without the SDK half, every mention of NSTableView or UndoManager reads as a stale claim.
build_symbol_index() {
    local sdk_root frameworks fw iface
    {
        grep -rhoE '\b[A-Z][A-Za-z0-9_]{3,}\b' --include='*.swift' \
            TablePro Plugins Packages LocalPackages TableProTests TableProUITests 2> /dev/null
        # C bridge headers: libpq, libmariadb and friends are named in the docs too.
        grep -rhoE '\b[A-Za-z][A-Za-z0-9_]{3,}\b' --include='*.h' Plugins 2> /dev/null
        # Xcode target and scheme names live in project.yml, not in any source file.
        grep -hoE '^  [A-Za-z][A-Za-z0-9_+-]*:' project.yml 2> /dev/null | tr -d ' :'
        printf '%s\n' $HARNESS_TOOLS
        printf '%s\n' $ENV_NAMES
    } | sort -u > "$WORK/symbols"

    sdk_root="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks"
    frameworks="AppKit SwiftUI Foundation Combine CoreData Observation UniformTypeIdentifiers"
    for fw in $frameworks; do
        iface="$sdk_root/$fw.framework/Modules/$fw.swiftmodule/arm64e-apple-macos.swiftinterface"
        [ -f "$iface" ] || continue
        grep -hoE '\b[A-Z][A-Za-z0-9_]{3,}\b' "$iface" 2> /dev/null
    done | sort -u >> "$WORK/symbols"
    sort -u -o "$WORK/symbols" "$WORK/symbols"
}

# ------------------------------------------------------------------ prose extraction

# Strip fenced code blocks, then emit "line:content" for what is left.
prose() {
    awk '/^```/ { fence = !fence; next } { print NR ":" (fence ? "" : $0) }' "$1"
}

# ------------------------------------------------------------------ checks

check_doc() {
    local doc="$1" dir line token
    dir="$(dirname "$doc")"
    prose "$doc" > "$WORK/prose"

    # paths
    while IFS= read -r hit; do
        line="${hit%%:*}"; token="${hit#*:}"
        case "$token" in
            http*|*' '*|*'*'*|*'<'*|*'$'*|*'|'*|*'{'*) continue ;;
            # A first segment carrying a dot is a hostname, not a path in this tree.
            *.*/*) [ "${token%%/*}" != "${token%%.*}" ] && continue ;;
        esac
        # Prose reads like a path when it is a pair of lowercase words: if/else, and/or, read/write.
        case "$token" in
            [a-z]*/[a-z]*)
                case "$token" in
                    *.*|*/*/*) ;;
                    *) continue ;;
                esac
                ;;
        esac
        token="${token%/}"
        [ -n "$token" ] || continue
        if [ -e "$token" ]; then
            pass "$token" "$doc:$line"
        elif [ -e "$dir/$token" ]; then
            pass "$token (relative to the doc)" "$doc:$line"
        elif [ -e "$dir/../$token" ]; then
            pass "$token (relative to the skill root)" "$doc:$line"
        elif [ -e "TablePro/$token" ] || [ -e "TableProUITests/$token" ]; then
            # CLAUDE.md writes app paths as Core/… and Views/… , and the UI-test doc writes
            # Support/… . Both are long-standing shorthand, not broken references.
            pass "$token (app-relative shorthand)" "$doc:$line"
        elif git check-ignore -q "$token" 2> /dev/null; then
            # A gitignored path is per-developer or downloaded, so a fresh checkout not having it
            # is the expected state. Secrets.xcconfig and Libs/*.a are documented for exactly that
            # reason, and flagging them would train everyone to ignore this check.
            pass "$token (gitignored, optional by design)" "$doc:$line"
        else
            checked=$((checked + 1))
            report "$doc:$line" "path does not exist: $token"
        fi
    done < <(sed 's/`/\n`/g' "$WORK/prose" | grep -oE '^[0-9]+:.*|`[A-Za-z0-9_./+-]+/[A-Za-z0-9_./+-]*`' > /dev/null 2>&1; \
        awk -F: '{ line=$1; $1=""; body=substr($0,2);
                   while (match(body, /`[A-Za-z0-9_.\/+-]+\/[A-Za-z0-9_.\/+-]*`/)) {
                       t = substr(body, RSTART+1, RLENGTH-2); print line ":" t;
                       body = substr(body, RSTART+RLENGTH) } }' "$WORK/prose")

    # swift symbols
    while IFS= read -r hit; do
        line="${hit%%:*}"; token="${hit#*:}"
        # ALL_CAPS is an environment variable, a build setting, or a verdict word, never a Swift
        # type. Checking those against the source index only produces noise.
        # ALL_CAPS is an environment variable, a build setting, or a verdict word, never a Swift
        # type. Use the POSIX class, not [a-z]: outside the C locale that range collates to
        # include uppercase, so the filter silently passes everything through.
        case "$token" in
            *[[:lower:]]*) ;;
            *) continue ;;
        esac
        if grep -qxF "$token" "$WORK/symbols"; then
            pass "$token" "$doc:$line"
        else
            checked=$((checked + 1))
            report "$doc:$line" "symbol is in no Swift source and no SDK interface: $token"
        fi
    done < <(awk -F: '{ line=$1; $1=""; body=substr($0,2);
                        while (match(body, /`[A-Z][A-Za-z0-9_]{3,}`/)) {
                            t = substr(body, RSTART+1, RLENGTH-2); print line ":" t;
                            body = substr(body, RSTART+RLENGTH) } }' "$WORK/prose" | sort -u -t: -k2)

    # scripts
    while IFS= read -r hit; do
        line="${hit%%:*}"; token="${hit#*:}"
        if [ ! -f "$token" ]; then
            checked=$((checked + 1))
            report "$doc:$line" "script does not exist: $token"
        elif [ ! -x "$token" ]; then
            checked=$((checked + 1))
            report "$doc:$line" "script exists but is not executable: $token"
        else
            pass "$token" "$doc:$line"
        fi
    done < <(grep -oE '[0-9]+:.*' "$WORK/prose" \
        | awk -F: '{ line=$1; $1=""; body=substr($0,2);
                     while (match(body, /(scripts|\.claude\/hooks|\.claude\/skills\/[a-z-]+\/scripts)\/[a-z0-9_-]+\.sh/)) {
                         print line ":" substr(body, RSTART, RLENGTH);
                         body = substr(body, RSTART+RLENGTH) } }' | sort -u -t: -k2)

    # skills
    while IFS= read -r hit; do
        line="${hit%%:*}"; token="${hit#*:}"
        if [ -d ".claude/skills/$token" ] || [ -d ".agents/skills/$token" ]; then
            pass "skill $token" "$doc:$line"
        elif printf '%s\n' $BUILTIN_SKILLS | grep -qx "$token"; then
            pass "built-in skill $token" "$doc:$line"
        else
            checked=$((checked + 1))
            report "$doc:$line" "skill does not resolve: $token"
        fi
    done < <(awk -F: '{ line=$1; $1=""; body=substr($0,2);
                        while (match(body, /Skill\([a-z-]+\)|\$[a-z]+-[a-z-]+|\$(swiftui|swiftdata|release|fix-issue)\b/)) {
                            t = substr(body, RSTART, RLENGTH);
                            gsub(/Skill\(|\)|\$/, "", t); print line ":" t;
                            body = substr(body, RSTART+RLENGTH) } }' "$WORK/prose" | sort -u -t: -k2)
}

check_counts() {
    local total doc line stated
    total="$(ls -d Plugins/*Plugin 2> /dev/null | wc -l | tr -d ' ')"
    for doc in "${DOCS[@]}"; do
        while IFS=: read -r line stated; do
            if [ "$stated" = "$total" ]; then
                pass "$stated plugin bundles" "$doc:$line"
            else
                checked=$((checked + 1))
                report "$doc:$line" "states $stated plugin bundles, the tree has $total"
            fi
        done < <(grep -noE '(The|all) [0-9]+ plugin' "$doc" 2> /dev/null | grep -oE '^[0-9]+|[0-9]+ plugin' \
            | paste -d: - - 2> /dev/null | sed -E 's/([0-9]+):([0-9]+) plugin/\1:\2/')
    done
}

# ------------------------------------------------------------------ run

build_symbol_index
echo "checking ${#DOCS[@]} documents against the tree"
for doc in "${DOCS[@]}"; do check_doc "$doc"; done
check_counts

echo
if [ "$findings" -eq 0 ]; then
    echo "clean: $checked references check out"
    exit 0
fi
echo "$findings stale reference(s) out of $checked checked"
echo "Each is a claim these docs make that the tree does not support. Fix the doc, or fix the"
echo "code if the doc describes the intent and the code is what drifted."
exit 1
