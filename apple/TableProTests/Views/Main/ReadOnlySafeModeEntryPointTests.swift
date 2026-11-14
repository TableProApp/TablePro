//
//  ReadOnlySafeModeEntryPointTests.swift
//  TableProTests
//
//  At Read-Only every read the app runs for the user reaches a driver that declares `.enforcesReadOnlyMode` with
//  `enforcesReadOnly` set, so `SELECT purge_orders()`, or a view that calls it, runs in the engine's read-only mode.
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class ReadOnlyRecordingDriver: PluginDriverStub, @unchecked Sendable {
    struct Call: Equatable {
        let entry: String
        let query: String
        let context: PluginStatementContext?
    }

    private let enforcesReadOnlyMode: Bool

    init(enforcesReadOnlyMode: Bool = true) {
        self.enforcesReadOnlyMode = enforcesReadOnlyMode
    }

    var capabilities: PluginCapabilities {
        enforcesReadOnlyMode ? [.readOnlyStatements, .enforcesReadOnlyMode] : [.readOnlyStatements]
    }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func call(containing text: String) -> Call? {
        calls.first { $0.query.contains(text) }
    }

    var entries: [String] {
        calls.map(\.entry)
    }

    private static let answer = PluginQueryResult(
        columns: ["n"], columnTypeNames: ["INT8"], rows: [[.text("1")]], rowsAffected: 0, executionTime: 0
    )

    private func record(_ entry: String, _ query: String, _ context: PluginStatementContext?) -> PluginQueryResult {
        lock.withLock { recorded.append(Call(entry: entry, query: query, context: context)) }
        return Self.answer
    }

    func execute(query: String) async throws -> PluginQueryResult {
        record("execute", query, nil)
    }

    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        record("execute", query, context)
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue],
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        record("executeParameterized", query, context)
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        record("executeUserQuery", query, context)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        record("executeBoundedQuery", query, nil)
    }

    func executeBoundedQuery(
        query: String,
        rowCap: Int,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult? {
        record("executeBoundedQuery", query, context)
    }

    func streamRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        _ = record("streamRows", query, context)
        return AsyncThrowingStream { $0.finish() }
    }

    func beginTransaction() async throws {
        _ = record("BEGIN", "", nil)
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        _ = record("BEGIN", "", nil)
    }

    func commitTransaction() async throws {
        _ = record("COMMIT", "", nil)
    }

    func rollbackTransaction() async throws {
        _ = record("ROLLBACK", "", nil)
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { .idle }

    // DuckDB switches databases in place, so its session route pins the scope's database before every read.
    func switchDatabase(to database: String) async throws {}
}

private final class ReadingExportFormat: ExportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Reading"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Reads every table's rows and writes an empty file"
    static let formatId = "read-only-reading"
    static let formatDisplayName = "Reading"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"

    private(set) var wasAskedToWrite = false

    required init() {}

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        wasAskedToWrite = true
        for table in tables {
            for try await _ in dataSource.streamExportRows(for: table) {}
        }
        try Data().write(to: destination)
        return ExportFormatResult()
    }
}

@MainActor
private final class FixedDriverProvider: ScopedMetadataProviding {
    private let drivers: [UUID: DatabaseDriver]

    init(_ drivers: [UUID: DatabaseDriver]) {
        self.drivers = drivers
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let driver = drivers[scope.connectionId] else {
            throw ObjectCopyError.refused("No driver for \(scope.connectionId)")
        }
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}

@MainActor
struct ReadOnlySafeModeEntryPointTests {
    private static let purge = "purge_orders()"

    private func makeConnection(_ level: SafeModeLevel, type: DatabaseType = .postgresql) -> DatabaseConnection {
        DatabaseConnection(name: "Shop", database: "app", type: type, safeModeLevel: level)
    }

