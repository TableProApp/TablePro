//
//  LibPQCappedUserReadTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// A scripted server sends every row at once and, where the answer says so, holds the statement until a cancel arrives,
// so a read that does not stop and cancel at its cap ends only when the server gives up waiting.
@Suite(.timeLimit(.minutes(1)))
struct LibPQCappedUserReadTests {
    private static let events = "SELECT * FROM events WHERE id > $1"
    private static let plainEvents = "SELECT * FROM events"
    private static let insert = "INSERT INTO events SELECT g FROM generate_series(1, $1) g RETURNING id"
    private static let columns = [LibPQScriptedServer.Column(name: "id", type: 23)]

    private static func rows(_ count: Int) -> [[String?]] {
        (0..<count).map { [String($0)] }
    }

    private static func status(_ query: String, _ earlier: [String]) -> UInt8 {
        let last = (earlier + [query]).last { ["BEGIN", "COMMIT", "ROLLBACK"].contains($0) }
        return last == "BEGIN" ? LibPQScriptedServer.inTransaction : LibPQScriptedServer.idle
    }

    private static func server(answering answers: [String: LibPQScriptedServer.Answer]) throws -> LibPQScriptedServer {
        try LibPQScriptedServer(
            status: { query, earlier in Self.status(query, earlier) },
            answer: { query in answers[query] }
        )
    }

    private static func connectedDriver(to server: LibPQScriptedServer) async throws -> PostgreSQLPluginDriver {
        let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: server.port, username: "postgres", password: "", database: "postgres"
        ))
        try await driver.connect()
        return driver
    }

    @Test("A capped read with parameters keeps the cap, cancels the rest and sends its parameters")
    func parametersStopAtTheCap() async throws {
        let server = try Self.server(answering: [
            Self.events: .init(columns: Self.columns, rows: Self.rows(50), waitsForCancel: true),
        ])
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let result = try await driver.executeUserQuery(query: Self.events, rowCap: 3, parameters: [.text("0")])

        #expect(result.rows == [[.text("0")], [.text("1")], [.text("2")]])
        #expect(result.isTruncated)
        #expect(server.cancelRequests == 1)
        #expect(server.boundParameters.last == ["0"])
        #expect(!server.queries.contains { $0.hasPrefix("DECLARE") })
    }

    @Test("A capped read with parameters that fits the cap sends no cancel")
    func shortParameterReadSendsNoCancel() async throws {
        let server = try Self.server(answering: [Self.events: .init(columns: Self.columns, rows: Self.rows(2))])
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let result = try await driver.executeUserQuery(query: Self.events, rowCap: 3, parameters: [.text("0")])

        #expect(result.rows.count == 2)
        #expect(!result.isTruncated)
        #expect(server.cancelRequests == 0)
    }

    @Test("A capped INSERT ... RETURNING runs to its end, keeps the cap and reports every row it wrote")
    func returningRunsToItsEnd() async throws {
        let server = try Self.server(answering: [
            Self.insert: .init(columns: Self.columns, rows: Self.rows(50), completion: "INSERT 0 50"),
        ])
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let result = try await driver.executeUserQuery(query: Self.insert, rowCap: 3, parameters: [.text("50")])

        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(result.rowsAffected == 50)
        #expect(server.cancelRequests == 0)
    }

    @Test("Inside the user's block a capped read with parameters drains instead of cancelling, and the block stays open")
    func insideBlockDrains() async throws {
        let server = try Self.server(answering: [Self.events: .init(columns: Self.columns, rows: Self.rows(50))])
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        _ = try await driver.execute(query: "BEGIN")
        let result = try await driver.executeUserQuery(query: Self.events, rowCap: 3, parameters: [.text("0")])
        _ = try await driver.execute(query: "SELECT 1")

        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(server.cancelRequests == 0)
        #expect(!server.queries.contains { $0.hasPrefix("DECLARE") })
        #expect(await driver.sessionTransactionState() == .inTransaction)
    }

    @Test("Inside the user's block an error past the cap fails the capped read instead of reporting the kept rows")
    func insideBlockErrorPastTheCapFails() async throws {
        let failure = LibPQScriptedServer.Failure(sqlState: "22012", message: "division by zero")
        let server = try Self.server(answering: [
            Self.events: .init(columns: Self.columns, rows: Self.rows(50), failureAfterRows: failure),
        ])
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        _ = try await driver.execute(query: "BEGIN")
        await #expect(throws: (any Error).self) {
            _ = try await driver.executeUserQuery(query: Self.events, rowCap: 3, parameters: [.text("0")])
        }
        #expect(server.cancelRequests == 0)
    }

    // A cancel would roll back whatever the function wrote while the kept rows read as done.
    @Test("A capped read that calls a function the user wrote runs to its end, keeps the cap and sends no cancel")
    func userFunctionRunsToItsEnd() async throws {
        let query = "SELECT audit_event(id) FROM events WHERE id > $1"
        let server = try Self.server(answering: [query: .init(columns: Self.columns, rows: Self.rows(50))])
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let result = try await driver.executeUserQuery(query: query, rowCap: 3, parameters: [.text("0")])

        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(server.cancelRequests == 0)
    }

    @Test("Without a server cancel a capped read with parameters is drained and keeps the cap")
    func suppressedCancelDrains() async throws {
        let server = try Self.server(answering: [Self.events: .init(columns: Self.columns, rows: Self.rows(50))])
        defer { server.close() }
        server.start()
        let connection = LibPQPluginConnection(
            host: "127.0.0.1",
            port: server.port,
            user: "postgres",
            password: nil,
            database: "postgres",
            suppressServerSideCancel: true
        )
        try await connection.connect()
        try await connection.finishConnecting()
        defer { connection.disconnect() }

        let result = try await connection.boundedQuery(Self.events, parameters: [.text("0")], rowCap: 3)

        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(server.cancelRequests == 0)
    }

    // Share Result reads a truncated result again through this call.
    @Test("A capped read with no parameters stops at the cap with one cancel")
    func plainCappedReadCancels() async throws {
        let server = try Self.server(answering: [
            Self.plainEvents: .init(columns: Self.columns, rows: Self.rows(50), waitsForCancel: true),
        ])
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        let result = try await driver.executeUserQuery(query: Self.plainEvents, rowCap: 3, parameters: nil)

        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(server.cancelRequests == 1)
        #expect(server.parsedStatements.last == Self.plainEvents)
    }
}
