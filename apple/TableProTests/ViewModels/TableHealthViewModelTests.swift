import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private struct Offline: LocalizedError {
    var errorDescription: String? { "No active connection" }
}

private struct DiskFull: LocalizedError {
    var errorDescription: String? { "The disk is full" }
}

// Answers the missing primary key check with the given tables and every other read with nothing.
// The driver runs off the main actor, so the state is locked rather than isolated.
private final class HealthServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _tablesWithoutKey = ["logs"]
    private var _tableBytes: [String: Int64] = [:]
    private var _failsMissingKeyCheck = false
    private var _queries: [String] = []
    private var _catalogReadFlags: [Bool] = []

    var tablesWithoutKey: [String] {
        get { lock.withLock { _tablesWithoutKey } }
        set { lock.withLock { _tablesWithoutKey = newValue } }
    }

    var tableBytes: [String: Int64] {
        get { lock.withLock { _tableBytes } }
        set { lock.withLock { _tableBytes = newValue } }
    }

    var failsMissingKeyCheck: Bool {
        get { lock.withLock { _failsMissingKeyCheck } }
        set { lock.withLock { _failsMissingKeyCheck = newValue } }
    }

    var queries: [String] { lock.withLock { _queries } }

    var catalogReadFlags: [Bool] { lock.withLock { _catalogReadFlags } }

    func noteContext(_ context: PluginStatementContext) {
        lock.withLock { _catalogReadFlags.append(context.readsCatalog) }
    }

    func answer(_ query: String) throws -> PluginQueryResult {
        let (tables, bytes, fails) = lock.withLock { () -> ([String], [String: Int64], Bool) in
            _queries.append(query)
            return (_tablesWithoutKey, _tableBytes, _failsMissingKeyCheck)
        }
        guard query == PostgreSQLTableHealthProvider.missingPrimaryKeyQuery else {
            return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }
        if fails { throw Offline() }
        return PluginQueryResult(
            columns: ["schema_name", "table_name", "table_bytes"],
            columnTypeNames: ["TEXT", "TEXT", "INT8"],
            rows: tables.map { table in
                [.text("public"), .text(table), bytes[table].map { PluginCellValue.text(String($0)) } ?? PluginCellValue.null]
            },
            rowsAffected: 0,
            executionTime: 0
        )
    }
}

private final class HealthPluginDriver: PluginDriverStub, @unchecked Sendable {
    private let server: HealthServer

    init(server: HealthServer) {
        self.server = server
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try server.answer(query)
    }

    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        server.noteContext(context)
        return try server.answer(query)
    }
}

@MainActor
private final class HealthMetadata: ScopedMetadataProviding {
    let server = HealthServer()
    let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
    // The sidebar's database, which a Table Health tab never reads.
    var browsedDatabase = "archive"
    var leaseFails = false
    // Holds the next lease until the test releases it, the way a slow catalog read holds one.
    var hold: (reached: AsyncGate, release: AsyncGate)?
    private(set) var leases: [(scope: DatabaseScope, workload: MetadataConnectionPool.Workload)] = []

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        leases.append((scope, workload))
        if let hold {
            self.hold = nil
            await hold.reached.open()
            await hold.release.wait()
        }
        if leaseFails { throw Offline() }
        return try await body(PluginDriverAdapter(connection: connection, pluginDriver: HealthPluginDriver(server: server)))
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        DatabaseScope(connectionId: connectionId, database: browsedDatabase, schema: "public")
    }
}

// Keeps ledgers in memory and posts the change the way the real store does.
@MainActor
private final class InMemoryHistory: TableHealthHistoryStoring {
    var ledgers: [String: TableHealthLedger] = [:]
    var failsWrites = false
    private(set) var recordCount = 0

    func ledger(connectionId: UUID, database: String) throws -> TableHealthLedger {
        ledgers[database] ?? TableHealthLedger()
    }

    func record(_ report: TableHealthReport, connectionId: UUID, database: String, at date: Date) throws -> TableHealthLedger {
        try save(connectionId: connectionId, database: database) { ledger in
            recordCount += 1
            return ledger.recording(report, at: date)
        }
    }

    func setIgnored(
        _ ids: Set<TableHealthFindingID>,
        ignored: Bool,
        connectionId: UUID,
        database: String,
        at date: Date
    ) throws -> TableHealthLedger {
        try save(connectionId: connectionId, database: database) { ledger in
            ignored ? ledger.ignoring(ids, at: date) : ledger.unignoring(ids)
        }
    }

