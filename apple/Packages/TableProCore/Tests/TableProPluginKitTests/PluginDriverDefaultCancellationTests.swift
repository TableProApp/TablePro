import Foundation
import TableProPluginKit
import Testing

// The default row stream ran its query in an unstructured task nothing cancelled, so an export
// stopped on a driver without its own stream kept the query and the connection busy to the end.
struct PluginDriverDefaultCancellationTests {
    @Test("The default row stream carries the header and every row the query returned")
    func defaultStreamCarriesTheResult() async throws {
        let driver = HeldQueryDriver(holdsQuery: false)
        var columns: [String] = []
        var rows: [PluginRow] = []
        for try await element in driver.streamRows(query: "SELECT v FROM t") {
            switch element {
            case .header(let header): columns = header.columns
            case .rows(let batch): rows += batch
            }
        }
        #expect(columns == ["v"])
        #expect(rows == [["1"], ["2"]])
        #expect(driver.executeCount == 1)
    }

    @Test("Cancelling the consumer of the default row stream cancels the query it runs", .timeLimit(.minutes(1)))
    func consumerCancelReachesTheQuery() async {
        let driver = HeldQueryDriver(holdsQuery: true)
        let consumer = Task {
            do {
                for try await _ in driver.streamRows(query: "SELECT v FROM t") {}
            } catch {}
        }
        await driver.waitUntilQueryStarts()
        consumer.cancel()
        await driver.waitUntilQueryIsCancelled()
        await consumer.value
        #expect(driver.executeCount == 1)
    }

    @Test("Dropping the default row stream cancels the query it runs", .timeLimit(.minutes(1)))
    func droppedStreamCancelsTheQuery() async {
        let driver = HeldQueryDriver(holdsQuery: true)
        var stream: AsyncThrowingStream<PluginStreamElement, Error>? = driver.streamRows(query: "SELECT v FROM t")
        await driver.waitUntilQueryStarts()
        #expect(stream != nil)
        stream = nil
        await driver.waitUntilQueryIsCancelled()
    }

    @Test("The per-table foreign key read stops at the next table once its caller is cancelled")
    func foreignKeyLoopStopsOnCancel() async {
        let driver = CancellingCatalogDriver(tableCount: 50)
        let read = Task { try await driver.fetchAllForeignKeys(schema: nil) }
        await #expect(throws: CancellationError.self) {
            _ = try await read.value
        }
        #expect(driver.perTableReads == 1)
    }

    @Test("The per-table metadata read, which skips unreadable tables, still stops once its caller is cancelled")
    func tableMetadataLoopStopsOnCancel() async {
        let driver = CancellingCatalogDriver(tableCount: 50)
        let read = Task { try await driver.fetchAllTableMetadata(schema: nil) }
        await #expect(throws: CancellationError.self) {
            _ = try await read.value
        }
        #expect(driver.perTableReads == 1)
    }
}

private final class HeldQueryDriver: PluginDatabaseDriver, @unchecked Sendable {
    let supportsSchemas = false
    let supportsTransactions = false
    let currentSchema: String? = nil
    let serverVersion: String? = nil

    private let holdsQuery: Bool
    private let lock = NSLock()
    private var executions = 0
    private let started: AsyncStream<Void>
    private let startedSignal: AsyncStream<Void>.Continuation
    private let cancelled: AsyncStream<Void>
    private let cancelledSignal: AsyncStream<Void>.Continuation
    // Never finished, so only a cancel of the task reading it ends the read.
    private let wire: AsyncStream<Void>
    private let wireWriter: AsyncStream<Void>.Continuation

    init(holdsQuery: Bool) {
        self.holdsQuery = holdsQuery
        (started, startedSignal) = AsyncStream<Void>.makeStream()
        (cancelled, cancelledSignal) = AsyncStream<Void>.makeStream()
        (wire, wireWriter) = AsyncStream<Void>.makeStream()
    }

    var executeCount: Int { lock.withLock { executions } }

    func waitUntilQueryStarts() async {
        for await _ in started { return }
    }

    func waitUntilQueryIsCancelled() async {
        for await _ in cancelled { return }
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { executions += 1 }
        guard holdsQuery else {
            return PluginQueryResult(
                columns: ["v"], columnTypeNames: ["INT"], rows: [["1"], ["2"]], rowsAffected: 0, executionTime: 0
            )
        }
        startedSignal.yield()
        for await _ in wire {}
        if Task.isCancelled { cancelledSignal.yield() }
        throw CancellationError()
    }

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

// Each per-table read cancels the task that made it and still answers, the way a driver that never
// checks for cancellation finishes its round trip.
private final class CancellingCatalogDriver: PluginDatabaseDriver, @unchecked Sendable {
    let supportsSchemas = false
    let supportsTransactions = false
    let currentSchema: String? = nil
    let serverVersion: String? = nil

    private let tableCount: Int
    private let lock = NSLock()
    private var reads = 0

    init(tableCount: Int) {
        self.tableCount = tableCount
    }

    var perTableReads: Int { lock.withLock { reads } }

    private func cancellingRead() {
        lock.withLock { reads += 1 }
        withUnsafeCurrentTask { $0?.cancel() }
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult { .empty }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        (0..<tableCount).map {
            PluginTableInfo(name: "t\($0)", comment: nil, partitionCount: nil, ownedByTable: nil, ownedByColumn: nil)
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        cancellingRead()
        return [
            PluginForeignKeyInfo(
                name: "fk_\(table)", column: "parent_id", referencedTable: "parent", referencedColumn: "id",
                referencedDatabase: nil
            )
        ]
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        cancellingRead()
        return PluginTableMetadata(tableName: table)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}
