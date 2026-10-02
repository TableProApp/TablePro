#!/usr/bin/env bash
#
# Check that the agent-facing docs still describe a repository that exists.
#
# Prose does not fail a build when the code moves underneath it, so a renamed type or a deleted
# script stays named in the docs until something asks. This asks.
#
# Scope: CLAUDE.md, AGENTS.md, and every .md under .claude/rules and .claude/skills.
#
# What is checked. Only mechanical claims, because those are the ones that rot silently:
#   paths    a backticked repo-relative path must exist
#   symbols  a backticked CamelCase identifier must exist in this tree, the macOS SDK, or the
#            Swift toolchain's feature list
#   scripts  every .sh named must exist, and be executable unless it is a sourced lib/ file
#   skills   every Skill(name) and hyphenated $name reference must resolve
#   counts   a stated plugin-bundle count must match the tree
#
# Fenced code blocks are stripped first: a claim in prose is a claim, a name inside an example is
# an example. A placeholder (`SomeType`, `TypeName`) and an absolute or home path are not claims
# about the tree either. Without Xcode the SDK half is skipped, and a framework-prefixed name (NS,
# CK, UI and the like) that the tree itself does not use is counted as skipped rather than stale.
#
# Usage:
#   scripts/check-doc-symbols.sh          # exit 1 if anything is stale
#   scripts/check-doc-symbols.sh --list   # also print what passed and what was skipped

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 3

LIST=0
[ "${1:-}" = "--list" ] && LIST=1

DOCS=()
for top in CLAUDE.md AGENTS.md; do
    [ -f "$top" ] && DOCS+=("$top")
done
while IFS= read -r f; do DOCS+=("$f"); done < <(
    find .claude/rules .claude/skills -name '*.md' -type f 2> /dev/null | sort
)

BUILTIN_SKILLS="code-review security-review simplify swiftui-pro run init update-config loop schedule"

# Claude Code tool names. They are backticked CamelCase in these docs and are not Swift types.
HARNESS_TOOLS="Read Write Edit Bash Glob Grep Agent Skill Workflow Task TodoWrite WebSearch WebFetch
AskUserQuestion ExitPlanMode EnterPlanMode SendMessage ListAgents Monitor NotebookEdit LSP
ReportFindings Artifact PushNotification TaskOutput TaskStop"

# Environment variables that read as CamelCase, so the ALL_CAPS filter does not catch them.
ENV_NAMES="XCTestConfigurationFilePath XCTestSessionIdentifier XCTestBundlePath"

SDK_FRAMEWORKS="AppKit SwiftUI Foundation Combine CoreData Observation UniformTypeIdentifiers
CloudKit Security CoreText QuartzCore CoreGraphics OSLog"

PLACEHOLDER_PATTERN='^(Some|My|Your|Foo|Bar|Example)[A-Z][a-z]|^(TypeName|ClassName|SuiteType|TestClassName)$'
FRAMEWORK_PREFIX_PATTERN='^(NS|CK|CF|CG|CA|CT|UI|XC|OS)[A-Z]'
TAB="$(printf '\t')"
SCRIPT_PATH_REGEX='(\.claude/hooks|([A-Za-z0-9_.-]+/)*scripts)(/[A-Za-z0-9_-]+)*/[A-Za-z0-9_.-]+\.sh'

# The release skill writes its blog post in the marketing site repo (../tablepro-web), a Laravel app.
# A path under one of that app's top-level folders, which this tree does not have, names that repo,
# and blog-post.md runs every command from there, so the names it uses are the site's own.
SITE_REPO_ROOTS="app public resources routes tests"
SITE_REPO_DOCS=".claude/skills/release/references/blog-post.md"

findings=0
checked=0
skipped=0
sdk_indexed=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

report() {
    findings=$((findings + 1))
    checked=$((checked + 1))
    printf '%s: %s\n' "$1" "$2"
}

pass() {
    checked=$((checked + 1))
    [ "$LIST" -eq 1 ] && printf '  ok    %-52s %s\n' "$1" "$2"
    return 0
}

skip() {
    skipped=$((skipped + 1))
    [ "$LIST" -eq 1 ] && printf '  skip  %-52s %s\n' "$1" "$2"
    return 0
}

# ------------------------------------------------------------------ symbol index

# Reads file paths on stdin and prints the identifiers left once comments are stripped, so a name
# that survives only in somebody's `//` note does not count as resolved. String literals stay: a
# name used in a literal is still a name the tree uses. -0777 reads each file as one record, so a
# /* */ match never spans two files, and one perl process serves every file.
uncommented_identifiers() {
    tr '\n' '\0' |
        xargs -0 perl -0777 -ne 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g; print "$_\n"' 2> /dev/null |
        grep -oE '\b[A-Z][A-Za-z0-9_]{3,}\b'
}

sdk_frameworks_dir() {
    local sdk
    command -v xcrun > /dev/null 2>&1 || return 1
    sdk="$(xcrun --sdk macosx --show-sdk-path 2> /dev/null)" || return 1
    [ -d "$sdk/System/Library/Frameworks" ] || return 1
    printf '%s\n' "$sdk/System/Library/Frameworks"
}

