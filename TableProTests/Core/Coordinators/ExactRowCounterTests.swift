import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private enum CountStubError: Error {
    case refused
}

private final class CountStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let ownsQueryBuilding: Bool
    private let driverCount: Result<Int?, CountStubError>
    private var executed: [String] = []
    private var driverCountCalls = 0

    init(ownsQueryBuilding: Bool, driverCount: Result<Int?, CountStubError>) {
        self.ownsQueryBuilding = ownsQueryBuilding
        self.driverCount = driverCount
    }

    var executedQueries: [String] {
        lock.withLock { executed }
    }

    var driverCountCallCount: Int {
        lock.withLock { driverCountCalls }
    }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        ownsQueryBuilding ? "BROWSE \(table)" : nil
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        lock.withLock { driverCountCalls += 1 }
        return try driverCount.get()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { executed.append(query) }
        return PluginQueryResult(
            columns: ["count"], columnTypeNames: ["INT64"], rows: [[.text("7")]], rowsAffected: 0, executionTime: 0
        )
    }

    func connect() async throws {}
    func disconnect() {}
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@Suite("Exact row count routing")
struct ExactRowCounterTests {
    private static let countSQL = "SELECT COUNT(*) FROM `Orders`"

    private func count(
        _ stub: CountStubDriver,
        countSQL: String? = ExactRowCounterTests.countSQL
    ) async throws -> Int? {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .spanner), pluginDriver: stub)
        return try await ExactRowCounter.count(
            on: adapter, table: "Orders", filters: [], logicMode: .and, countSQL: countSQL
        )
    }

    @Test("A driver that builds its own queries is asked first, and the host SQL follows it")
    func routesQueryBuildingDriversThroughTheDriverFirst() {
        #expect(
            ExactRowCounter.route(countSQL: Self.countSQL, driverOwnsQueryBuilding: true)
                == .driverCountThenHostSQL(Self.countSQL)
        )
    }

    @Test("Every other SQL engine keeps the host COUNT query alone")
    func keepsHostSQLForOtherEngines() {
        #expect(
            ExactRowCounter.route(countSQL: Self.countSQL, driverOwnsQueryBuilding: false)
                == .hostCountSQL(Self.countSQL)
        )
    }

    @Test("Without host SQL the driver is the only source, whoever builds the queries")
    func withoutHostSQLTheDriverCounts() {
        #expect(ExactRowCounter.route(countSQL: nil, driverOwnsQueryBuilding: true) == .driverCount)
        #expect(ExactRowCounter.route(countSQL: nil, driverOwnsQueryBuilding: false) == .driverCount)
    }

    @Test("The driver's own count wins and the host COUNT never runs")
    func driverCountWins() async throws {
        let stub = CountStubDriver(ownsQueryBuilding: true, driverCount: .success(42))

        let result = try await count(stub)

        #expect(result == 42)
        #expect(stub.executedQueries.isEmpty)
    }

    @Test("A driver that has no count falls back to the host COUNT")
    func nilDriverCountFallsBack() async throws {
        let stub = CountStubDriver(ownsQueryBuilding: true, driverCount: .success(nil))

        let result = try await count(stub)

        #expect(result == 7)
        #expect(stub.driverCountCallCount == 1)
        #expect(stub.executedQueries == [Self.countSQL])
    }

    @Test("A driver count that fails falls back to the host COUNT")
    func failingDriverCountFallsBack() async throws {
        let stub = CountStubDriver(ownsQueryBuilding: true, driverCount: .failure(.refused))

        let result = try await count(stub)

        #expect(result == 7)
        #expect(stub.executedQueries == [Self.countSQL])
    }

    @Test("A driver that does not build queries is never asked for a count")
    func otherEnginesSkipTheDriverCount() async throws {
        let stub = CountStubDriver(ownsQueryBuilding: false, driverCount: .success(42))

        let result = try await count(stub)

        #expect(result == 7)
        #expect(stub.driverCountCallCount == 0)
        #expect(stub.executedQueries == [Self.countSQL])
    }

    @Test("A failed driver count with no host SQL still reports the failure")
    func failureWithoutHostSQLPropagates() async {
        let stub = CountStubDriver(ownsQueryBuilding: true, driverCount: .failure(.refused))

        await #expect(throws: CountStubError.self) {
            _ = try await count(stub, countSQL: nil)
        }
        #expect(stub.executedQueries.isEmpty)
    }
}
