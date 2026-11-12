import AppKit
import Combine
import Foundation
import SwiftUI
import TableProTestSupport
import Testing
@testable import TablePro

@MainActor
private func makeSUT(
    pendingTruncates: Set<DatabaseTreeTableRef> = [],
    pendingDeletes: Set<DatabaseTreeTableRef> = [],
    tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:],
    databaseType: DatabaseType = .mysql
) -> (
    vm: SidebarViewModel,
    pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
    pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
    tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>
) {
    var truncatesState = pendingTruncates
    var deletesState = pendingDeletes
    var optionsState = tableOperationOptions

    let truncatesBinding = Binding(get: { truncatesState }, set: { truncatesState = $0 })
    let deletesBinding = Binding(get: { deletesState }, set: { deletesState = $0 })
    let optionsBinding = Binding(get: { optionsState }, set: { optionsState = $0 })

    let vm = SidebarViewModel(
        pendingTruncates: truncatesBinding,
        pendingDeletes: deletesBinding,
        tableOperationOptions: optionsBinding,
        databaseType: databaseType,
        connectionId: UUID()
    )

    return (vm, truncatesBinding, deletesBinding, optionsBinding)
}

@MainActor
private func makeRef(_ name: String, database: String? = nil, schema: String? = nil) -> DatabaseTreeTableRef {
    DatabaseTreeTableRef(
        database: database,
        schema: schema,
        table: TestFixtures.makeTableInfo(name: name)
    )
}

// MARK: - Tests

struct SidebarViewModelTests {

    // MARK: - Batch Toggle Truncate

    @Test("batchToggleTruncate asks the window for new tables")
    @MainActor
    func batchToggleTruncateShowsDialog() {
        let table = makeRef("users")
        let (vm, _, _, _) = makeSUT()
        let window = WindowSidebarState()

        vm.batchToggleTruncate(refs: [table], from: window)

        #expect(window.pendingTableOperation?.operation == .truncate)
        #expect(window.pendingTableOperation?.tables == [table])
    }

    @Test("batchToggleTruncate unstages when all already pending")
    @MainActor
    func batchToggleTruncateCancels() {
        let table = makeRef("users")
        let (vm, truncatesBinding, _, optionsBinding) = makeSUT(
            pendingTruncates: [table],
            tableOperationOptions: [table: TableOperationOptions()]
        )
        let window = WindowSidebarState()

        vm.batchToggleTruncate(refs: [table], from: window)

        #expect(window.pendingTableOperation == nil)
        #expect(!truncatesBinding.wrappedValue.contains(table))
        #expect(optionsBinding.wrappedValue[table] == nil)
    }

    @Test("batchToggleTruncate does nothing for no tables")
    @MainActor
    func batchToggleTruncateNoSelection() {
        let (vm, _, _, _) = makeSUT()
        let window = WindowSidebarState()

        vm.batchToggleTruncate(refs: [], from: window)

        #expect(window.pendingTableOperation == nil)
    }

    // MARK: - Batch Toggle Delete

    @Test("batchToggleDelete asks the window for new tables")
    @MainActor
    func batchToggleDeleteShowsDialog() {
        let table = makeRef("orders")
        let (vm, _, _, _) = makeSUT()
        let window = WindowSidebarState()

        vm.batchToggleDelete(refs: [table], from: window)

        #expect(window.pendingTableOperation?.operation == .drop)
        #expect(window.pendingTableOperation?.tables == [table])
    }

    @Test("batchToggleDelete unstages when all already pending")
    @MainActor
    func batchToggleDeleteCancels() {
        let table = makeRef("orders")
        let (vm, _, deletesBinding, optionsBinding) = makeSUT(
            pendingDeletes: [table],
            tableOperationOptions: [table: TableOperationOptions()]
        )
        let window = WindowSidebarState()

        vm.batchToggleDelete(refs: [table], from: window)

        #expect(window.pendingTableOperation == nil)
        #expect(!deletesBinding.wrappedValue.contains(table))
        #expect(optionsBinding.wrappedValue[table] == nil)
    }

    // MARK: - Confirm Operation

    @Test("confirmOperation truncate moves tables from pendingDeletes to pendingTruncates")
    @MainActor
    func confirmTruncateMovesFromDeletes() {
        let table = makeRef("users")
        let (vm, truncatesBinding, deletesBinding, optionsBinding) = makeSUT(pendingDeletes: [table])

        let options = TableOperationOptions(ignoreForeignKeys: true)
        vm.confirmOperation(PendingTableOperation(operation: .truncate, tables: [table]), options: options)

        #expect(truncatesBinding.wrappedValue.contains(table))
        #expect(!deletesBinding.wrappedValue.contains(table))
        #expect(optionsBinding.wrappedValue[table]?.ignoreForeignKeys == true)
    }