    func clearResolved(connectionId: UUID, database: String) throws -> TableHealthLedger {
        try save(connectionId: connectionId, database: database) { $0.clearingResolved() }
    }

    private func save(
        connectionId: UUID,
        database: String,
        _ change: (TableHealthLedger) -> TableHealthLedger
    ) throws -> TableHealthLedger {
        if failsWrites { throw DiskFull() }
        let next = change(ledgers[database] ?? TableHealthLedger())
        ledgers[database] = next
        NotificationCenter.default.post(
            name: .tableHealthHistoryDidChange,
            object: nil,
            userInfo: TableHealthHistoryChange.userInfo(connectionId: connectionId, database: database)
        )
        return next
    }
}

@MainActor
private final class BoundDatabase {
    var name: String

    init(_ name: String) {
        self.name = name
    }
}

@MainActor
struct TableHealthViewModelTests {
    private func makeViewModel(
        _ metadata: HealthMetadata,
        history: InMemoryHistory = InMemoryHistory(),
        database: BoundDatabase = BoundDatabase("shop"),
        databaseType: DatabaseType = .postgresql
    ) -> TableHealthViewModel {
        TableHealthViewModel(
            connectionId: metadata.connection.id,
            provider: TableHealthProviderFactory.provider(for: databaseType),
            history: history,
            metadata: metadata,
            database: { database.name }
        )
    }

    private func row(_ viewModel: TableHealthViewModel, table: String) -> TableHealthFindingRow? {
        viewModel.findingRows.first { $0.id.table == table }
    }

    @Test("An engine without a provider is not supported and reads nothing")
    func unsupportedEngine() async {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata, databaseType: .sqlite)

        await viewModel.refresh()