build_symbol_index() {
    local frameworks_dir fw iface
    {
        find TablePro Plugins Packages TableProTests TableProUITests TableProMobile \
            -name '*.swift' -type f 2> /dev/null | uncommented_identifiers
        grep -rhoE '\b[A-Za-z][A-Za-z0-9_]{3,}\b' --include='*.h' Plugins 2> /dev/null
        grep -hoE '^  [A-Za-z][A-Za-z0-9_+-]*:' project.yml 2> /dev/null | tr -d ' :'
        printf '%s\n' $HARNESS_TOOLS $ENV_NAMES
        if command -v xcrun > /dev/null 2>&1; then
            xcrun swift-frontend -print-supported-features 2> /dev/null |
                sed -n 's/.*"name": "\([A-Za-z0-9_]*\)".*/\1/p'
        fi
    } > "$WORK/symbols.raw"

    if frameworks_dir="$(sdk_frameworks_dir)"; then
        sdk_indexed=1
        : > "$WORK/sdk-headers"
        for fw in $SDK_FRAMEWORKS; do
            iface="$frameworks_dir/$fw.framework/Modules/$fw.swiftmodule/arm64e-apple-macos.swiftinterface"
            [ -f "$iface" ] && grep -hoE '\b[A-Z][A-Za-z0-9_]{3,}\b' "$iface" >> "$WORK/symbols.raw"
            # Headers is a symlink into Versions/Current, and find follows a symlinked starting
            # point only when the path ends in a slash.
            find "$frameworks_dir/$fw.framework/Headers/" -name '*.h' -type f 2> /dev/null >> "$WORK/sdk-headers"
        done
        uncommented_identifiers < "$WORK/sdk-headers" >> "$WORK/symbols.raw"
    fi
    LC_ALL=C sort -u "$WORK/symbols.raw" > "$WORK/symbols"
}

# ------------------------------------------------------------------ prose extraction

# Strip fenced code blocks, then emit "line:content" for what is left.
prose() {
    awk '/^[[:space:]]*```/ { fence = !fence; next } { print NR ":" (fence ? "" : $0) }' "$1"
}

# Prints "line:match" for every match of the regex in the prose, with the first and last
# characters (the backticks) trimmed when trim is 1. The regex goes through the environment
# because awk -v rewrites the backslash escapes it carries.
matches() {
    MATCH_PATTERN="$1" awk -v trim="$2" '{
        pattern = ENVIRON["MATCH_PATTERN"]
        line = $0; sub(/:.*/, "", line); body = substr($0, length(line) + 2)
        while (match(body, pattern)) {
            print line ":" substr(body, RSTART + trim, RLENGTH - 2 * trim)
            body = substr(body, RSTART + RLENGTH)
        }
    }' "$WORK/prose"
}

# A path written relative to the repo, the doc, the skill root, or the app or UI-test target.
# Prints the path as it exists on disk, a tab, and how it was resolved.
resolve_path() {
    local token="$1" dir="$2" candidate
    for candidate in "$token" "$dir/$token" "$dir/../$token" "TablePro/$token" "TableProUITests/$token"; do
        [ -e "$candidate" ] || continue
        case "$candidate" in
            "$token") printf '%s\t\n' "$candidate" ;;
            "$dir/$token") printf '%s\t (relative to the doc)\n' "$candidate" ;;
            "$dir/../$token") printf '%s\t (relative to the skill root)\n' "$candidate" ;;
            *) printf '%s\t (target-relative shorthand)\n' "$candidate" ;;
        esac
        return 0
    done
    # A gitignored path is per-developer or downloaded, so a fresh checkout not having it is the
    # expected state, and flagging Secrets.xcconfig or Libs/*.a would train everyone to ignore this.
    if git check-ignore -q "$token" 2> /dev/null; then
        printf '%s\t (gitignored, optional by design)\n' "$token"
        return 0
    fi
    return 1
}

is_site_repo_path() {
    local root="${1%%/*}"
    [ ! -d "$root" ] && printf ' %s ' $SITE_REPO_ROOTS | grep -qF " $root "
}

is_site_repo_doc() {
    printf ' %s ' $SITE_REPO_DOCS | grep -qF " $1 "
}

# ------------------------------------------------------------------ checks