    @Test("confirmOperation drop moves tables from pendingTruncates to pendingDeletes")
    @MainActor
    func confirmDropMovesFromTruncates() {
        let table = makeRef("users")
        let (vm, truncatesBinding, deletesBinding, optionsBinding) = makeSUT(pendingTruncates: [table])

        let options = TableOperationOptions(cascade: true)
        vm.confirmOperation(PendingTableOperation(operation: .drop, tables: [table]), options: options)

        #expect(!truncatesBinding.wrappedValue.contains(table))
        #expect(deletesBinding.wrappedValue.contains(table))
        #expect(optionsBinding.wrappedValue[table]?.cascade == true)
    }

    @Test("confirmOperation stores options per table")
    @MainActor
    func confirmOperationStoresOptions() {
        let t1 = makeRef("t1")
        let t2 = makeRef("t2")
        let (vm, _, _, optionsBinding) = makeSUT()

        let options = TableOperationOptions(ignoreForeignKeys: true, cascade: true)
        vm.confirmOperation(PendingTableOperation(operation: .truncate, tables: [t1, t2]), options: options)

        #expect(optionsBinding.wrappedValue[t1] == options)
        #expect(optionsBinding.wrappedValue[t2] == options)
    }
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct SidebarViewModelCopyTests {
        @Test("copyTableNames copies sorted comma-separated names")
        func copyTableNames() throws {
            let clipboard = try #require(RecordingClipboard.current)

            SidebarViewModel.copyTableNames(of: [makeRef("zebra"), makeRef("alpha")])

            #expect(clipboard.text == "alpha,zebra")
        }

        @Test("copyTableNames does nothing for no tables")
        func copyTableNamesNoSelection() throws {
            let clipboard = try #require(RecordingClipboard.current)

            SidebarViewModel.copyTableNames(of: [])

            #expect(clipboard.text == nil)
        }
    }
}

// MARK: - Multi-Section Sidebar

@MainActor
private func makeViewModel(
    connectionId: UUID = UUID(),
    databaseType: DatabaseType = .postgresql,
    defaults: UserDefaults,
    clock: any Clock<Duration> = ContinuousClock()
) -> SidebarViewModel {
    var truncates: Set<DatabaseTreeTableRef> = []
    var deletes: Set<DatabaseTreeTableRef> = []
    var options: [DatabaseTreeTableRef: TableOperationOptions] = [:]
    let truncatesBinding = Binding(get: { truncates }, set: { truncates = $0 })
    let deletesBinding = Binding(get: { deletes }, set: { deletes = $0 })
    let optionsBinding = Binding(get: { options }, set: { options = $0 })
    return SidebarViewModel(
        pendingTruncates: truncatesBinding,
        pendingDeletes: deletesBinding,
        tableOperationOptions: optionsBinding,
        databaseType: databaseType,
        connectionId: connectionId,
        defaults: defaults,
        clock: clock
    )
}