        #expect(!viewModel.isSupported)
        #expect(viewModel.report == nil)
        #expect(metadata.leases.isEmpty)
    }

    @Test("A refresh reads the tab's own database in one bulk lease, whatever the sidebar browses")
    func oneLeaseOnTheTabDatabase() async throws {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)

        await viewModel.refresh()

        let lease = try #require(metadata.leases.first)
        #expect(metadata.leases.count == 1)
        #expect(lease.scope.database == "shop")
        #expect(lease.workload == .bulk)
        #expect(metadata.server.queries.contains(PostgreSQLTableHealthProvider.missingPrimaryKeyQuery))
        #expect(viewModel.report?.database == "shop")
        #expect(viewModel.report?.findingCount == 1)
    }

    // A planted @>(int2[], int2[]) in the browsed schema ran as the reader while these went out as plain reads.
    @Test("Every check reaches the driver as a catalog read")
    func everyCheckIsACatalogRead() async {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)

        await viewModel.refresh()

        #expect(!metadata.server.catalogReadFlags.isEmpty)
        #expect(metadata.server.catalogReadFlags.allSatisfy { $0 })
    }

    @Test("The first appearance loads and a second appearance does not reload")
    func loadsOnce() async {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(metadata.leases.count == 1)
        #expect(viewModel.report?.findingCount == 1)
    }

    @Test("A pane switch during the first load neither drops it nor strands the next appearance")
    func paneSwitchDuringFirstLoad() async {
        let metadata = HealthMetadata()
        let hold = (reached: AsyncGate(), release: AsyncGate())
        metadata.hold = hold
        let viewModel = makeViewModel(metadata)

        let firstAppearance = Task { await viewModel.loadIfNeeded() }
        await hold.reached.wait()
        firstAppearance.cancel()
        let secondAppearance = Task { await viewModel.loadIfNeeded() }
        await hold.release.open()
        await secondAppearance.value

        #expect(viewModel.report?.findingCount == 1)
        #expect(metadata.leases.count == 1)
        #expect(!viewModel.isRefreshing)
    }

    @Test("A refresh asked for during a refresh runs once more after it")
    func refreshDuringRefreshRunsAgain() async {
        let metadata = HealthMetadata()
        let hold = (reached: AsyncGate(), release: AsyncGate())
        metadata.hold = hold
        let viewModel = makeViewModel(metadata)

        let first = Task { await viewModel.refresh() }
        await hold.reached.wait()
        metadata.server.tablesWithoutKey = ["logs", "events"]
        let second = Task { await viewModel.refresh() }
        await hold.release.open()
        await second.value
        await first.value

        #expect(metadata.leases.count == 2)
        #expect(viewModel.report?.findingCount == 2)
        #expect(!viewModel.isRefreshing)
    }

    @Test("A cancelled refresh records nothing and reports no error")
    func cancelledRefreshRecordsNothing() async {
        let metadata = HealthMetadata()
        let hold = (reached: AsyncGate(), release: AsyncGate())
        metadata.hold = hold
        let history = InMemoryHistory()
        let viewModel = makeViewModel(metadata, history: history)

        let run = Task { await viewModel.refresh() }
        await hold.reached.wait()
        viewModel.cancel()
        await hold.release.open()
        await run.value

        #expect(viewModel.report == nil)
        #expect(viewModel.loadError == nil)
        #expect(history.recordCount == 0)
        #expect(!viewModel.isRefreshing)
    }

    @Test("A tab with no database says to open Table Health again, and reads nothing")
    func noDatabaseAsksForOne() async {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata, database: BoundDatabase(""))

        await viewModel.refresh()

        #expect(viewModel.needsDatabase)
        #expect(viewModel.loadError == TableHealthError.noDatabase.errorDescription)
        #expect(TableHealthError.noDatabase.errorDescription == "Close this tab and choose Database > Table Health.")
        #expect(metadata.leases.isEmpty)
        #expect(!makeViewModel(metadata).needsDatabase)
    }

    @Test("A lost connection says so once, and a later refresh clears it")
    func offlineThenOnline() async {
        let metadata = HealthMetadata()
        metadata.leaseFails = true
        let viewModel = makeViewModel(metadata)

        await viewModel.refresh()
        #expect(viewModel.loadError == "No active connection")
        #expect(viewModel.report == nil)
        #expect(metadata.server.queries.isEmpty)

        metadata.leaseFails = false
        await viewModel.refresh()
        #expect(viewModel.loadError == nil)
        #expect(viewModel.report?.findingCount == 1)
    }

    @Test("A failed refresh keeps the report it already had")
    func failedRefreshKeepsReport() async {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        metadata.leaseFails = true
        await viewModel.refresh()

        #expect(viewModel.report?.findingCount == 1)
        #expect(viewModel.loadError != nil)
    }

    @Test("A check that fails on refresh keeps its findings and its selection, under the error")
    func failedCheckKeepsFindings() async throws {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()
        let logs = try #require(row(viewModel, table: "logs"))
        viewModel.scope = .check(.missingPrimaryKey)
        viewModel.selection = [logs.id]

        metadata.server.failsMissingKeyCheck = true
        await viewModel.refresh()

        let check = try #require(viewModel.report?.result(for: .missingPrimaryKey))
        #expect(check.outcome == .failed("No active connection"))
        #expect(check.findings.map { $0.table } == ["logs"])
        #expect(viewModel.selectedFindings.map { $0.table } == ["logs"])
        #expect(viewModel.checkFailure == "No active connection")
        #expect(viewModel.listState == .rows)
    }

    @Test("A renamed database retargets the next refresh and carries no findings across")
    func renameRetargetsTheNextRefresh() async {
        let metadata = HealthMetadata()
        let database = BoundDatabase("shop")
        let viewModel = makeViewModel(metadata, database: database)
        await viewModel.refresh()

        database.name = "shop_v2"
        metadata.server.failsMissingKeyCheck = true
        await viewModel.refresh()

        #expect(metadata.leases.map { $0.scope.database } == ["shop", "shop_v2"])
        #expect(viewModel.report?.database == "shop_v2")
        #expect(viewModel.report?.findingCount == 0)
    }

    @Test("A refresh drops the selection when its finding is gone and keeps it otherwise")
    func selectionFollowsFindings() async throws {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = ["logs", "events"]
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        let events = try #require(row(viewModel, table: "events"))
        viewModel.selection = [events.id]

        await viewModel.refresh()
        #expect(viewModel.selectedFindings.map { $0.table } == ["events"])

        metadata.server.tablesWithoutKey = ["logs"]
        await viewModel.refresh()
        #expect(viewModel.selectedFindings.isEmpty)
    }

    @Test("The first run marks nothing new; a finding that appears later is New")
    func newFindingsAfterTheFirstRun() async throws {
        let metadata = HealthMetadata()
        let history = InMemoryHistory()
        let viewModel = makeViewModel(metadata, history: history)
        await viewModel.refresh()
        #expect(viewModel.findingRows.map { $0.status } == [.seen])

        metadata.server.tablesWithoutKey = ["logs", "events"]
        await viewModel.refresh()

        #expect(history.recordCount == 2)
        #expect(row(viewModel, table: "events")?.status == .new)
        #expect(row(viewModel, table: "logs")?.status == .seen)
    }

    @Test("A finding gone since the last run is listed under Resolved with when it was last seen")
    func goneFindingsAreResolved() async throws {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = ["logs", "events"]
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        metadata.server.tablesWithoutKey = ["logs"]
        await viewModel.refresh()
        viewModel.scope = .resolved

        #expect(viewModel.resolvedCount == 1)
        let resolved = try #require(viewModel.rows.first)
        #expect(resolved.id.table == "events")
        #expect(resolved.status == .resolved)
        #expect(resolved.lastSeen != nil)
        #expect(resolved.finding == nil)

        viewModel.clearResolved()
        #expect(viewModel.resolvedCount == 0)
        #expect(viewModel.listState == .noResolved)
    }

    @Test("Ignore hides a finding until Show Ignored, survives a refresh, and Stop Ignoring brings it back")
    func ignoreHidesUntilShown() async throws {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = ["logs", "events"]
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()
        let logs = try #require(row(viewModel, table: "logs"))

        viewModel.setIgnored([logs.id], ignored: true)
        await viewModel.refresh()

        #expect(viewModel.rows.map { $0.id.table } == ["events"])
        #expect(viewModel.allFindingsCount == 1)
        #expect(viewModel.badgeCount(for: .missingPrimaryKey) == 1)
        viewModel.showIgnored = true
        #expect(Set(viewModel.rows.compactMap { $0.id.table }) == ["logs", "events"])
        #expect(row(viewModel, table: "logs")?.status == .ignored)

        viewModel.setIgnored([logs.id], ignored: false)
        viewModel.showIgnored = false
        #expect(viewModel.rows.count == 2)
    }

    @Test("When every finding is ignored the pane says how many are hidden")
    func everyFindingIgnored() async throws {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()
        let logs = try #require(row(viewModel, table: "logs"))

        viewModel.setIgnored([logs.id], ignored: true)

        #expect(viewModel.rows.isEmpty)
        #expect(viewModel.listState == .ignoredHidden(1))
    }

    @Test("A history that cannot be saved keeps the report and says so")
    func storeFailureKeepsTheReport() async throws {
        let metadata = HealthMetadata()
        let history = InMemoryHistory()
        history.failsWrites = true
        let viewModel = makeViewModel(metadata, history: history)

        await viewModel.refresh()

        #expect(viewModel.report?.findingCount == 1)
        #expect(viewModel.storeError == "The disk is full")
        #expect(viewModel.loadError == nil)

        history.failsWrites = false
        await viewModel.refresh()
        #expect(viewModel.storeError == nil)
    }

    @Test("An ignore made in another tab on the same database reaches this one")
    func otherTabsIgnoreArrives() async throws {
        let metadata = HealthMetadata()
        let history = InMemoryHistory()
        let first = makeViewModel(metadata, history: history)
        let second = makeViewModel(metadata, history: history)
        await first.refresh()
        await second.refresh()
        let logs = try #require(row(first, table: "logs"))

        first.setIgnored([logs.id], ignored: true)

        try await waitUntil { second.rows.isEmpty }
        #expect(row(second, table: "logs")?.status == .ignored)
    }

    @Test("The filter narrows the rows and the export offers all, shown and selected findings")
    func filterAndExportScopes() async throws {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = ["logs", "events", "event_archive"]
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        viewModel.filterText = "event"
        #expect(Set(viewModel.rows.compactMap { $0.id.table }) == ["events", "event_archive"])
        let logs = try #require(row(viewModel, table: "logs"))
        let events = try #require(row(viewModel, table: "events"))
        viewModel.selection = [logs.id, events.id]

        let request = try #require(viewModel.exportRequest())
        #expect(request.scopes.map { $0.id } == ["all", "shown", "selected"])
        #expect(request.scopes.map { $0.rowCount } == [3, 2, 1])
        #expect(request.initialScope?.id == "shown")
        #expect(request.databaseTypeId == DataSourceExportRequest.dataFileTypeId)

        viewModel.filterText = "nothing matches"
        #expect(viewModel.listState == .noResults)
    }

    @Test("With every finding shown, the export offers only all findings")
    func exportWithNothingNarrowed() async throws {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        let request = try #require(viewModel.exportRequest())

        #expect(request.scopes.map { $0.id } == ["all"])
        #expect(request.initialScope?.id == "all")
    }

    @Test("A column sort reorders the rows once, here largest table first")
    func sortBySize() async {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = ["small", "large", "medium"]
        metadata.server.tableBytes = ["small": 10, "large": 3_000, "medium": 500]
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        viewModel.sortOrder = [KeyPathComparator(\TableHealthFindingRow.sizeSortKey, order: .reverse)]

        #expect(viewModel.rows.map { $0.id.table } == ["large", "medium", "small"])
    }

    @Test("Copy writes the shown columns as tab-separated rows under a header")
    func copyIsTabSeparatedWithAHeader() async throws {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()
        let logs = try #require(row(viewModel, table: "logs"))

        let text = try #require(viewModel.tsv(for: [logs]))
        let lines = text.components(separatedBy: "\n")

        #expect(lines.count == 2)
        #expect(lines[0] == TableHealthColumn.findings.map { $0.title }.joined(separator: "\t"))
        #expect(lines[1].components(separatedBy: "\t").count == TableHealthColumn.findings.count)
        #expect(lines[1].contains("public.logs"))
    }

    @Test("One fix opens as itself; several open as one script naming each finding")
    func fixTextForOneAndSeveral() async throws {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = ["logs", "events"]
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()
        let findings = viewModel.findingRows.compactMap(\.finding)
        let logs = try #require(findings.first { $0.table == "logs" })

        #expect(viewModel.fixText(for: [logs], databaseType: .postgresql) == logs.fixSQL)
        let script = try #require(viewModel.fixText(for: findings, databaseType: .postgresql))
        #expect(script.hasPrefix("-- "))
        #expect(findings.allSatisfy { finding in finding.fixSQL.map { script.contains($0) } ?? false })
    }

    @Test("All Findings says that checks failed when they did and nothing else was found")
    func allFindingsSaysChecksFailed() async {
        let metadata = HealthMetadata()
        metadata.server.failsMissingKeyCheck = true
        let viewModel = makeViewModel(metadata)

        await viewModel.refresh()

        #expect(viewModel.rows.isEmpty)
        #expect(viewModel.failedCheckCount == 1)
        #expect(viewModel.listState == .someChecksFailed(failed: 1, hiddenIgnored: 0))
    }

    @Test("A failed check in All Findings still says how many ignored findings are hidden")
    func failedChecksKeepTheIgnoredCount() async throws {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()
        let logs = try #require(row(viewModel, table: "logs"))
        viewModel.setIgnored([logs.id], ignored: true)

        metadata.server.failsMissingKeyCheck = true
        await viewModel.refresh()

        #expect(viewModel.rows.isEmpty)
        #expect(viewModel.listState == .someChecksFailed(failed: 1, hiddenIgnored: 1))
        viewModel.showIgnored = true
        #expect(viewModel.listState == .rows)
    }

    @Test("All Findings keeps the rows it has when a check fails, and counts the failure")
    func allFindingsKeepsRowsUnderAFailure() async {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        metadata.server.failsMissingKeyCheck = true
        await viewModel.refresh()

        #expect(viewModel.listState == .rows)
        #expect(viewModel.failedCheckCount == 1)
    }

    @Test("A check that found nothing leaves its description to the pane's header")
    func cleanCheckStatesItsSummaryOnce() async {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = []
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        viewModel.scope = .check(.missingPrimaryKey)

        #expect(viewModel.listState == .noFindings(""))
        #expect(viewModel.currentCheck?.check.summary.isEmpty == false)
    }

    @Test("Copy writes the selected findings the table shows, whichever list has focus")
    func selectionCopyUsesShownRows() async throws {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = ["logs", "events"]
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()
        let logs = try #require(row(viewModel, table: "logs"))
        let events = try #require(row(viewModel, table: "events"))
        viewModel.selection = [logs.id, events.id]

        viewModel.filterText = "events"
        let text = try #require(viewModel.selectionTSV())

        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].contains("public.events"))

        viewModel.selection = []
        #expect(viewModel.selectionTSV() == nil)
    }

    @Test("A history reload reads the database the tab names now")
    func reloadHistoryFollowsTheTab() async throws {
        let metadata = HealthMetadata()
        let history = InMemoryHistory()
        let database = BoundDatabase("shop")
        let viewModel = makeViewModel(metadata, history: history, database: database)
        await viewModel.refresh()
        let logs = try #require(row(viewModel, table: "logs"))
        history.ledgers["shop_v2"] = (history.ledgers["shop"] ?? TableHealthLedger()).ignoring([logs.id], at: Date())

        database.name = "shop_v2"
        viewModel.reloadHistory()

        #expect(row(viewModel, table: "logs")?.status == .ignored)
    }
}
