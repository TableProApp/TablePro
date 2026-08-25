//
//  BoundedQueryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Bounded query reads stop at the row cap")
struct BoundedQueryTests {

    @Test("Stops the producer once the cap is exceeded instead of draining the whole result")
    func stopsProducerPastCap() async throws {
        let driver = StreamingStubDriver(totalRows: 100_000, batchSize: 500)

        let result = try await driver.boundedQueryFromStream(query: "SELECT * FROM t", rowCap: 1_000)

        #expect(result.rows.count == 1_000)
        #expect(result.isTruncated)
        #expect(driver.producedRowCount < 100_000)
    }

    @Test("Reports the full result untruncated when it fits inside the cap")
    func belowCapIsNotTruncated() async throws {
        let driver = StreamingStubDriver(totalRows: 40, batchSize: 500)

        let result = try await driver.boundedQueryFromStream(query: "SELECT * FROM t", rowCap: 1_000)

        #expect(result.rows.count == 40)
        #expect(!result.isTruncated)
    }

    @Test("A result of exactly the cap is not truncated")
    func exactlyCapIsNotTruncated() async throws {
        let driver = StreamingStubDriver(totalRows: 1_000, batchSize: 250)

        let result = try await driver.boundedQueryFromStream(query: "SELECT * FROM t", rowCap: 1_000)

        #expect(result.rows.count == 1_000)
        #expect(!result.isTruncated)
    }

    @Test("Carries the column header through from the stream")
    func carriesHeader() async throws {
        let driver = StreamingStubDriver(totalRows: 10, batchSize: 5)

        let result = try await driver.boundedQueryFromStream(query: "SELECT * FROM t", rowCap: 100)

        #expect(result.columns == ["col1"])
        #expect(result.columnTypeNames == ["TEXT"])
    }

    @Test("Propagates a producer failure rather than returning a short result")
    func propagatesProducerFailure() async throws {
        let driver = StreamingStubDriver(totalRows: 100, batchSize: 10, failAfterRows: 30)

        await #expect(throws: StreamingStubError.self) {
            _ = try await driver.boundedQueryFromStream(query: "SELECT * FROM t", rowCap: 1_000)
        }
    }

    @Test("A driver that does not opt in returns nil so the caller keeps the buffered path")
    func nonParticipatingDriverReturnsNil() async throws {
        let driver = NonBoundedStubDriver()

        let result = try await driver.executeBoundedQuery(query: "SELECT * FROM t", rowCap: 1_000)

        #expect(result == nil)
    }

    @Test("The buffered executeUserQuery still caps and flags truncation for a driver without the hook")
    func bufferedPathUnchanged() async throws {
        let driver = NonBoundedStubDriver(rowCount: 50)

        let result = try await driver.executeUserQuery(query: "SELECT * FROM t", rowCap: 10, parameters: nil)

        #expect(result.rows.count == 10)
        #expect(result.isTruncated)
    }
}

@Suite("PluginBoundedStream collector")
struct PluginBoundedStreamTests {

    @Test("Treats a zero or negative cap as one row")
    func nonPositiveCapReadsOneRow() async throws {
        let driver = StreamingStubDriver(totalRows: 10, batchSize: 10)

        let result = try await PluginBoundedStream.collect(
            driver.streamRows(query: "SELECT 1"),
            rowCap: 0,
            startedAt: Date()
        )

        #expect(result.rows.count == 1)
        #expect(result.isTruncated)
    }

    @Test("Never holds a row past the cap even when a batch overshoots it")
    func neverHoldsARowPastTheCap() async throws {
        let driver = StreamingStubDriver(totalRows: 10_000, batchSize: 999)

        let result = try await PluginBoundedStream.collect(
            driver.streamRows(query: "SELECT 1"),
            rowCap: 1_000,
            startedAt: Date()
        )

        #expect(result.rows.count == 1_000)
        #expect(result.isTruncated)
    }
}

enum StreamingStubError: Error {
    case producerFailed
}

private final class StreamingStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let totalRows: Int
    private let batchSize: Int
    private let failAfterRows: Int?
    private let counter = ProducedRowCounter()

    var producedRowCount: Int { counter.value }

    init(totalRows: Int, batchSize: Int, failAfterRows: Int? = nil) {
        self.totalRows = totalRows
        self.batchSize = batchSize
        self.failAfterRows = failAfterRows
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let total = totalRows
        let size = batchSize
        let failAfter = failAfterRows
        let counter = self.counter

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                continuation.yield(.header(PluginStreamHeader(columns: ["col1"], columnTypeNames: ["TEXT"])))
                var produced = 0
                while produced < total {
                    await Task.yield()
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if let failAfter, produced >= failAfter {
                        continuation.finish(throwing: StreamingStubError.producerFailed)
                        return
                    }
                    let count = min(size, total - produced)
                    let batch: [PluginRow] = (0..<count).map { [.text("row_\(produced + $0)")] }
                    produced += count
                    counter.add(count)
                    continuation.yield(.rows(batch))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult { .empty }
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

private final class ProducedRowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add(_ rows: Int) {
        lock.lock()
        count += rows
        lock.unlock()
    }
}

private final class NonBoundedStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let rowCount: Int

    init(rowCount: Int = 0) {
        self.rowCount = rowCount
    }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(
            columns: ["col1"],
            columnTypeNames: ["TEXT"],
            rows: (0..<rowCount).map { [.text("row_\($0)")] },
            rowsAffected: 0,
            executionTime: 0
        )
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