@MainActor
struct SidebarViewModelMultiSectionTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    @Test("tables of kind splits by TableType raw value")
    func splitsTablesByKind() {
        let vm = makeViewModel(defaults: suite.defaults)
        let userTable = TestFixtures.makeTableInfo(name: "users", type: .table)
        let profileView = TestFixtures.makeTableInfo(name: "profiles", type: .view)
        let mixed = [userTable, profileView]

        let tablesOnly = vm.tables(of: .table, from: mixed)
        let viewsOnly = vm.tables(of: .view, from: mixed)
        let matviews = vm.tables(of: .materializedView, from: mixed)

        #expect(tablesOnly.map(\.name) == ["users"])
        #expect(viewsOnly.map(\.name) == ["profiles"])
        #expect(matviews.isEmpty)
    }

    @Test("system tables fall into the table bucket")
    func systemTablesBucketAsTables() {
        let vm = makeViewModel(defaults: suite.defaults)
        let sysTable = TestFixtures.makeTableInfo(name: "pg_stat_user_tables", type: .systemTable)

        let tablesOnly = vm.tables(of: .table, from: [sysTable])
        let viewsOnly = vm.tables(of: .view, from: [sysTable])

        #expect(tablesOnly.map(\.name) == ["pg_stat_user_tables"])
        #expect(viewsOnly.isEmpty)
    }

    @Test("routine kinds return empty when querying tables(of:)")
    func routinesEmptyInTablesOf() {
        let vm = makeViewModel(defaults: suite.defaults)
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)

        #expect(vm.tables(of: .procedure, from: [table]).isEmpty)
        #expect(vm.tables(of: .function, from: [table]).isEmpty)
    }

    @Test("filteredTables(of:) honors search across kinds")
    func filteredTablesAcrossKinds() {
        let vm = makeViewModel(defaults: suite.defaults)
        let users = TestFixtures.makeTableInfo(name: "users", type: .table)
        let userView = TestFixtures.makeTableInfo(name: "user_profile_view", type: .view)
        let orders = TestFixtures.makeTableInfo(name: "orders", type: .table)
        let mixed = [users, userView, orders]
        vm.searchText = "user"

        let tableMatches = vm.filteredTables(of: .table, from: mixed)
        let viewMatches = vm.filteredTables(of: .view, from: mixed)

        #expect(tableMatches.map(\.name) == ["users"])
        #expect(viewMatches.map(\.name) == ["user_profile_view"])
    }

    @Test("filteredRoutines filters by name across kinds")
    func filteredRoutinesByKind() {
        let vm = makeViewModel(defaults: suite.defaults)
        let getUser = RoutineInfo(name: "get_user_by_id", kind: .procedure, schema: "public")
        let calcAge = RoutineInfo(name: "calculate_age", kind: .function, schema: "public")
        let mixed = [getUser, calcAge]

        let procs = vm.filteredRoutines(of: .procedure, from: mixed)
        let funcs = vm.filteredRoutines(of: .function, from: mixed)

        #expect(procs.map(\.name) == ["get_user_by_id"])
        #expect(funcs.map(\.name) == ["calculate_age"])
    }

    @Test("Sidebar filter uses substring matching, not fuzzy abbreviations")
    func sidebarFilterUsesSubstringNotAbbreviation() {
        let vm = makeViewModel(defaults: suite.defaults)
        let userProfileView = TestFixtures.makeTableInfo(name: "user_profile_view", type: .view)
        let orders = TestFixtures.makeTableInfo(name: "orders", type: .view)
        vm.searchText = "upv"

        let matches = vm.filteredTables(of: .view, from: [userProfileView, orders])

        #expect(matches.isEmpty)
    }

    @Test("Sidebar filter ranks prefix matches above interior-substring matches")
    func sidebarFilterRanksPrefixFirst() {
        let vm = makeViewModel(defaults: suite.defaults)
        let auditUser = TestFixtures.makeTableInfo(name: "audit_user", type: .table)
        let users = TestFixtures.makeTableInfo(name: "users", type: .table)
        let userLog = TestFixtures.makeTableInfo(name: "user_log", type: .table)
        vm.searchText = "user"

        let matches = vm.filteredTables(of: .table, from: [auditUser, users, userLog])

        #expect(matches.map(\.name) == ["users", "user_log", "audit_user"])
    }

    @Test("filteredRoutines search matches name case insensitively")
    func filteredRoutinesSearch() {
        let vm = makeViewModel(defaults: suite.defaults)
        let getUser = RoutineInfo(name: "GET_USER_BY_ID", kind: .procedure)
        let other = RoutineInfo(name: "log_event", kind: .procedure)
        vm.searchText = "user"

        let procs = vm.filteredRoutines(of: .procedure, from: [getUser, other])

        #expect(procs.map(\.name) == ["GET_USER_BY_ID"])
    }

    @Test("effectiveExpanded honors stored state when search empty")
    func effectiveExpandedRespectsStored() {
        let vm = makeViewModel(defaults: suite.defaults)
        vm.expanded[.view] = false

        #expect(vm.effectiveExpanded(kind: .view, hasMatches: false) == false)
        #expect(vm.effectiveExpanded(kind: .table, hasMatches: false) == true)
    }

    @Test("effectiveExpanded auto-expands when search has matches")
    func effectiveExpandedAutoExpandsOnSearch() {
        let vm = makeViewModel(defaults: suite.defaults)
        vm.expanded[.procedure] = false
        vm.searchText = "user"

        let result = vm.effectiveExpanded(kind: .procedure, hasMatches: true)

        #expect(result == true)
    }

    @Test("effectiveExpanded stays collapsed when search has no matches")
    func effectiveExpandedStaysCollapsedWithoutMatches() {
        let vm = makeViewModel(defaults: suite.defaults)
        vm.expanded[.function] = false
        vm.searchText = "nonexistent"

        let result = vm.effectiveExpanded(kind: .function, hasMatches: false)

        #expect(result == false)
    }

    @Test("default expansion is true for tables only")
    func defaultExpansionTablesOnly() {
        let vm = makeViewModel(defaults: suite.defaults)

        #expect(vm.expanded[.table] == true)
        #expect(vm.expanded[.view] == false)
        #expect(vm.expanded[.materializedView] == false)
        #expect(vm.expanded[.foreignTable] == false)
        #expect(vm.expanded[.procedure] == false)
        #expect(vm.expanded[.function] == false)
    }

    @Test("expansion writes persist to per-kind UserDefaults keys")
    func expansionWritesPersist() {
        let defaults = suite.defaults
        let connectionId = UUID()
        let vm = makeViewModel(connectionId: connectionId, defaults: defaults)
        let key = SidebarPersistenceKey.expanded(connectionId: connectionId, kind: .procedure)

        vm.expanded[.procedure] = true

        #expect(defaults.bool(forKey: key) == true)
    }

    @Test("A declared kind's flat expansion persists under the one per-connection key and restores by id")
    func declaredKindExpansionPersistsUnderOneKey() {
        let defaults = suite.defaults
        let connectionId = UUID()
        let events = SidebarServerObjectKind(
            id: "event", displayName: "Event", pluralDisplayName: "Events", iconName: "calendar.badge.clock", scope: .container
        )
        let vm = makeViewModel(connectionId: connectionId, databaseType: .mysql, defaults: defaults)
        #expect(vm.expanded[.server(events)] == false)

        vm.expanded[.server(events)] = true

        let key = SidebarPersistenceKey.serverKindsExpanded(connectionId: connectionId)
        #expect(defaults.dictionary(forKey: key)?["event"] as? Bool == true)
        #expect(defaults.object(forKey: "sidebar.\(connectionId.uuidString).server.event.expanded") == nil)
        #expect(SidebarPersistenceKey.all(connectionId: connectionId).contains(key))

        let restored = makeViewModel(connectionId: connectionId, databaseType: .mysql, defaults: defaults)
        #expect(restored.expanded[.server(SidebarServerObjectKind(id: "event"))] == true)

        SidebarPersistenceKey.removeAll(connectionId: connectionId, defaults: defaults)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test("Every built-in kind's expansion key is listed for cleanup")
    func builtInExpansionKeysAreListed() {
        let connectionId = UUID()
        let all = SidebarPersistenceKey.all(connectionId: connectionId)
        for kind in SidebarObjectKind.builtIn {
            #expect(all.contains(SidebarPersistenceKey.expanded(connectionId: connectionId, kind: kind)))
        }
        #expect(SidebarPersistenceKey.expanded(connectionId: connectionId, kind: .materializedView)
            == "sidebar.\(connectionId.uuidString).materializedView.expanded")
    }

    @Test("filteredServerObjects narrows by the search and follows each kind on its own")
    func filteredServerObjectsBySearch() {
        let vm = makeViewModel(databaseType: .mysql, defaults: suite.defaults)
        let events = [
            ServerObjectInfo(kindId: "event", name: "nightly_cleanup", schema: "shop"),
            ServerObjectInfo(kindId: "event", name: "hourly_rollup", schema: "shop")
        ]
        #expect(vm.filteredServerObjects(kindId: "event", from: events).count == 2)

        vm.searchText = "nightly"

        #expect(vm.filteredServerObjects(kindId: "event", from: events).map { $0.name } == ["nightly_cleanup"])
        #expect(vm.filteredServerObjects(kindId: "extension", from: []).isEmpty)
    }

    @Test("recents expansion defaults to expanded and persists across init")
    func recentsExpansionPersists() {
        let defaults = suite.defaults
        let connectionId = UUID()
        let key = SidebarPersistenceKey.recentsExpanded(connectionId: connectionId)

        let first = makeViewModel(connectionId: connectionId, defaults: defaults)
        #expect(first.isRecentsExpanded == true)

        first.isRecentsExpanded = false
        #expect(defaults.object(forKey: key) as? Bool == false)

        let second = makeViewModel(connectionId: connectionId, defaults: defaults)
        #expect(second.isRecentsExpanded == false)
    }

    @Test("expansion seeds .table from legacy per-connection key on first init")
    func legacyMigrationFromPerConnectionKey() {
        let defaults = suite.defaults
        let connectionId = UUID()
        let perKindKey = SidebarPersistenceKey.expanded(connectionId: connectionId, kind: .table)
        let legacyKey = SidebarPersistenceKey.tablesExpanded(connectionId: connectionId)
        defaults.set(false, forKey: legacyKey)

        let vm = makeViewModel(connectionId: connectionId, defaults: defaults)

        #expect(vm.expanded[.table] == false)
        #expect(defaults.object(forKey: perKindKey) as? Bool == false)
    }

    @Test("expansion seeds .table from global legacy key when no per-connection key set")
    func legacyMigrationFromGlobalKey() {
        let defaults = suite.defaults
        let connectionId = UUID()
        defaults.set(false, forKey: SidebarPersistenceKey.legacyTablesExpanded)

        let vm = makeViewModel(connectionId: connectionId, defaults: defaults)

        #expect(vm.expanded[.table] == false)
    }
}

