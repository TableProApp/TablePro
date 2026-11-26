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

    // SidebarView hands the bindings over on every evaluation of its parent, so a publish here redraws the sidebar.
    @Test("Handing over new bindings publishes nothing, and reads go through the new ones")
    @MainActor
    func updateBindingsPublishesNothing() {
        let (vm, _, _, _) = makeSUT()
        var published = 0
        let observation = vm.objectWillChange.sink { published += 1 }
        let table = makeRef("users")
        var truncates: Set<DatabaseTreeTableRef> = [table]
        vm.updateBindings(
            pendingTruncates: Binding(get: { truncates }, set: { truncates = $0 }),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:])
        )
        observation.cancel()
        #expect(published == 0)
        #expect(vm.pendingTruncates == [table])
    }

    @Test("A container's remembered verdict follows its query")
    @MainActor
    func containerBucketsMemoizeBySource() {
        let (vm, _, _, _) = makeSUT()
        let tables = [TestFixtures.makeTableInfo(name: "users"), TestFixtures.makeTableInfo(name: "orders")]
        func source(_ rows: [TableInfo], _ query: String) -> DatabaseTreeBucketSource {
            DatabaseTreeBucketSource(tables: rows, routines: [], triggers: [], userTypes: [], searchText: query, database: "db")
        }
        let first = vm.containerBuckets(database: "db", schema: nil, source: source(tables, "us"))
        #expect(first.tables.values.flatMap { $0 }.map(\.name) == ["users"])
        let again = vm.containerBuckets(database: "db", schema: nil, source: source(tables, "us"))
        #expect(again.tables.values.flatMap { $0 }.map(\.name) == ["users"])
        let narrowed = vm.containerBuckets(database: "db", schema: nil, source: source(tables, "ord"))
        #expect(narrowed.tables.values.flatMap { $0 }.map(\.name) == ["orders"])
    }

    @Test("Clearing the search lets go of the rows a container's verdict held")
    @MainActor
    func clearingTheSearchReleasesContainerRows() {
        let (vm, _, _, _) = makeSUT()
        var tables = [TestFixtures.makeTableInfo(name: "users"), TestFixtures.makeTableInfo(name: "orders")]
        vm.searchText = "us"
        _ = vm.containerBuckets(
            database: "db",
            schema: nil,
            source: DatabaseTreeBucketSource(
                tables: tables, routines: [], triggers: [], userTypes: [], searchText: "us", database: "db"
            )
        )

        vm.searchText = ""

        // A write moves the buffer only while another holder shares it.
        let shared = tables.withUnsafeBufferPointer { $0.baseAddress }
        tables[0] = tables[0]
        #expect(tables.withUnsafeBufferPointer { $0.baseAddress } == shared)
    }

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
    clock: any Clock<Duration> = ContinuousClock(),
    turns: TurnEnds? = nil
) -> SidebarViewModel {
    var truncates: Set<DatabaseTreeTableRef> = []
    var deletes: Set<DatabaseTreeTableRef> = []
    var options: [DatabaseTreeTableRef: TableOperationOptions] = [:]
    let truncatesBinding = Binding(get: { truncates }, set: { truncates = $0 })
    let deletesBinding = Binding(get: { deletes }, set: { deletes = $0 })
    let optionsBinding = Binding(get: { options }, set: { options = $0 })
    let onTurnEnd: @MainActor (@escaping @MainActor () -> Void) -> Void
    if let turns {
        onTurnEnd = { turns.schedule($0) }
    } else {
        onTurnEnd = RunLoopTurn.onEnd
    }
    return SidebarViewModel(
        pendingTruncates: truncatesBinding,
        pendingDeletes: deletesBinding,
        tableOperationOptions: optionsBinding,
        databaseType: databaseType,
        connectionId: connectionId,
        defaults: defaults,
        clock: clock,
        onTurnEnd: onTurnEnd
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

    @Test("A side list replaced by as many rows is filtered again before the catalog generation moves")
    func sameCountReplacementIsFilteredAgain() {
        let vm = makeViewModel(defaults: suite.defaults)

        #expect(vm.filteredRoutines(of: .function, from: [RoutineInfo(name: "old_total", kind: .function)]).map(\.name) == ["old_total"])
        #expect(vm.filteredRoutines(of: .function, from: [RoutineInfo(name: "new_total", kind: .function)]).map(\.name) == ["new_total"])

        let oldTrigger = TriggerInfo(name: "old_audit", timing: "BEFORE", event: "INSERT", statement: "")
        let newTrigger = TriggerInfo(name: "new_audit", timing: "BEFORE", event: "INSERT", statement: "")
        #expect(vm.filteredTriggers(from: [oldTrigger]).map(\.name) == ["old_audit"])
        #expect(vm.filteredTriggers(from: [newTrigger]).map(\.name) == ["new_audit"])

        #expect(vm.filteredUserTypes(from: [UserDefinedTypeInfo(name: "old_mood", kind: .enumeration)]).map(\.name) == ["old_mood"])
        #expect(vm.filteredUserTypes(from: [UserDefinedTypeInfo(name: "new_mood", kind: .enumeration)]).map(\.name) == ["new_mood"])

        let oldEvent = ServerObjectInfo(kindId: "event", name: "old_job")
        let newEvent = ServerObjectInfo(kindId: "event", name: "new_job")
        #expect(vm.filteredServerObjects(kindId: "event", from: [oldEvent]).map(\.name) == ["old_job"])
        #expect(vm.filteredServerObjects(kindId: "event", from: [newEvent]).map(\.name) == ["new_job"])

        let oldTable = TableInfo(name: "old_orders", type: .table, rowCount: nil)
        let newTable = TableInfo(name: "new_orders", type: .table, rowCount: nil)
        #expect(vm.filteredTables(of: .table, from: [oldTable]).map(\.name) == ["old_orders"])
        #expect(vm.filteredTables(of: .table, from: [newTable]).map(\.name) == ["new_orders"])
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

/// Stands in for the end of the main run loop's turn, which a case ends by hand.
@MainActor
private final class TurnEnds {
    private var bodies: [@MainActor () -> Void] = []

    var pending: Int { bodies.count }

    func schedule(_ body: @escaping @MainActor () -> Void) {
        bodies.append(body)
    }

    func end() {
        let due = bodies
        bodies = []
        for body in due { body() }
    }
}

@MainActor
struct SidebarViewModelSearchDebounceTests {
    private let suite: EphemeralDefaults
    private let clock = ManualClock()
    private let turns = TurnEnds()

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeDebouncingViewModel() -> SidebarViewModel {
        makeViewModel(defaults: suite.defaults, clock: clock, turns: turns)
    }

    private func debounceStarted() async throws {
        try await waitUntil { clock.pendingSleeperCount > 0 }
    }

    /// Types `query` into an empty field and reports that the outline's rebuild for it took `cost`,
    /// ending at the clock's new time.
    private func applyFirstKey(_ query: String, to vm: SidebarViewModel, costing cost: Duration) {
        vm.searchText = query
        vm.noteSearchRebuild(for: query)
        clock.advance(by: cost)
        turns.end()
    }

    /// The shared state's sink hops one run loop turn, so this waits for writes made before it.
    private func deliverSharedStateChanges() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
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
        applyFirstKey("user", to: vm, costing: .milliseconds(400))
        vm.searchText = "users"
        try await debounceStarted()

        vm.searchText = ""

        #expect(vm.filterQuery == "")
    }

    @Test("filterQuery stays at previous value while a slow refresh's cost has not passed")
    func filterQueryHoldsPreviousValueAfterSlowRefresh() async throws {
        let vm = makeDebouncingViewModel()
        applyFirstKey("user", to: vm, costing: .milliseconds(400))
        #expect(vm.filterQuery == "user")

        vm.searchText = "users"
        try await debounceStarted()

        #expect(vm.filterQuery == "user")
    }

    @Test("filterQuery catches up once a slow refresh's capped cost has passed")
    func filterQueryCatchesUpAfterSlowRefresh() async throws {
        let vm = makeDebouncingViewModel()
        applyFirstKey("user", to: vm, costing: .milliseconds(400))
        let debounced = DebouncedFilterQueries(of: vm)

        vm.searchText = "users"
        try await debounceStarted()
        clock.advance(by: .milliseconds(149))
        #expect(vm.filterQuery == "user")
        clock.advance(by: .milliseconds(1))

        #expect(await debounced.first() == "users")
        #expect(vm.filterQuery == "users")
    }

    @Test("rapid consecutive keystrokes after a slow refresh collapse to the final value")
    func rapidKeystrokesCollapseToFinalValue() async throws {
        let vm = makeDebouncingViewModel()
        applyFirstKey("u", to: vm, costing: .milliseconds(400))

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

        applyFirstKey("user", to: vm, costing: .milliseconds(400))
        vm.searchText = "users"
        try await debounceStarted()

        let matches = vm.filteredTables(of: .table, from: mixed)

        #expect(matches.map(\.name) == ["users", "user_log"])
    }

    @Test("After a fast refresh the next key applies in its own turn")
    func fastRefreshAppliesNextKeyAtOnce() {
        let vm = makeDebouncingViewModel()
        applyFirstKey("user", to: vm, costing: .milliseconds(20))
        clock.advance(by: .milliseconds(30))

        vm.searchText = "users"

        #expect(vm.filterQuery == "users")
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test("A key 10 ms after a 90 ms refresh applies 80 ms later")
    func keyWaitsTheRestOfTheLastRefresh() async throws {
        let vm = makeDebouncingViewModel()
        applyFirstKey("user", to: vm, costing: .milliseconds(90))
        clock.advance(by: .milliseconds(10))

        vm.searchText = "users"
        try await debounceStarted()
        clock.advance(by: .milliseconds(79))
        #expect(vm.filterQuery == "user")

        let debounced = DebouncedFilterQueries(of: vm)
        clock.advance(by: .milliseconds(1))
        #expect(await debounced.first() == "users")
    }

    @Test("A shared state write while a key waits does not move the moment it applies")
    func unrelatedSharedStateWriteKeepsTheWait() async throws {
        let vm = makeDebouncingViewModel()
        applyFirstKey("user", to: vm, costing: .milliseconds(90))
        vm.searchText = "users"
        try await debounceStarted()
        clock.advance(by: .milliseconds(50))

        vm.sharedState.favoritesSearchText = "unrelated"
        await deliverSharedStateChanges()
        #expect(clock.pendingSleeperCount == 1)

        let debounced = DebouncedFilterQueries(of: vm)
        clock.advance(by: .milliseconds(40))
        #expect(await debounced.first() == "users")
    }

    @Test("Typing back to the shown query cancels the waiting key")
    func typingBackCancelsTheWait() async throws {
        let vm = makeDebouncingViewModel()
        applyFirstKey("user", to: vm, costing: .milliseconds(400))
        let debounced = DebouncedFilterQueries(of: vm)

        vm.searchText = "users"
        try await debounceStarted()
        vm.searchText = "user"

        try await waitUntil { clock.pendingSleeperCount == 0 }
        clock.advance(by: .milliseconds(150))
        await deliverSharedStateChanges()
        #expect(debounced.published.isEmpty)
        #expect(vm.filterQuery == "user")
    }

    @Test("Two outlines rebuilding for one query record one cost, timed from the write")
    func twoOutlinesRecordOneCost() async throws {
        let vm = makeDebouncingViewModel()
        vm.searchText = "user"
        vm.noteSearchRebuild(for: "user")
        vm.noteSearchRebuild(for: "user")
        #expect(turns.pending == 1)
        clock.advance(by: .milliseconds(90))
        turns.end()
        clock.advance(by: .milliseconds(10))

        vm.searchText = "users"
        try await debounceStarted()
        clock.advance(by: .milliseconds(79))
        #expect(vm.filterQuery == "user")

        let debounced = DebouncedFilterQueries(of: vm)
        clock.advance(by: .milliseconds(1))
        #expect(await debounced.first() == "users")
    }

    @Test("A rebuild in a later turn than the write is timed from the rebuild")
    func laterRebuildIsTimedFromTheRebuild() async throws {
        let vm = makeDebouncingViewModel()
        vm.searchText = "user"
        turns.end()
        clock.advance(by: .milliseconds(500))

        vm.noteSearchRebuild(for: "user")
        clock.advance(by: .milliseconds(40))
        turns.end()
        clock.advance(by: .milliseconds(10))

        vm.searchText = "users"
        try await debounceStarted()
        clock.advance(by: .milliseconds(29))
        #expect(vm.filterQuery == "user")

        let debounced = DebouncedFilterQueries(of: vm)
        clock.advance(by: .milliseconds(1))
        #expect(await debounced.first() == "users")
    }
}
