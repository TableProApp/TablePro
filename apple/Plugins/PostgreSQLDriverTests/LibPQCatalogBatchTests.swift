//
//  LibPQCatalogBatchTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LibPQCatalogBatchTests {
    private static let pin = "SET LOCAL search_path = pg_catalog, pg_temp"

    @Test("Each read's answer is found past the statements that pin its path")
    func answerIndexesSkipThePins() {
        let batch = LibPQCatalogBatch(
            leading: ["SELECT 0"],
            reads: [
                PostgreSQLCatalogRead(statement: "SELECT 1"),
                PostgreSQLCatalogRead(statement: "SELECT 2"),
                PostgreSQLCatalogRead(statement: "SELECT 3", namesRelativeTo: "sales"),
                PostgreSQLCatalogRead(statement: "SELECT 4")
            ],
            trailing: ["SET x = 1"]
        )

        #expect(batch.readResultIndexes == [2, 3, 5, 7])
        #expect(batch.statementCount == 9)
        #expect(batch.text.hasPrefix("SELECT 0"))
    }

    @Test("A statement ending in a line comment cannot swallow the separator")
    func lineCommentKeepsTheNextStatementApart() {
        let batch = LibPQCatalogBatch(reads: [
            PostgreSQLCatalogRead(statement: "SELECT 1 -- one"),
            PostgreSQLCatalogRead(statement: "SELECT 2")
        ])

        #expect(batch.text.contains("SELECT 1 -- one\n;\nSELECT 2"))
    }

    private static func connected(to server: LibPQScriptedServer) async throws -> PostgreSQLPluginDriver {
        let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: server.port, username: "postgres", password: "", database: "postgres"
        ))
        try await driver.connect()
        return driver
    }

    private static func columnReads(of query: String) -> Int {
        let reads = [
            PostgreSQLSchemaQueries.enumLabelQuery(schema: "public", table: "orders"),
            PostgreSQLSchemaQueries.arrayTypeQuery(schema: "public", table: "orders")
        ]
        return reads.filter { query.contains($0) }.count
    }

    @Test("A table's columns are read in one Query on an idle session")
    func columnsTakeOneQuery() async throws {
        let server = try LibPQScriptedServer()
        defer { server.close() }
        server.start()
        let driver = try await Self.connected(to: server)
        defer { driver.disconnect() }
        let before = server.queries.count

        _ = try await driver.fetchColumns(table: "orders", schema: "public")

        let sent = Array(server.queries[before...])
        #expect(sent.count == 1)
        #expect(Self.columnReads(of: sent[0]) == 2)
        #expect(sent[0].contains("SET LOCAL search_path = pg_catalog, \"public\", pg_temp"))
    }

    @Test("Inside the person's block a savepoint holds the batch and is rolled back after it")
    func blockTakesASavepoint() async throws {
        let server = try LibPQScriptedServer(status: { query, earlier in
            (earlier + [query]).contains("BEGIN") ? LibPQScriptedServer.inTransaction : LibPQScriptedServer.idle
        })
        defer { server.close() }
        server.start()
        let driver = try await Self.connected(to: server)
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "BEGIN")
        let before = server.queries.count

        _ = try await driver.fetchColumns(table: "orders", schema: "public")

        let sent = Array(server.queries[before...])
        #expect(sent.count == 2)
        #expect(sent[0].hasPrefix("SAVEPOINT tablepro_scoped_read"))
        #expect(Self.columnReads(of: sent[0]) == 2)
        #expect(sent[1] == "ROLLBACK TO SAVEPOINT tablepro_scoped_read; RELEASE SAVEPOINT tablepro_scoped_read")
    }

    @Test("A block a failed statement aborted keeps each read on its own")
    func abortedBlockIsNotBatched() async throws {
        let server = try LibPQScriptedServer(status: { query, earlier in
            (earlier + [query]).contains("BEGIN") ? LibPQScriptedServer.failedTransaction : LibPQScriptedServer.idle
        })
        defer { server.close() }
        server.start()
        let driver = try await Self.connected(to: server)
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "BEGIN")
        let before = server.queries.count

        _ = try? await driver.fetchColumns(table: "orders", schema: "public")

        let sent = Array(server.queries[before...])
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { Self.columnReads(of: $0) <= 1 })
    }

    @Test("The read the server refuses is the error the column read reports, and nothing is sent again")
    func failedReadReportsItsOwnError() async throws {
        let failing = PostgreSQLSchemaQueries.arrayTypeQuery(schema: "public", table: "orders")
        let server = try LibPQScriptedServer(failingStatement: failing)
        defer { server.close() }
        server.start()
        let driver = try await Self.connected(to: server)
        defer { driver.disconnect() }
        let before = server.queries.count

        await #expect(throws: LibPQPluginError.self) {
            _ = try await driver.fetchColumns(table: "orders", schema: "public")
        }
        #expect(server.queries.count == before + 1)
    }
}