    private func makeFixture(
        _ level: SafeModeLevel,
        type: DatabaseType = .postgresql,
        enforcesReadOnlyMode: Bool = true
    ) -> (CoordinatorFixture, ReadOnlyRecordingDriver) {
        let driver = ReadOnlyRecordingDriver(enforcesReadOnlyMode: enforcesReadOnlyMode)
        let connection = makeConnection(level, type: type)
        let fixture = CoordinatorFixture(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        fixture.coordinator.toolbarState.safeModeLevel = level
        fixture.coordinator.executionGate = AlwaysAllowGate()
        return (fixture, driver)
    }

    private func rawFilterTableTab() -> QueryTab {
        var tab = QueryTab(
            title: "orders",
            query: "SELECT * FROM orders WHERE (purge_orders() IS NULL) LIMIT 100",
            tabType: .table,
            tableName: "orders"
        )
        let filter = TableFilter.rawCondition("purge_orders() IS NULL")
        tab.filterState.filters = [filter]
        tab.filterState.commit = .all
        tab.filterState.executedFilters = [filter]
        tab.filterState.executedLogicMode = .and
        return tab
    }

    // MARK: - Run

    @Test("Run at Read-Only sends the statement in the engine's read-only mode")
    func runCarriesTheMode() async throws {
        let (fixture, driver) = makeFixture(.readOnly)
        defer { fixture.coordinator.cancelAllQueryTasks() }
        fixture.addTab(QueryTab(title: "Query", query: "SELECT purge_orders()", tabType: .query))

        #expect(fixture.coordinator.runStatement("SELECT purge_orders()"))
        try await waitUntil { driver.call(containing: Self.purge) != nil }

        #expect(driver.call(containing: Self.purge)?.context?.enforcesReadOnly == true)
    }

    @Test("Run at Silent sends the statement as it always did")
    func runAtSilentIsUnchanged() async throws {
        let (fixture, driver) = makeFixture(.silent)
        defer { fixture.coordinator.cancelAllQueryTasks() }
        fixture.addTab(QueryTab(title: "Query", query: "SELECT purge_orders()", tabType: .query))

        #expect(fixture.coordinator.runStatement("SELECT purge_orders()"))
        try await waitUntil { driver.call(containing: Self.purge) != nil }

        #expect(driver.call(containing: Self.purge)?.context?.enforcesReadOnly != true)
    }

    // MARK: - Run All

    @Test("Run All at Read-Only opens no transaction and sends each statement in the read-only mode")
    func runAllRunsInAutocommit() async throws {
        let (fixture, driver) = makeFixture(.readOnly)
        defer { fixture.coordinator.cancelAllQueryTasks() }
        fixture.addTab(QueryTab(title: "Query", query: "SELECT purge_orders();\nSELECT 42", tabType: .query))

        fixture.coordinator.queryExecutionCoordinator.runAllStatements()
        try await waitUntil { driver.call(containing: "42") != nil }

        let statements = driver.calls.filter { $0.query.contains(Self.purge) || $0.query.contains("42") }
        #expect(!driver.entries.contains("BEGIN"))
        #expect(statements.count == 2)
        #expect(statements.allSatisfy { $0.context?.enforcesReadOnly == true })
    }

    @Test("Run All at Silent still wraps the batch in the app's transaction")
    func runAllAtSilentWraps() async throws {
        let (fixture, driver) = makeFixture(.silent)
        defer { fixture.coordinator.cancelAllQueryTasks() }
        fixture.addTab(QueryTab(title: "Query", query: "SELECT purge_orders();\nSELECT 42", tabType: .query))

        fixture.coordinator.queryExecutionCoordinator.runAllStatements()
        try await waitUntil { driver.entries.contains("COMMIT") }

        let entries = driver.entries
        let begin = try #require(entries.firstIndex(of: "BEGIN"))
        let first = try #require(driver.calls.firstIndex { $0.query.contains(Self.purge) })
        #expect(begin < first)
        #expect(driver.calls.allSatisfy { $0.context?.enforcesReadOnly != true })
    }

    // MARK: - Table browse

    @Test("A raw filter that calls a function runs in the read-only mode at Read-Only, without the gate, on a driver with it")
    func rawFilterBrowseCarriesTheMode() async throws {
        let (fixture, driver) = makeFixture(.readOnly)
        let gate = RequestRecordingGate(allows: true)
        fixture.coordinator.executionGate = gate
        defer { fixture.coordinator.cancelAllQueryTasks() }
        fixture.addTab(rawFilterTableTab())

        #expect(fixture.coordinator.executeTableTabQueryDirectly(viewport: .firstRow) == nil)
        try await waitUntil { driver.call(containing: Self.purge) != nil }

        #expect(await gate.requests.isEmpty)
        #expect(driver.call(containing: Self.purge)?.context?.enforcesReadOnly == true)
    }

    @Test("On a driver without the mode, every load under the raw filter goes to the gate")
    func rawFilterIsGatedOnEveryRun() async throws {
        let (fixture, driver) = makeFixture(.readOnly, enforcesReadOnlyMode: false)
        let gate = RequestRecordingGate(allows: true)
        fixture.coordinator.executionGate = gate
        defer { fixture.coordinator.cancelAllQueryTasks() }
        let tab = fixture.addTab(rawFilterTableTab())

        let first = fixture.coordinator.executeTableTabQueryDirectly(viewport: .firstRow)
        #expect(first != nil)
        await first?.value
        try await waitUntil { driver.call(containing: Self.purge) != nil }
        let second = fixture.coordinator.executeTableTabQueryDirectly(viewport: .firstRow)
        #expect(second != nil)
        await second?.value

        let browses = await gate.requests.filter { $0.sql == tab.content.query }
        #expect(browses.count == 2)
    }

    // Oracle and Dameng call a function named bare, which only the catalog the gate reads can tell from a column.
    @Test("On Oracle and Dameng every raw filter goes to the gate at Read-Only, parentheses or not", arguments: [
        DatabaseType.oracle, .dameng,
    ])
    func bareNameRawFilterGoesToTheGate(type: DatabaseType) {
        let (fixture, _) = makeFixture(.readOnly, type: type, enforcesReadOnlyMode: false)
        let (postgres, _) = makeFixture(.readOnly, enforcesReadOnlyMode: false)
        let filters = [TableFilter.rawCondition("purge_orders IS NULL")]

        #expect(fixture.coordinator.rawFilterNeedsReadOnlyGate(filters))
        #expect(!postgres.coordinator.rawFilterNeedsReadOnlyGate(filters))
    }

    // A view, or a row security policy, can call a writing function with no call in the browse's text.
    @Test("A table browse with no raw filter runs in the read-only mode at Read-Only without asking")
    func plainBrowseCarriesTheMode() async throws {
        let (fixture, driver) = makeFixture(.readOnly)
        let gate = RequestRecordingGate(allows: true)
        fixture.coordinator.executionGate = gate
        defer { fixture.coordinator.cancelAllQueryTasks() }
        fixture.addTab(QueryTab(title: "order_cleanup", query: "SELECT * FROM order_cleanup LIMIT 100", tabType: .table, tableName: "order_cleanup"))

        #expect(fixture.coordinator.executeTableTabQueryDirectly(viewport: .firstRow) == nil)
        try await waitUntil { driver.call(containing: "FROM order_cleanup") != nil }

        #expect(await gate.requests.isEmpty)
        #expect(driver.call(containing: "FROM order_cleanup")?.context?.enforcesReadOnly == true)
    }

    // MARK: - Filtered count

    @Test("The host's COUNT(*) under a raw filter runs in the read-only mode at Read-Only")
    func hostCountCarriesTheMode() async throws {
        let driver = ReadOnlyRecordingDriver()
        let adapter = PluginDriverAdapter(connection: makeConnection(.readOnly), pluginDriver: driver)
        let filters = [TableFilter.rawCondition("purge_orders() IS NULL")]
        let countSQL = "SELECT COUNT(*) FROM orders WHERE (purge_orders() IS NULL)"

        _ = try await ExactRowCounter.count(
            on: adapter, table: "orders", filters: filters, logicMode: .and, countSQL: countSQL, safeModeIsReadOnly: true
        )
        _ = try await ExactRowCounter.count(
            on: adapter, table: "orders", filters: filters, logicMode: .and, countSQL: countSQL
        )

        #expect(driver.calls.map { $0.context?.enforcesReadOnly == true } == [true, false])
    }

    // DuckDB counts on its session driver, which this test installs; a pooled engine would open a connection of its own.
    @Test("Count Exactly with a raw filter that calls a function runs in the read-only mode without the gate")
    func countExactlyCarriesTheMode() async throws {
        let (fixture, driver) = makeFixture(.readOnly, type: .duckdb)
        let gate = RequestRecordingGate(allows: true)
        fixture.coordinator.executionGate = gate
        defer { fixture.coordinator.cancelAllQueryTasks() }
        fixture.addTab(rawFilterTableTab())

        fixture.coordinator.paginationCoordinator.requestExactRowCount()
        try await waitUntil { driver.call(containing: "COUNT") != nil }

        #expect(await !gate.requests.contains { $0.sql?.contains("COUNT") == true })
        #expect(driver.call(containing: "COUNT")?.context?.enforcesReadOnly == true)
    }

    @Test("Count Exactly with a raw filter that calls a function goes to the gate on a driver without the mode")
    func countExactlyIsGatedWithoutTheMode() async throws {
        let (fixture, driver) = makeFixture(.readOnly, type: .mysql, enforcesReadOnlyMode: false)
        let gate = RequestRecordingGate(allows: false)
        fixture.coordinator.executionGate = gate
        defer { fixture.coordinator.cancelAllQueryTasks() }
        let tab = fixture.addTab(rawFilterTableTab())

        fixture.coordinator.paginationCoordinator.requestExactRowCount()
        try await waitUntil {
            fixture.tabManager.tabs.first { $0.id == tab.id }?.pagination.isCountingExact == false
        }

        #expect(await gate.requests.contains { $0.sql?.contains("COUNT") == true })
        #expect(driver.call(containing: "COUNT") == nil)
    }

    // MARK: - Export

    @Test("Every export read runs in the read-only mode at Read-Only, filtered or not, and Silent changes nothing")
    func exportRowScopeCarriesTheMode() async throws {
        let driver = ReadOnlyRecordingDriver()
        let adapter = PluginDriverAdapter(connection: makeConnection(.readOnly), pluginDriver: driver)
        let filtered = PluginExportTable(
            name: "orders", databaseName: "", tableType: "table", schema: nil, kind: .table,
            rowScope: PluginExportRowScope(filter: "purge_orders() IS NULL")
        )
        let limited = PluginExportTable(
            name: "orders", databaseName: "", tableType: "table", schema: nil, kind: .table,
            rowScope: PluginExportRowScope(rowLimit: 5)
        )

        let atReadOnly = ExportDataSourceAdapter(driver: adapter, databaseType: .postgresql, safeModeIsReadOnly: true)
        for try await _ in atReadOnly.streamExportRows(for: filtered) {}
        for try await _ in atReadOnly.streamExportRows(for: limited) {}
        let atSilent = ExportDataSourceAdapter(driver: adapter, databaseType: .postgresql)
        for try await _ in atSilent.streamExportRows(for: filtered) {}

        #expect(driver.calls.map { $0.context?.enforcesReadOnly == true } == [true, true, false])
        #expect(driver.calls.first?.query.contains(Self.purge) == true)
    }

    @Test("At Read-Only an export's snapshot transaction is not opened, and its other statements run read-only")
    func exportSnapshotIsSkippedAtReadOnly() async throws {
        let driver = ReadOnlyRecordingDriver()
        let adapter = PluginDriverAdapter(connection: makeConnection(.readOnly), pluginDriver: driver)
        let atReadOnly = ExportDataSourceAdapter(driver: adapter, databaseType: .postgresql, safeModeIsReadOnly: true)

        _ = try await atReadOnly.execute(query: "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        _ = try await atReadOnly.execute(query: "SELECT 1")
        _ = try await atReadOnly.execute(query: "COMMIT")

        #expect(driver.calls.map { $0.query } == ["SELECT 1"])
        #expect(driver.calls.first?.context?.enforcesReadOnly == true)
    }

    private func installReadOnlySession(type: DatabaseType = .postgresql) -> (DatabaseConnection, ReadOnlyRecordingDriver, PluginDriverAdapter) {
        installSession(.readOnly, type: type)
    }

    private func installSession(
        _ level: SafeModeLevel,
        type: DatabaseType = .postgresql,
        id: UUID = UUID()
    ) -> (DatabaseConnection, ReadOnlyRecordingDriver, PluginDriverAdapter) {
        let driver = ReadOnlyRecordingDriver()
        let connection = DatabaseConnection(id: id, name: "Shop", database: "app", type: type, safeModeLevel: level)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        var session = ConnectionSession(connection: connection, driver: adapter)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver, adapter)
    }

    private func exportURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
    }

