#!/usr/bin/env bash
#
# Lists what TablePro test runs left on this Mac. With --apply, backs all of it up, then removes it.
#
# Usage:
#   scripts/clean-test-residue.sh           dry run: a count and a few names per row
#   scripts/clean-test-residue.sh --apply   back up to ~/TablePro-test-residue-<timestamp>/, then remove
#
# Only names traced to a test go: defaults domains in ~/Library/Preferences, the autosave records of
# sandboxed UI runs and the PluginSettingsTests keys in com.TablePro, mcp-audit-test_ databases, and
# the EphemeralDefaults, ScratchDefaults and tablepro-tests entries in the user temp directory.
# Per-connection keys in com.TablePro (QuickSwitcher.frecency.<id> and the like) stay: a real
# connection writes the same key, and a linked-folder connection is never saved, so a key whose
# connection is missing from the store is not proof of a test.
#
# --apply refuses, exit 1, while TablePro or a TablePro test run is active. Exits 2 on a usage error.

set -euo pipefail

usage() {
    sed -n "6,7s/^#   //p" "${BASH_SOURCE[0]}"
}

case "$#:${1:-}" in
    0:) APPLY=0 ;;
    1:--apply) APPLY=1 ;;
    1:-h | 1:--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

[ "$(uname -s)" = Darwin ] || { echo "clean-test-residue.sh: macOS only" >&2; exit 2; }

# The unit test host is TablePro itself; package tests run in xctest or swiftpm-testing-helper.
active() {
    pgrep -x TablePro > /dev/null \
        || pgrep -f TableProUITests-Runner > /dev/null \
        || pgrep -f '(xctest|swiftpm-testing-helper).*TablePro' > /dev/null
}

refuse_if_active() {
    active || return 0
    echo "TablePro or a TablePro test run is active. Quit it, then run --apply again." >&2
    exit 1
}

HOME_DIR="$(cd "$HOME" && pwd -P)"
# Resolved, because /var is a symlink and tar refuses to restore through one.
TEMP_DIR="$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRIPT="$WORK/residue.js"

cat > "$SCRIPT" <<'JXA'
ObjC.import('Foundation')
ObjC.bindFunction('CFPreferencesCopyKeyList', ['id', ['id', 'id', 'id']])
ObjC.bindFunction('CFPreferencesSetMultiple', ['void', ['id', 'id', 'id', 'id', 'id']])
ObjC.bindFunction('CFPreferencesSynchronize', ['bool', ['id', 'id', 'id']])

const USER = $('kCFPreferencesCurrentUser')
const HOST = $('kCFPreferencesAnyHost')
const APP_DOMAIN = 'com.TablePro'
const UUID = '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
const UUID_NAMED = new RegExp(UUID, 'i')
const quote = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// Each stem is traced to the test file, or the commit, that named a suite <stem><UUID>.
const SUITE_STEMS = [
    'cl-sync-meta-', 'ClosedTabDraftStorageTests.', 'codablelist-', 'ColumnVisibilityPersistenceTests-',
    'colvis-', 'DatabaseTreeFavoriteRefreshTests.databases.', 'DatabaseTreeFavoriteRefreshTests.favorites.',
    'DatabaseTreeFavoriteRefreshTests.sync.', 'DatabaseTreeFilterStorageTests.', 'DatabaseTreeFolderNodeTests.',
    'ExternalConnectionGateTests.', 'ExternalConnectionTrustStoreTests.', 'FavoriteDatabasesStorageTests.favorites.',
    'FavoriteDatabasesStorageTests.sync.', 'FavoritesExpansionStateTests.', 'FavoriteTablesStorageTests.favorites.',
    'FavoriteTablesStorageTests.sync.', 'FilterSettingsStorageTests-', 'ForeignKeyLabelColumnTests.',
    'ImportColumnMappingStoreTests.', 'legacy-theme-fonts-', 'linkedfolder-', 'linkedsqlfolder-',
    'LoadableExtensionApprovalStoreTests-', 'LoadableExtensionGateTests-', 'MCPRemoteToolApprovalTests.',
    'MCPRemoteToolPolicyTests.', 'MCPRemoteToolScopeTests-', 'MCPServerStoreTests-', 'notifications-',
    'QuickSwitcherFrecencyTests.', 'QuickSwitcherRecentIdentityTests.', 'QuickSwitcherTests.', 'recent-',
    'RecentTablesTests.', 'registry-freshness-tests-', 'RightPanelStateTests.', 'RowImportMappingTests.', 'sc-',
    'settings-decode-', 'settings-reset-', 'sidebar-tree-', 'slashcmd-', 'slashcmd-meta-',
    'SQLTableEditAdoptionTests.', 'StartupMigrationTests-', 'syncmetadata-', 'syncscope-',
    'TableFolderStorageTests.folders.', 'TableFolderStorageTests.sync.', 'tablepro-favorite-pull-',
    'tablepro-favorite-remote-', 'tablepro-favorite-sync-', 'tablepro-purge-', 'tablepro-purge-pane-',
    'TrailingPaneRevealTests.', 'TrailingPaneStateTests.', 'tree-group-collapse-', 'tree-group-database-',
    'tree-group-selection-', 'tree-group-writes-', 'tree-groups-', 'vdf-'
]
const DOMAIN_RULES = [
    { label: 'com.TablePro.tests.* domains in ~/Library/Preferences', test: /^com\.TablePro\.tests\..+$/ },
    { label: 'com.TablePro.uitest suites in ~/Library/Preferences', test: /^com\.TablePro\.uitest(\.[0-9a-f]{16})?$/ },
    {
        label: '<stem><UUID> suites of a traced test in ~/Library/Preferences',
        test: new RegExp(`^(?:(?:${SUITE_STEMS.map(quote).join('|')})${UUID}(?:\\.sync)?`
            + `|test\\.MacAnalyticsProviderTests\\.[A-Za-z]+\\(\\)\\.[0-9]+\\.${UUID})$`, 'i')
    }
]