check_paths() {
    local doc="$1" dir="$2" hit line token resolved
    while IFS= read -r hit; do
        line="${hit%%:*}"; token="${hit#*:}"
        case "$token" in
            http* | /* | *' '* | *'*'* | *'<'* | *'$'* | *'|'* | *'{'*) continue ;;
            # A first segment carrying a dot is a hostname, not a path in this tree.
            *.*/*) [ "${token%%/*}" != "${token%%.*}" ] && continue ;;
        esac
        # Prose reads like a path when it is a pair of lowercase words: if/else, and/or, read/write.
        case "$token" in
            [a-z]*/[a-z]*)
                case "$token" in
                    *.* | */*/*) ;;
                    *) continue ;;
                esac
                ;;
        esac
        token="${token%/}"
        [ -n "$token" ] || continue
        # A script is check_scripts' claim, so it is reported once, there.
        [[ "$token" =~ ^$SCRIPT_PATH_REGEX$ ]] && continue
        if resolved="$(resolve_path "$token" "$dir")"; then
            pass "$token${resolved#*"$TAB"}" "$doc:$line"
        elif is_site_repo_path "$token"; then
            skip "$token (marketing site repo)" "$doc:$line"
        else
            report "$doc:$line" "path does not exist: $token"
        fi
    done < <(matches '`[A-Za-z0-9_./+-]+/[A-Za-z0-9_./+-]*`' 1)
}

check_symbols() {
    local doc="$1" hit line token
    matches '`[A-Z][A-Za-z0-9_]{3,}`' 1 | sort -u -t: -k2 > "$WORK/symbol-hits"
    cut -d: -f2 "$WORK/symbol-hits" | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$WORK/symbols" > "$WORK/resolved"
    while IFS= read -r hit; do
        line="${hit%%:*}"; token="${hit#*:}"
        # ALL_CAPS is an environment variable, a build setting, or a verdict word, never a Swift
        # type. Use the POSIX class: outside the C locale [a-z] collates to include uppercase.
        case "$token" in
            *[[:lower:]]*) ;;
            *) continue ;;
        esac
        if grep -qxF "$token" "$WORK/resolved"; then
            pass "$token" "$doc:$line"
        elif printf '%s\n' "$token" | grep -qE "$PLACEHOLDER_PATTERN"; then
            skip "$token (placeholder)" "$doc:$line"
        elif is_site_repo_doc "$doc"; then
            skip "$token (marketing site repo)" "$doc:$line"
        elif [ "$sdk_indexed" -eq 0 ] && printf '%s\n' "$token" | grep -qE "$FRAMEWORK_PREFIX_PATTERN"; then
            skip "$token (SDK name, no SDK to check against)" "$doc:$line"
        else
            report "$doc:$line" "symbol is in no Swift source, SDK header or toolchain feature list: $token"
        fi
    done < "$WORK/symbol-hits"
}

check_scripts() {
    local doc="$1" dir="$2" hit line token resolved path
    while IFS= read -r hit; do
        line="${hit%%:*}"; token="${hit#*:}"
        resolved="$(resolve_path "$token" "$dir")" || resolved=""
        path="${resolved%%"$TAB"*}"
        if [ ! -f "$path" ]; then
            report "$doc:$line" "script does not exist: $token"
        elif [ -x "$path" ] || [[ "$token" == */lib/* ]]; then
            pass "$token${resolved#*"$TAB"}" "$doc:$line"
        else
            report "$doc:$line" "script exists but is not executable: $token"
        fi
    done < <(matches "$SCRIPT_PATH_REGEX" 0 | sort -u -t: -k2)
}

check_skills() {
    local doc="$1" hit line token
    while IFS= read -r hit; do
        line="${hit%%:*}"; token="${hit#*:}"
        token="${token#Skill(}"; token="${token%)}"; token="${token#\$}"
        if [ -d ".claude/skills/$token" ] || [ -d ".agents/skills/$token" ]; then
            pass "skill $token" "$doc:$line"
        elif printf '%s\n' $BUILTIN_SKILLS | grep -qx "$token"; then
            pass "built-in skill $token" "$doc:$line"
        else
            report "$doc:$line" "skill does not resolve: $token"
        fi
    done < <(matches 'Skill\([a-z-]+\)|\$[a-z]+-[a-z-]+' 0 | sort -u -t: -k2)
}

check_doc() {
    local doc="$1" dir
    dir="$(dirname "$doc")"
    prose "$doc" > "$WORK/prose"
    check_paths "$doc" "$dir"
    check_symbols "$doc"
    check_scripts "$doc" "$dir"
    check_skills "$doc"
}

check_counts() {
    local total doc line stated
    total="$(find Plugins -mindepth 1 -maxdepth 1 -name '*Plugin' | wc -l | tr -d ' ')"
    for doc in "${DOCS[@]}"; do
        while IFS=: read -r line stated; do
            if [ "$stated" = "$total" ]; then
                pass "$stated plugin bundles" "$doc:$line"
            else
                report "$doc:$line" "states $stated plugin bundles, the tree has $total"
            fi
        done < <(grep -noE '(The|all) [0-9]+ plugin' "$doc" 2> /dev/null |
            sed -E 's/^([0-9]+):[^0-9]*([0-9]+) plugin$/\1:\2/')
    done
}

# ------------------------------------------------------------------ run

build_symbol_index
echo "checking ${#DOCS[@]} documents against the tree"
[ "$sdk_indexed" -eq 1 ] || echo "no macOS SDK found: SDK names the tree does not use are skipped"
for doc in "${DOCS[@]}"; do check_doc "$doc"; done
check_counts

echo
if [ "$findings" -eq 0 ]; then
    echo "clean: $checked references check out, $skipped skipped"
    exit 0
fi
echo "$findings stale reference(s) out of $checked checked, $skipped skipped"
echo "Each is a claim these docs make that the tree does not support. Fix the doc, or fix the"
echo "code if the doc describes the intent and the code is what drifted."
exit 1