/// `$filterQuery` replays its current value to a new subscriber, which `dropFirst` discards.
@MainActor
private final class DebouncedFilterQueries {
    private(set) var published: [String] = []
    private let values: AsyncStream<String>
    private var subscription: AnyCancellable?

    init(of viewModel: SidebarViewModel) {
        let (values, continuation) = AsyncStream<String>.makeStream()
        self.values = values
        subscription = viewModel.$filterQuery.dropFirst().sink { [weak self] value in
            self?.published.append(value)
            continuation.yield(value)
        }
    }

    func first() async -> String? {
        let stream = values
        let arrived = await BoundedCall.result { () -> String? in
            for await value in stream { return value }
            return nil
        }
        return arrived ?? nil
    }
}

@MainActor
struct SidebarViewModelSearchDebounceTests {
    private let suite: EphemeralDefaults
    private let clock = ManualClock()

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeDebouncingViewModel() -> SidebarViewModel {
        makeViewModel(defaults: suite.defaults, clock: clock)
    }

    private func debounceStarted() async throws {
        try await waitUntil { clock.pendingSleeperCount > 0 }
    }

    @Test("filterQuery updates immediately on first non-empty input")
    func filterQueryUpdatesImmediatelyOnFirstInput() {
        let vm = makeDebouncingViewModel()

        vm.searchText = "user"

        #expect(vm.filterQuery == "user")
    }