    @Test("A filtered export at Read-Only asks the gate with its filter before any count or row is read")
    func filteredExportAsksTheGateFirst() async throws {
        let (connection, driver, adapter) = installReadOnlySession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let format = ReadingExportFormat()
        let service = ExportService(driver: adapter, databaseType: .postgresql) { _ in format }
        let gate = RequestRecordingGate(allows: false)
        service.executionGate = gate
        var item = ExportObjectItem(name: "orders", kind: .table)
        item.rowScope = PluginExportRowScope(filter: "purge_orders() IS NULL")
        var config = ExportConfiguration()
        config.formatId = ReadingExportFormat.formatId
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ExecutionGateError.self) {
            try await service.export(objects: [item], config: config, to: url)
        }

        let requests = await gate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.connectionId == connection.id)
        #expect(requests.first?.sql?.contains(Self.purge) == true)
        #expect(driver.calls.isEmpty)
        #expect(!format.wasAskedToWrite)
    }

    @Test("An export at Read-Only counts and reads its rows in the read-only mode")
    func exportCountAndRowsCarryTheMode() async throws {
        let (connection, driver, adapter) = installReadOnlySession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let format = ReadingExportFormat()
        let service = ExportService(driver: adapter, databaseType: .postgresql) { _ in format }
        service.executionGate = AlwaysAllowGate()
        var config = ExportConfiguration()
        config.formatId = ReadingExportFormat.formatId
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await service.export(objects: [ExportObjectItem(name: "order_cleanup", kind: .table)], config: config, to: url)

        let count = try #require(driver.call(containing: "COUNT("))
        let rows = try #require(driver.calls.first { $0.entry == "streamRows" })
        #expect(count.context?.enforcesReadOnly == true)
        #expect(rows.context?.enforcesReadOnly == true)
    }

    @Test("Export Query Results at Read-Only asks the gate with its query before it runs")
    func queryExportAsksTheGateFirst() async throws {
        let (connection, driver, adapter) = installReadOnlySession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let format = ReadingExportFormat()
        let service = ExportService(driver: adapter, databaseType: .postgresql) { _ in format }
        let gate = RequestRecordingGate(allows: false)
        service.executionGate = gate
        var config = ExportConfiguration()
        config.formatId = ReadingExportFormat.formatId
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ExecutionGateError.self) {
            try await service.exportStreamingQuery(query: "SELECT purge_orders()", config: config, to: url)
        }

        #expect(await gate.requests.map { $0.sql } == ["SELECT purge_orders()"])
        #expect(driver.calls.isEmpty)
        #expect(!format.wasAskedToWrite)
    }

    @Test("Transfer To at Read-Only asks the gate with the source filter before anything else")
    func transferFilterAsksTheGateFirst() async throws {
        let (connection, _, _) = installReadOnlySession()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let gate = RequestRecordingGate(allows: false)
        var item = ExportObjectItem(name: "orders", kind: .table)
        item.rowScope = PluginExportRowScope(filter: "purge_orders() IS NULL")
        let request = TableTransferService.Request(objects: [item], sourceType: .postgresql, destinationType: .mysql)

        await #expect(throws: ExecutionGateError.self) {
            try await TableTransferService().run(
                request: request,
                source: DatabaseScope(connectionId: connection.id, database: "app", schema: nil),
                destination: DatabaseScope(connectionId: UUID(), database: "archive", schema: nil),
                operationDescription: "Transfer 1 table into archive?",
                confirmedByCaller: false,
                gate: gate
            )
        }

        let requests = await gate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.connectionId == connection.id)
        #expect(requests.first?.sql?.contains(Self.purge) == true)
    }

    // The gate's own decision on a fallback engine held at Read-Only: the export is refused without a question.
    @Test("A held Read-Only refuses an export filter that calls a function on a driver without the mode")
    func heldReadOnlyRefusesAnExportFilter() async throws {
        let (connection, driver, adapter) = installReadOnlySession(type: .oracle)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let format = ReadingExportFormat()
        let service = ExportService(driver: adapter, databaseType: .oracle) { _ in format }
        let confirm = StubConfirming(answer: true)
        service.executionGate = DefaultExecutionGate(
            confirming: confirm,
            authenticating: StubAuthenticating(answer: true),
            safeModeLevelResolver: { _ in .readOnly },
            forcesWriteResolver: { _ in false },
            readOnlyFunctionPolicyResolver: { _, _ in ReadOnlyFunctionPolicy(functionsCanWrite: true, floor: .readOnly) }
        )
        var item = ExportObjectItem(name: "ORDERS", kind: .table)
        item.rowScope = PluginExportRowScope(filter: "purge_orders() = 1")
        var config = ExportConfiguration()
        config.formatId = ReadingExportFormat.formatId
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ExecutionGateError.self) {
            try await service.export(objects: [item], config: config, to: url)
        }

        #expect(confirm.callCount == 0)
        #expect(driver.calls.isEmpty)
    }

    // MARK: - Dashboard

    @Test("A dashboard tile runs its saved query in the read-only mode at Read-Only")
    func dashboardTileCarriesTheMode() async throws {
        let driver = ReadOnlyRecordingDriver()
        let connection = makeConnection(.readOnly)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let suite = try EphemeralDefaults()
        let defaults = suite.defaults
        let saved = SQLFavorite(name: "Purge", query: "SELECT purge_orders()")
        let viewModel = ServerDashboardViewModel(
            connectionId: connection.id,
            databaseType: .postgresql,
            services: .live,
            tileEnvironment: DashboardTileBoard.Environment(
                loadCatalog: { _ in DashboardSavedQueryCatalog(favorites: [saved], folders: []) },
                savedQueriesDidChange: Empty<UUID?, Never>().eraseToAnyPublisher(),
                gate: AlwaysAllowGate(),
                forcesWrite: { _ in false },
                safeModeLevel: { _ in .readOnly },
                chartsAvailable: { false },
                nullDisplay: { "NULL" },
                storage: ServerDashboardTileStorage(defaults: { defaults })
            )
        )

        viewModel.tileBoard.add(favoriteId: saved.id)
        try await waitUntil { driver.call(containing: Self.purge) != nil }

        let call = driver.call(containing: Self.purge)
        #expect(call?.entry == "executeBoundedQuery")
        #expect(call?.context?.enforcesReadOnly == true)
    }

    // MARK: - Driver without the mode

    @Test("A raw filter that calls a function is refused at Read-Only on a driver without the mode, with no question")
    func rawFilterIsRefusedWithoutTheMode() async throws {
        let (fixture, driver) = makeFixture(.readOnly, enforcesReadOnlyMode: false)
        let confirm = StubConfirming(answer: true)
        fixture.coordinator.executionGate = DefaultExecutionGate(
            confirming: confirm,
            authenticating: StubAuthenticating(answer: true),
            safeModeLevelResolver: { _ in .readOnly },
            forcesWriteResolver: { _ in false },
            readOnlyFunctionPolicyResolver: { _, _ in ReadOnlyFunctionPolicy(functionsCanWrite: true) }
        )
        defer { fixture.coordinator.cancelAllQueryTasks() }
        fixture.addTab(rawFilterTableTab())

        let refusal = fixture.coordinator.executeTableTabQueryDirectly(viewport: .firstRow)
        #expect(refusal != nil)
        await refusal?.value

        #expect(confirm.callCount == 0)
        #expect(driver.call(containing: Self.purge) == nil)
    }

    // MARK: - Data Compare

    private func compareEndpoint(_ connection: DatabaseConnection) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil),
            connectionName: connection.name,
            databaseType: connection.type,
            safeModeLevel: connection.safeModeLevel,
            color: .blue
        )
    }

    private func comparePlan(sourceFilter: String = "") -> DataComparePlan {
        DataComparePlan(
            table: "orders",
            schema: nil,
            columns: [CompareColumn(name: "id", sourceType: "INTEGER")],
            scope: DataTableScope(keyColumns: ["id"], sourceFilter: sourceFilter),
            isEnabled: true
        )
    }

    // DuckDB reads both sides on the session drivers this test installs; a pooled engine would open connections of its own.
    @Test("Data Compare reads the Read-Only side in the read-only mode, and the other side as before")
    func compareReadsTheReadOnlySideReadOnly() async throws {
        let (source, sourceDriver, _) = installSession(.readOnly, type: .duckdb)
        let (target, targetDriver, _) = installSession(.silent, type: .duckdb)
        defer {
            DatabaseManager.shared.removeSession(for: source.id)
            DatabaseManager.shared.removeSession(for: target.id)
        }
        let service = CompareRowService(manager: .shared, gate: AlwaysAllowGate())

        _ = try? await service.compare(
            plan: comparePlan(),
            source: compareEndpoint(source), sourceConnection: source,
            target: compareEndpoint(target), targetConnection: target,
            options: DataCompareOptions()
        )

        let read = try #require(sourceDriver.call(containing: "orders"))
        #expect(read.context?.enforcesReadOnly == true)
        #expect(targetDriver.calls.allSatisfy { $0.context?.enforcesReadOnly != true })
    }

    @Test("A Data Compare filter on a Read-Only connection asks the gate before either side is read")
    func compareFilterAsksTheGateFirst() async throws {
        let (source, sourceDriver, _) = installSession(.readOnly, type: .duckdb)
        let (target, targetDriver, _) = installSession(.silent, type: .duckdb)
        defer {
            DatabaseManager.shared.removeSession(for: source.id)
            DatabaseManager.shared.removeSession(for: target.id)
        }
        let gate = RequestRecordingGate(allows: false)
        let service = CompareRowService(manager: .shared, gate: gate)

        await #expect(throws: ExecutionGateError.self) {
            _ = try await service.compare(
                plan: self.comparePlan(sourceFilter: "purge_orders() IS NULL"),
                source: self.compareEndpoint(source), sourceConnection: source,
                target: self.compareEndpoint(target), targetConnection: target,
                options: DataCompareOptions()
            )
        }

        let requests = await gate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.connectionId == source.id)
        #expect(requests.first?.sql?.contains(Self.purge) == true)
        #expect(sourceDriver.call(containing: "orders") == nil)
        #expect(targetDriver.call(containing: "orders") == nil)
    }

    // MARK: - Copy Objects

    private func copyRequest(source: DatabaseConnection, target: DatabaseConnection) -> ObjectCopyRequest {
        ObjectCopyRequest(
            source: compareEndpoint(source),
            destination: .existing(compareEndpoint(target)),
            objects: [ObjectCopySelection(kind: .table, name: "order_cleanup", schema: nil)],
            content: .data,
            existingPolicy: .replace,
            errorHandling: .stopAndRollback,
            wrapEachTableInTransaction: true
        )
    }

    private func copyPlan(source: DatabaseConnection, target: DatabaseConnection, query: String, filtered: Bool) -> ObjectCopyPlan {
        let step = ObjectCopyTableStep(
            selection: ObjectCopySelection(kind: .table, name: "order_cleanup", schema: nil),
            dropStatements: [],
            sequenceStatements: [],
            createStatements: [],
            truncateStatements: [],
            columns: ["id"],
            primaryKeyColumns: ["id"],
            sourceQuery: query,
            targetTable: "order_cleanup",
            targetSchema: nil,
            estimatedRows: nil,
            copiesData: true,
            copiesIdentityColumn: false,
            hasRowFilter: filtered,
            note: nil
        )
        return ObjectCopyPlan(
            request: copyRequest(source: source, target: target),
            createsDatabase: false,
            tableSteps: [step],
            definitionSteps: [],
            keysInside: ObjectCopyKeysInside(created: true, rows: true)
        )
    }

    @Test("Copy Objects reads a Read-Only source, a view among them, in the read-only mode")
    func objectCopyReadsTheSourceReadOnly() async throws {
        let (source, sourceDriver, sourceAdapter) = installSession(.readOnly)
        let target = DatabaseConnection(name: "Archive", database: "archive", type: .mysql)
        let targetAdapter = PluginDriverAdapter(connection: target, pluginDriver: ReadOnlyRecordingDriver())
        defer { DatabaseManager.shared.removeSession(for: source.id) }
        let runner = ObjectCopyRunner(
            manager: FixedDriverProvider([source.id: sourceAdapter, target.id: targetAdapter]),
            gate: AlwaysAllowGate()
        )

        _ = try await runner.run(
            copyPlan(source: source, target: target, query: "SELECT id FROM order_cleanup", filtered: false),
            progress: ObjectCopyProgress(progress: Progress())
        )

        let read = try #require(sourceDriver.call(containing: "order_cleanup"))
        #expect(read.context?.enforcesReadOnly == true)
    }

    @Test("A Copy Objects row filter on a Read-Only source asks the gate before anything runs")
    func objectCopyFilterAsksTheGateFirst() async throws {
        let (source, sourceDriver, sourceAdapter) = installSession(.readOnly)
        let target = DatabaseConnection(name: "Archive", database: "archive", type: .mysql)
        let targetAdapter = PluginDriverAdapter(connection: target, pluginDriver: ReadOnlyRecordingDriver())
        defer { DatabaseManager.shared.removeSession(for: source.id) }
        let gate = RequestRecordingGate(allows: false)
        let runner = ObjectCopyRunner(
            manager: FixedDriverProvider([source.id: sourceAdapter, target.id: targetAdapter]),
            gate: gate
        )
        let query = "SELECT id FROM order_cleanup WHERE purge_orders() IS NULL"

        await #expect(throws: ExecutionGateError.self) {
            _ = try await runner.run(
                self.copyPlan(source: source, target: target, query: query, filtered: true),
                progress: ObjectCopyProgress(progress: Progress())
            )
        }

        #expect(await gate.requests.map { $0.sql } == [query])
        #expect(await gate.requests.first?.connectionId == source.id)
        #expect(sourceDriver.call(containing: "order_cleanup") == nil)
    }
}