// EphemeralDefaults and ScratchDefaults name each suite by a path in the temp directory.
const TEMP_RULES = [
    { label: 'EphemeralDefaults-<UUID> directories in the temp directory', test: new RegExp(`^EphemeralDefaults-${UUID}$`, 'i') },
    { label: 'com.TablePro.tests.<UUID>.plist suites in the temp directory', test: new RegExp(`^com\\.TablePro\\.tests\\.${UUID}\\.plist$`, 'i') }
]
const TESTS_TEMP_DIR = 'tablepro-tests'
const AUDIT_PREFIX = 'mcp-audit-test_'
const FLUSH_WAIT_SECONDS = 30

// Production writes these autosave names bare. Older builds appended ".<sandbox directory name>"
// under a UI test sandbox; SplitViewAutosaveName.current now returns nil there, and
// SplitViewAutosaveSweep leaves suffixed names alone.
const RECORD = '(?:NSSplitView Subview Frames |NSWindow Frame |NSTableView Columns v3 |NSTableView Sort Ordering v2 '
    + '|NSTableView Supports v2 |NSTableView Hidden Columns |NSOutlineView Items )'
const BARE_NAMES = [
    'MainEditorWindow', 'welcome', 'connection-form', 'settings', 'integrations-activity', 'acknowledgements',
    'support', 'compare-sync', 'com.TablePro.DataFileWindow', 'com.TablePro.DataFileSplit',
    'com.TablePro.queryHistory.listDetail', 'com.TablePro.versionHistory.listDetail',
    'com.TablePro.queryPlanTreeSplit', 'com.TablePro.queryPlanOutline.v2', 'com.TablePro.usersRoles.mainSplit',
    'com.TablePro.usersRoles.privilegeSplit', 'com.TablePro.usersRoles.scopeOutline', 'com.TablePro.triggerSplit',
    'com.TablePro.CompareSync.main', 'com.TablePro.CompareSync.script', 'ServerDashboardSplit',
    'CellImageViewerWindow', 'GeometryMapViewerWindow', 'JSONViewerWindow', 'PhpViewerWindow', 'TextViewerWindow'
]
const SANDBOXED_RECORD = new RegExp(`^${RECORD}(?:${BARE_NAMES.map(quote).join('|')}`
    + `|HistoryDrawer-${UUID}|QuerySplit-${UUID}(?:-${UUID})?)\\.(.+)$`, 'i')
// From June to August 2026 production named this split per connection, so a suffix counts only
// when the same sandbox name shows up on a record above.
const MAIN_SPLIT = /^NSSplitView Subview Frames com\.TablePro\.mainSplit\.(.+)$/
const PLUGIN_SETTINGS_TEST = new RegExp(`^com\\.TablePro\\.plugin\\.test\\.settings\\.(?:other\\.)?${UUID}\\.[A-Za-z]+$`, 'i')

