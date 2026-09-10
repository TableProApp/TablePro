//
//  StreamingRowProviderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

final class StreamingRowProviderTests: XCTestCase {
    private func stream(_ elements: [PluginStreamElement]) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            for element in elements { continuation.yield(element) }
            continuation.finish()
        }
    }

    private func header(_ columns: [String]) -> PluginStreamElement {
        .header(PluginStreamHeader(columns: columns, columnTypeNames: columns.map { _ in "text" }))
    }

    func testHeaderColumnsAreUsedToNameValues() async throws {
        let provider = StreamingRowProvider(
            stream: stream([header(["id", "name"]), .rows([[.text("1"), .text("a")]])])
        )

        let row = try await provider.nextRow()

        XCTAssertEqual(row?.value(for: "id"), .text("1"))
        XCTAssertEqual(row?.value(for: "name"), .text("a"))
    }

    func testExplicitColumnsSurviveAMissingHeader() async throws {
        let provider = StreamingRowProvider(
            stream: stream([.rows([[.text("1"), .text("a")]])]),
            columns: ["id", "name"]
        )

        let row = try await provider.nextRow()

        XCTAssertEqual(row?.value(for: "name"), .text("a"))
    }

    func testRowsAcrossMultipleBatchesAreAllReturnedInOrder() async throws {
        let provider = StreamingRowProvider(stream: stream([
            header(["id"]),
            .rows([[.text("1")], [.text("2")]]),
            .rows([[.text("3")]])
        ]))

        var seen: [String] = []
        while let row = try await provider.nextRow() {
            if case .text(let value) = row.value(for: "id") { seen.append(value) }
        }

        XCTAssertEqual(seen, ["1", "2", "3"])
    }

    func testEmptyBatchesAreSkippedRatherThanEndingTheStream() async throws {
        let provider = StreamingRowProvider(stream: stream([
            header(["id"]),
            .rows([]),
            .rows([]),
            .rows([[.text("1")]])
        ]))

        let row = try await provider.nextRow()

        XCTAssertEqual(row?.value(for: "id"), .text("1"), "empty batches must not be mistaken for end of stream")
    }

    func testExhaustedStreamReturnsNilRepeatedly() async throws {
        let provider = StreamingRowProvider(stream: stream([header(["id"]), .rows([[.text("1")]])]))

        _ = try await provider.nextRow()

        let firstNil = try await provider.nextRow()
        let secondNil = try await provider.nextRow()
        XCTAssertNil(firstNil)
        XCTAssertNil(secondNil)
    }

    func testShortRowDoesNotOverrunTheColumnList() async throws {
        let provider = StreamingRowProvider(stream: stream([
            header(["id", "name", "extra"]),
            .rows([[.text("1")]])
        ]))

        let row = try await provider.nextRow()

        XCTAssertEqual(row?.value(for: "id"), .text("1"))
        XCTAssertEqual(row?.value(for: "name"), .null, "a column with no value reads as NULL")
    }

    func testErrorsFromTheStreamPropagate() async {
        struct Boom: Error {}
        let failing = AsyncThrowingStream<PluginStreamElement, Error> { continuation in
            continuation.yield(self.header(["id"]))
            continuation.finish(throwing: Boom())
        }
        let provider = StreamingRowProvider(stream: failing)

        do {
            _ = try await provider.nextRow()
            XCTFail("Expected the stream error to surface")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}

final class KeyOrderedQueryTests: XCTestCase {
    private final class Quoting: PluginDatabaseDriver, @unchecked Sendable {
        func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
        func connect() async throws {}
        func disconnect() {}
        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
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

    func testQuerySelectsRequestedColumnsOrderedByKey() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id", "name"], keyColumns: ["id"], driver: Quoting()
        )

        XCTAssertEqual(sql, "SELECT \"id\", \"name\" FROM \"users\" ORDER BY \"id\"")
    }

    func testCompositeKeyOrdersByEveryKeyColumn() {
        let sql = KeyOrderedQuery.build(
            table: "t", schema: nil, columns: ["a"], keyColumns: ["tenant", "id"], driver: Quoting()
        )

        XCTAssertTrue(sql.hasSuffix("ORDER BY \"tenant\", \"id\""), sql)
    }

    func testSchemaIsQualifiedAndQuoted() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: "app", columns: ["id"], keyColumns: ["id"], driver: Quoting()
        )

        XCTAssertTrue(sql.contains("FROM \"app\".\"users\""), sql)
    }
}
