#!/usr/bin/env bash
set -euo pipefail

# Static inventory for the staged refactor (see specs/claude-code-refactor-roadmap.md).
# Reports duplicate contracts, crash-prone constructs, global-state usage, raw SQL
# interpolation, and execution-gate migration progress so refactor PRs have a
# repeatable baseline.
#
# Usage:
#   scripts/audit-refactor-health.sh           # print the full report
#   scripts/audit-refactor-health.sh --check    # also exit non-zero if drift gates fail
#
# Run from the repository root. Uses portable find/grep so it works locally and in CI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CHECK_MODE=false
if [ "${1:-}" = "--check" ]; then
    CHECK_MODE=true
fi

DRIFT_FAILURES=0

section() {
    echo
    echo "=== $1 ==="
}

swift_files() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    find "$dir" -name '*.swift' -type f 2>/dev/null
}

count_swift_files() {
    local total=0 dir
    for dir in "$@"; do
        total=$((total + $(swift_files "$dir" | wc -l | tr -d ' ')))
    done
    echo "$total"
}

count_swift_loc() {
    local dir="$1"
    [ -d "$dir" ] || { echo 0; return; }
    swift_files "$dir" | tr '\n' '\0' | xargs -0 wc -l 2>/dev/null | tail -1 | awk '{print $1 + 0}'
}

# grep_swift <pattern> <dir...> : extended-regex search across Swift files, prints matches
grep_swift() {
    local pattern="$1"; shift
    local dir found=""
    for dir in "$@"; do
        [ -d "$dir" ] || continue
        found="$found"$'\n'"$(grep -rnE "$pattern" "$dir" --include='*.swift' 2>/dev/null || true)"
    done
    printf '%s\n' "$found" | grep -v '^$' || true
}

count_swift_matches() {
    local pattern="$1"; shift
    grep_swift "$pattern" "$@" | grep -c . || true
}

report_loc_by_area() {
    section "Swift LOC by area"
    echo "Swift files (app + plugins + packages + mobile): $(count_swift_files TablePro Plugins Packages TableProMobile)"
    for dir in TablePro/Core TablePro/Views TablePro/Models TablePro/ViewModels Plugins Packages/TableProCore/Sources TableProMobile; do
        printf '  %-36s %8s LOC\n' "$dir" "$(count_swift_loc "$dir")"
    done
}

report_duplicate_contracts() {
    section "Duplicate shared contracts (R-001 / R-002 / R-008)"

    echo "DatabaseType definitions:"
    local dbtype_defs dbtype_count
    dbtype_defs=$(grep_swift '^(public )?(struct|enum) DatabaseType[ :<]' TablePro Plugins Packages TableProMobile | awk -F: '{print $1}' | sort -u)
    if [ -n "$dbtype_defs" ]; then
        printf '%s\n' "$dbtype_defs" | sed 's/^/  /'
    else
        echo "  (none found)"
    fi
    dbtype_count=$(printf '%s\n' "$dbtype_defs" | grep -c . || true)

    echo
    echo "PluginKit source trees:"
    if [ -d "Plugins/TableProPluginKit" ] && [ -d "Packages/TableProCore/Sources/TableProPluginKit" ]; then
        echo "  both present (duplicate authoritative PluginKit)"
        if $CHECK_MODE; then
            echo "  ⚠️  drift gate: duplicate PluginKit source trees still present"
            DRIFT_FAILURES=$((DRIFT_FAILURES + 1))
        fi
    else
        echo "  single source ✅"
    fi

    echo
    echo "Sync source trees:"
    if [ -d "TablePro/Core/Sync" ] && [ -d "Packages/TableProCore/Sources/TableProSync" ]; then
        echo "  both present (desktop + package sync contracts)"
    else
        echo "  single source ✅"
    fi

    if $CHECK_MODE && [ "${dbtype_count:-0}" -gt 1 ]; then
        echo "  ⚠️  drift gate: more than one production DatabaseType definition"
        DRIFT_FAILURES=$((DRIFT_FAILURES + 1))
    fi
}

report_crash_constructs() {
    section "Crash-prone constructs (R-009)"
    local pattern='try!|as!|fatalError|precondition|assertionFailure'
    for dir in TablePro Plugins TableProMobile; do
        printf '  %-16s %6s occurrences\n' "$dir" "$(count_swift_matches "$pattern" "$dir")"
    done
}

report_global_state() {
    section "Global state usage (R-006)"
    echo "  .shared references (TablePro):          $(count_swift_matches '\.shared\b' TablePro)"
    echo "  UserDefaults.standard references:       $(count_swift_matches 'UserDefaults\.standard' TablePro)"
}

report_sql_hotspots() {
    section "Raw SQL interpolation hotspots (R-007)"
    echo "  string-literal SQL statements (app + plugins): $(count_swift_matches '"[[:space:]]*(SELECT|INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE)[[:space:]]' TablePro Plugins)"
}

report_gate_migration() {
    section "Execution-gate migration (R-003)"
    echo "  ExecutionGate authorize call sites:       $(count_swift_matches 'ExecutionGateProvider\.shared\.authorize' TablePro)"
    echo "  direct driver execute call sites:         $(count_swift_matches 'driver\.(execute|executeParameterized|executeUserQuery)\(' TablePro)"
    echo "  (direct driver execute should trend down as callers route through the gate)"
}

echo "TablePro refactor health audit"
echo "Repo: $REPO_ROOT"
report_loc_by_area
report_duplicate_contracts
report_crash_constructs
report_global_state
report_sql_hotspots
report_gate_migration

if $CHECK_MODE; then
    echo
    if [ "$DRIFT_FAILURES" -gt 0 ]; then
        echo "❌ $DRIFT_FAILURES drift gate(s) failed"
        exit 1
    fi
    echo "✅ drift gates passed"
fi
