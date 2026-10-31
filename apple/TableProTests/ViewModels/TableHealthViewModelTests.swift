import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct Offline: LocalizedError {
    var errorDescription: String? { "No active connection" }
}

// Answers the missing primary key check with the given tables and every other read with nothing.
// The driver runs off the main actor, so the state is locked rather than isolated.
private final class HealthServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _tablesWithoutKey = ["logs"]
    private var _failsMissingKeyCheck = false
    private var _queries: [String] = []

    var tablesWithoutKey: [String] {
        get { lock.withLock { _tablesWithoutKey } }
        set { lock.withLock { _tablesWithoutKey = newValue } }
    }

    var failsMissingKeyCheck: Bool {
        get { lock.withLock { _failsMissingKeyCheck } }
        set { lock.withLock { _failsMissingKeyCheck = newValue } }
    }

    var queries: [String] { lock.withLock { _queries } }

    func answer(_ query: String) throws -> PluginQueryResult {
        let (tables, fails) = lock.withLock { () -> ([String], Bool) in
            _queries.append(query)
            return (_tablesWithoutKey, _failsMissingKeyCheck)
        }
        guard query == PostgreSQLTableHealthProvider.missingPrimaryKeyQuery else {
            return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }
        if fails { throw Offline() }
        return PluginQueryResult(
            columns: ["schema_name", "table_name"],
            columnTypeNames: ["TEXT", "TEXT"],
            rows: tables.map { [.text("public"), .text($0)] },
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
}

@MainActor
private final class HealthMetadata: ScopedMetadataProviding {
    let server = HealthServer()
    let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
    var database = "shop"
    var isConnected = true
    var leaseFails = false
    private(set) var leases: [(scope: DatabaseScope, workload: MetadataConnectionPool.Workload)] = []

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        leases.append((scope, workload))
        if leaseFails { throw Offline() }
        return try await body(PluginDriverAdapter(connection: connection, pluginDriver: HealthPluginDriver(server: server)))
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        guard isConnected else { return nil }
        return DatabaseScope(connectionId: connectionId, database: database, schema: "public")
    }
}

@MainActor
struct TableHealthViewModelTests {
    private func makeViewModel(
        _ metadata: HealthMetadata,
        databaseType: DatabaseType = .postgresql
    ) -> TableHealthViewModel {
        TableHealthViewModel(
            connectionId: metadata.connection.id,
            provider: TableHealthProviderFactory.provider(for: databaseType),
            metadata: metadata
        )
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

    @Test("A refresh runs every read in one metadata lease on the browsed database, and names it")
    func oneLeaseOnBrowseScope() async throws {
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

    @Test("The first appearance loads and a second appearance does not reload")
    func loadsOnce() async {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(metadata.leases.count == 1)
        #expect(viewModel.report?.findingCount == 1)
    }

    @Test("A connection with no database selected asks for one and reads nothing")
    func serverScopedAsksForDatabase() async {
        let metadata = HealthMetadata()
        metadata.database = ""
        let viewModel = makeViewModel(metadata)

        await viewModel.refresh()

        #expect(viewModel.loadError == TableHealthError.noDatabase.errorDescription)
        #expect(metadata.leases.isEmpty)
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

        metadata.isConnected = false
        await viewModel.refresh()

        #expect(viewModel.report?.findingCount == 1)
        #expect(viewModel.loadError != nil)
    }

    @Test("A check that fails on refresh keeps its findings and its selection, under the error")
    func failedCheckKeepsFindings() async throws {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()
        let logs = try #require(viewModel.report?.checks.flatMap { $0.findings }.first)
        viewModel.selectedFindingId = logs.id

        metadata.server.failsMissingKeyCheck = true
        await viewModel.refresh()

        let check = try #require(viewModel.report?.checks.first { $0.kind == .missingPrimaryKey })
        #expect(check.outcome == .failed("No active connection"))
        #expect(check.findings.map { $0.table } == ["logs"])
        #expect(viewModel.selectedFinding?.table == "logs")
    }

    @Test("Findings from another database are not carried over when a check fails")
    func otherDatabaseFindingsDropped() async {
        let metadata = HealthMetadata()
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        metadata.database = "archive"
        metadata.server.failsMissingKeyCheck = true
        await viewModel.refresh()

        #expect(viewModel.report?.database == "archive")
        #expect(viewModel.report?.findingCount == 0)
        #expect(viewModel.selectedFindingId == nil)
    }

    @Test("A refresh drops the selection when its finding is gone and keeps it otherwise")
    func selectionFollowsFindings() async throws {
        let metadata = HealthMetadata()
        metadata.server.tablesWithoutKey = ["logs", "events"]
        let viewModel = makeViewModel(metadata)
        await viewModel.refresh()

        let events = try #require(viewModel.report?.checks.flatMap { $0.findings }.first { $0.table == "events" })
        viewModel.selectedFindingId = events.id

        await viewModel.refresh()
        #expect(viewModel.selectedFinding?.table == "events")

        metadata.server.tablesWithoutKey = ["logs"]
        await viewModel.refresh()
        #expect(viewModel.selectedFindingId == nil)
        #expect(viewModel.selectedFinding == nil)
    }
}