const fm = $.NSFileManager.defaultManager
const list = dir => (fm.contentsOfDirectoryAtPathError(dir, null).js || []).map(n => n.js)
const readLines = path => {
    const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
    return text.isNil() ? [] : text.js.split('\n').filter(line => line.length > 0)
}
const writeLines = (path, lines) => {
    $(lines.map(line => `${line}\n`).join('')).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)
}
const isEmptyPlist = path => {
    const dict = $.NSDictionary.dictionaryWithContentsOfFile(path)
    return !dict.isNil() && Number(dict.count) === 0
}
const dirs = (home, temp) => ({
    prefs: `${home}/Library/Preferences`,
    audit: `${home}/Library/Application Support/TablePro`,
    temp,
    testsTemp: `${temp}/${TESTS_TEMP_DIR}`
})

function scan(home, temp, work, mode) {
    const d = dirs(home, temp)
    const out = []
    const row = (count, label, samples) => {
        out.push(`${String(count).padStart(7)}  ${label}`)
        samples.slice(0, 3).forEach(s => out.push(`           ${s}`))
    }

    const domainGroups = DOMAIN_RULES.map(rule => ({ ...rule, names: [] }))
    const unproven = []
    for (const name of list(d.prefs).filter(n => n.endsWith('.plist')).map(n => n.slice(0, -6))) {
        const group = domainGroups.find(g => g.test.test(name))
        if (group) group.names.push(name)
        else if (UUID_NAMED.test(name)) unproven.push(name)
    }
    const domains = domainGroups.flatMap(g => g.names)

    const keys = ($.CFPreferencesCopyKeyList($(APP_DOMAIN), USER, HOST).js || []).map(k => k.js)
    const sandboxNames = new Set()
    const sandboxed = keys.filter(k => {
        const m = SANDBOXED_RECORD.exec(k)
        if (m) sandboxNames.add(m[1].toUpperCase())
        return m !== null
    })
    const mainSplit = keys.filter(k => {
        const m = MAIN_SPLIT.exec(k)
        return m !== null && sandboxNames.has(m[1].toUpperCase())
    })
    const pluginTest = keys.filter(k => PLUGIN_SETTINGS_TEST.test(k))
    const deadKeys = [...sandboxed, ...mainSplit, ...pluginTest]
    const dead = new Set(deadKeys)
    const leftUUIDKeys = keys.filter(k => UUID_NAMED.test(k) && !dead.has(k))

    const tempNames = list(d.temp)
    const tempGroups = TEMP_RULES.map(rule => ({
        ...rule,
        paths: tempNames.filter(n => rule.test.test(n)).map(n => `${d.temp}/${n}`)
    }))
    const testsTemp = list(d.testsTemp).map(n => `${d.testsTemp}/${n}`)
    const audit = list(d.audit).filter(n => n.startsWith(AUDIT_PREFIX)).map(n => `${d.audit}/${n}`)
    const files = [...tempGroups.flatMap(g => g.paths), ...testsTemp, ...audit]

    out.push(mode === 'apply' ? 'Removing:' : 'Would remove (dry run):')
    domainGroups.forEach(g => row(g.names.length, g.label, g.names))
    row(sandboxed.length + mainSplit.length, 'com.TablePro autosave records of sandboxed UI runs', [...sandboxed, ...mainSplit])
    row(pluginTest.length, 'com.TablePro keys of the PluginSettingsTests plugin', pluginTest)
    row(audit.length, `${AUDIT_PREFIX} files in ~/Library/Application Support/TablePro`, audit)
    tempGroups.forEach(g => row(g.paths.length, g.label, g.paths))
    row(testsTemp.length, `entries in ${TESTS_TEMP_DIR} in the temp directory`, testsTemp)
    out.push('Left alone, not traced to a test:')
    row(unproven.length, 'UUID-named domains in ~/Library/Preferences', unproven)
    row(leftUUIDKeys.length, 'com.TablePro keys that carry a UUID', leftUUIDKeys)

    writeLines(`${work}/domains`, domains)
    writeLines(`${work}/keys`, deadKeys)
    writeLines(`${work}/files`, files)
    // Relative to /, for tar -C /.
    const backup = [...domains.map(n => `${d.prefs}/${n}.plist`), ...files].map(p => p.replace(/^\/+/, ''))
    writeLines(`${work}/backup`, backup)
    return out.join('\n')
}

