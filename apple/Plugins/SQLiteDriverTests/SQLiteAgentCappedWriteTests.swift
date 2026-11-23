//
//  SQLiteAgentCappedWriteTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// The shipped agent over a loopback relay: a capped write it stops early would report rows its rollback took back.
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: SQLiteAgentLoopback.python3Path != nil))
struct SQLiteAgentCappedWriteTests {
    private static func withAgent(_ body: (SQLitePluginDriver) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("agent-capped-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let loopback = try SQLiteAgentLoopback(arguments: SQLiteAgentLoopback.shippedArguments)
        defer { loopback.close() }
        let fields = [SQLiteAgentProtocol.backendFieldKey: SQLiteAgentProtocol.agentBackendValue]
        let backend = SQLiteAgentBackend(
            host: "127.0.0.1",
            port: loopback.port,
            path: path,
            token: loopback.token,
            helloBudget: try #require(SQLiteAgentHelloBudget.forAgent(additionalFields: fields))
        )
        let driver = SQLitePluginDriver(
            config: DriverConnectionConfig(
                host: "127.0.0.1", port: loopback.port, username: "", password: "", database: path,
                additionalFields: fields
            ),
            backend: backend
        )
        do {
            try await driver.connect()
            try await body(driver)
        } catch {
            await backend.close()
            throw error
        }
        await backend.close()
    }

    @Test("A capped write through the agent runs to its end, so a deferred key it breaks fails it and nothing stays")
    func cappedWriteMeetsItsDeferredKey() async throws {
        try await Self.withAgent { driver in
            _ = try await driver.execute(query: "PRAGMA foreign_keys = ON")
            _ = try await driver.execute(query: "CREATE TABLE parent (id INTEGER PRIMARY KEY)")
            _ = try await driver.execute(query: """
                CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent (id) DEFERRABLE INITIALLY DEFERRED)
                """)

            await #expect(throws: (any Error).self) {
                _ = try await driver.executeUserQuery(
                    query: """
                        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 10)
                        INSERT INTO child (id, parent_id) SELECT x, CAST(? AS INTEGER) FROM n RETURNING id
                        """,
                    rowCap: 3,
                    parameters: [.text("99")]
                )
            }
            let left = try await driver.execute(query: "SELECT count(*) FROM child").rows
            #expect(left.first?.first?.asText == "0")
        }
    }

    @Test("A capped read through the agent still stops at its cap")
    func cappedReadStops() async throws {
        try await Self.withAgent { driver in
            _ = try await driver.execute(query: """
                CREATE TABLE t AS WITH RECURSIVE g(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM g WHERE x < 1000) SELECT x AS id FROM g
                """)

            let result = try await driver.executeUserQuery(
                query: "SELECT id FROM t WHERE id > CAST(? AS INTEGER)", rowCap: 3, parameters: [.text("0")]
            )

            #expect(result.rows.count == 3)
            #expect(result.isTruncated)
        }
    }
}