    @Test("filterQuery clears immediately when search becomes empty")
    func filterQueryClearsImmediatelyOnEmpty() async throws {
        let vm = makeDebouncingViewModel()
        vm.searchText = "user"
        vm.searchText = "users"
        try await debounceStarted()

        vm.searchText = ""

        #expect(vm.filterQuery == "")
    }

    @Test("filterQuery stays at previous value during debounce window")
    func filterQueryHoldsPreviousValueDuringDebounce() async throws {
        let vm = makeDebouncingViewModel()
        vm.searchText = "user"
        #expect(vm.filterQuery == "user")

        vm.searchText = "users"
        try await debounceStarted()

        #expect(vm.filterQuery == "user")
    }

    @Test("filterQuery catches up after debounce window elapses")
    func filterQueryCatchesUpAfterDebounce() async throws {
        let vm = makeDebouncingViewModel()
        vm.searchText = "user"
        let debounced = DebouncedFilterQueries(of: vm)

        vm.searchText = "users"
        try await debounceStarted()
        clock.advance(by: .milliseconds(150))

        #expect(await debounced.first() == "users")
        #expect(vm.filterQuery == "users")
    }

    @Test("rapid consecutive keystrokes collapse to the final value")
    func rapidKeystrokesCollapseToFinalValue() async throws {
        let vm = makeDebouncingViewModel()
        vm.searchText = "u"

        let debounced = DebouncedFilterQueries(of: vm)

        vm.searchText = "us"
        vm.searchText = "use"
        vm.searchText = "user"
        try await debounceStarted()

        #expect(vm.filterQuery == "u")
        clock.advance(by: .milliseconds(150))

        #expect(await debounced.first() == "user")
        #expect(debounced.published == ["user"])
        #expect(vm.filterQuery == "user")
    }

    @Test("filter caches still serve filteredTables using filterQuery, not searchText")
    func filteredTablesHonorsFilterQueryNotSearchText() async throws {
        let vm = makeDebouncingViewModel()
        let users = TestFixtures.makeTableInfo(name: "users", type: .table)
        let userLog = TestFixtures.makeTableInfo(name: "user_log", type: .table)
        let orders = TestFixtures.makeTableInfo(name: "orders", type: .table)
        let mixed = [users, userLog, orders]

        vm.searchText = "user"
        vm.searchText = "users"
        try await debounceStarted()

        let matches = vm.filteredTables(of: .table, from: mixed)

        #expect(matches.map(\.name) == ["users", "user_log"])
    }
}