function apply(home, temp, work) {
    const d = dirs(home, temp)
    const provenKey = k => SANDBOXED_RECORD.test(k) || MAIN_SPLIT.test(k) || PLUGIN_SETTINGS_TEST.test(k)
    const provenDomain = n => DOMAIN_RULES.some(rule => rule.test.test(n))
    const provenFile = p => !p.includes('/../')
        && [d.temp, d.audit].some(dir => p.startsWith(`${dir}/`) && p.length > dir.length + 1)

    const keys = readLines(`${work}/keys`)
    const domains = readLines(`${work}/domains`)
    const files = readLines(`${work}/files`)
    const strays = [...keys.filter(k => !provenKey(k)), ...domains.filter(n => !provenDomain(n)), ...files.filter(p => !provenFile(p))]
    if (strays.length > 0) throw new Error(`refusing, untraced entries in the work lists: ${strays.slice(0, 3).join(', ')}`)

    if (keys.length > 0) {
        $.CFPreferencesSetMultiple($(), $(keys), $(APP_DOMAIN), USER, HOST)
        $.CFPreferencesSynchronize($(APP_DOMAIN), USER, HOST)
    }

    for (const name of domains) {
        const domain = $(name)
        const domainKeys = $.CFPreferencesCopyKeyList(domain, USER, HOST)
        if (!domainKeys.isNil() && Number(domainKeys.count) > 0) $.CFPreferencesSetMultiple($(), domainKeys, domain, USER, HOST)
        $.CFPreferencesSynchronize(domain, USER, HOST)
    }
    // cfprefsd writes an emptied domain out as a 42-byte plist about 5 s later, and writes it back
    // if the file is already gone, so a file goes only once it reads back empty.
    let pending = domains.map(name => `${d.prefs}/${name}.plist`)
    for (let waited = 0; ; waited++) {
        pending = pending.filter(path => {
            if (!fm.fileExistsAtPath(path)) return false
            if (!isEmptyPlist(path)) return true
            fm.removeItemAtPathError(path, null)
            return false
        })
        if (pending.length === 0 || waited >= FLUSH_WAIT_SECONDS) break
        $.NSThread.sleepForTimeInterval(1)
    }

    const failed = files.filter(p => fm.fileExistsAtPath(p) && !fm.removeItemAtPathError(p, null))

    const out = [`Removed ${keys.length} com.TablePro keys, ${domains.length - pending.length} domains, ${files.length - failed.length} files and directories.`]
    if (pending.length > 0) out.push(`${pending.length} domain files did not read back empty within ${FLUSH_WAIT_SECONDS} s and were kept. Run --apply again.`)
    if (failed.length > 0) out.push(`${failed.length} could not be removed, such as ${failed[0]}.`)
    return out.join('\n')
}

function run(argv) {
    const [mode, home, temp, work] = argv
    if (mode === 'apply') return apply(home, temp, work)
    return scan(home, temp, work, argv[4])
}
JXA

jxa() {
    osascript -l JavaScript "$SCRIPT" "$@"
}

if [ "$APPLY" -eq 0 ]; then
    if active; then
        echo "Note: TablePro or a TablePro test run is active, so these counts can still change."
    fi
    jxa scan "$HOME_DIR" "$TEMP_DIR" "$WORK" dry
    echo "--apply backs all of it up to ~/TablePro-test-residue-<timestamp>/ first."
    exit 0
fi

refuse_if_active
jxa scan "$HOME_DIR" "$TEMP_DIR" "$WORK" apply
if [ ! -s "$WORK/keys" ] && [ ! -s "$WORK/backup" ]; then
    echo "Nothing to remove."
    exit 0
fi

BACKUP="$HOME_DIR/TablePro-test-residue-$(date +%Y%m%d-%H%M%S)"
mkdir "$BACKUP"
if [ -s "$WORK/keys" ]; then
    defaults export com.TablePro "$BACKUP/com.TablePro.plist"
    cp "$WORK/keys" "$BACKUP/removed-keys.txt"
fi
if [ -s "$WORK/backup" ]; then
    tar -czf "$BACKUP/files.tar.gz" --no-mac-metadata -C / -T "$WORK/backup"
    cp "$WORK/backup" "$BACKUP/removed-paths.txt"
fi
echo "Backup: $BACKUP"

refuse_if_active
DOMAINS="$(wc -l < "$WORK/domains" | tr -d ' ')"
echo "Resetting $DOMAINS domains, about $((DOMAINS * 35 / 10000 + 10)) s."
jxa apply "$HOME_DIR" "$TEMP_DIR" "$WORK"
if [ -f "$BACKUP/com.TablePro.plist" ]; then
    echo "Restore com.TablePro: defaults import com.TablePro \"$BACKUP/com.TablePro.plist\""
fi
if [ -f "$BACKUP/files.tar.gz" ]; then
    echo "Restore the files: tar -xzf \"$BACKUP/files.tar.gz\" -C /"
fi
