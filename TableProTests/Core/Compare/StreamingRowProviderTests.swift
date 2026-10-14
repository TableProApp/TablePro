//
//  StreamingRowProviderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct StreamingRowProviderTests {
    private func stream(_ elements: [PluginStreamElement]) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            for element in elements { continuation.yield(element) }
            continuation.finish()
        }
    }

    private func header(_ columns: [String]) -> PluginStreamElement {
        .header(PluginStreamHeader(columns: columns, columnTypeNames: columns.map { _ in "text" }))
    }

    @Test
    func headerColumnsAreUsedToNameValues() async throws {
        let provider = StreamingRowProvider(
            stream: stream([header(["id", "name"]), .rows([[.text("1"), .text("a")]])])
        )

        let row = try await provider.nextRow()

        #expect(row?.value(for: "id") == .text("1"))
        #expect(row?.value(for: "name") == .text("a"))
    }

    @Test
    func explicitColumnsSurviveAMissingHeader() async throws {
        let provider = StreamingRowProvider(
            stream: stream([.rows([[.text("1"), .text("a")]])]),
            columns: ["id", "name"]
        )

        let row = try await provider.nextRow()

        #expect(row?.value(for: "name") == .text("a"))
    }

    @Test
    func rowsAcrossMultipleBatchesAreAllReturnedInOrder() async throws {
        let provider = StreamingRowProvider(stream: stream([
            header(["id"]),
            .rows([[.text("1")], [.text("2")]]),
            .rows([[.text("3")]])
        ]))

        var seen: [String] = []
        while let row = try await provider.nextRow() {
            if case .text(let value) = row.value(for: "id") { seen.append(value) }
        }

        #expect(seen == ["1", "2", "3"])
    }

    @Test
    func emptyBatchesAreSkippedRatherThanEndingTheStream() async throws {
        let provider = StreamingRowProvider(stream: stream([
            header(["id"]),
            .rows([]),
            .rows([]),
            .rows([[.text("1")]])
        ]))

        let row = try await provider.nextRow()

        #expect(row?.value(for: "id") == .text("1"), "empty batches must not be mistaken for end of stream")
    }

    @Test
    func exhaustedStreamReturnsNilRepeatedly() async throws {
        let provider = StreamingRowProvider(stream: stream([header(["id"]), .rows([[.text("1")]])]))

        _ = try await provider.nextRow()

        let firstNil = try await provider.nextRow()
        let secondNil = try await provider.nextRow()
        #expect(firstNil == nil)
        #expect(secondNil == nil)
    }

    @Test
    func shortRowDoesNotOverrunTheColumnList() async throws {
        let provider = StreamingRowProvider(stream: stream([
            header(["id", "name", "extra"]),
            .rows([[.text("1")]])
        ]))

        let row = try await provider.nextRow()

        #expect(row?.value(for: "id") == .text("1"))
        #expect(row?.value(for: "name") == .null, "a column with no value reads as NULL")
    }

    @Test
    func errorsFromTheStreamPropagate() async {
        struct Boom: Error {}
        let failing = AsyncThrowingStream<PluginStreamElement, Error> { continuation in
            continuation.yield(self.header(["id"]))
            continuation.finish(throwing: Boom())
        }
        let provider = StreamingRowProvider(stream: failing)

        do {
            _ = try await provider.nextRow()
            Issue.record("Expected the stream error to surface")
        } catch {
            #expect(error is Boom)
        }
    }
}

struct KeyOrderedQueryTests {
    private final class Quoting: PluginDriverStub, @unchecked Sendable {
        func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }
    }

    @Test
    func querySelectsRequestedColumnsOrderedByKey() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: nil, columns: ["id", "name"], keyColumns: ["id"], driver: Quoting(),
            databaseType: .postgresql
        )

        #expect(sql == "SELECT \"id\", \"name\" FROM \"users\" ORDER BY \"id\"")
    }

    @Test
    func compositeKeyOrdersByEveryKeyColumn() {
        let sql = KeyOrderedQuery.build(
            table: "t", schema: nil, columns: ["a"], keyColumns: ["tenant", "id"], driver: Quoting(),
            databaseType: .postgresql
        )

        #expect(sql.hasSuffix("ORDER BY \"tenant\", \"id\""), Comment(rawValue: sql))
    }

    @Test
    func schemaIsQualifiedAndQuoted() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: "app", columns: ["id"], keyColumns: ["id"], driver: Quoting(),
            databaseType: .postgresql
        )

        #expect(sql.contains("FROM \"app\".\"users\""), Comment(rawValue: sql))
    }

    @Test
    func theEngineImplicitSchemaIsLeftUnqualified() {
        let sql = KeyOrderedQuery.build(
            table: "users", schema: "(default)", columns: ["id"], keyColumns: ["id"], driver: Quoting(),
            databaseType: .spanner
        )

        #expect(sql == "SELECT \"id\" FROM \"users\" ORDER BY \"id\"")
    }
}
