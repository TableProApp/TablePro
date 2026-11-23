//
//  LibPQSavepointProbeTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// The probe's answer is used only inside a block, so it goes out before the statement that opens one and never before
// a read.
@Suite(.timeLimit(.minutes(1)))
struct LibPQSavepointProbeTests {
    private static let probe = "tablepro_probe"
    private static let events = "SELECT * FROM events"

    private static func status(_ query: String, _ earlier: [String]) -> UInt8 {
        let last = (earlier + [query]).last { ["BEGIN", "COMMIT", "ROLLBACK"].contains($0) }
        return last == "BEGIN" ? LibPQScriptedServer.inTransaction : LibPQScriptedServer.idle
    }

    private static func server(failingStatement: String? = nil) throws -> LibPQScriptedServer {
        try LibPQScriptedServer(
            status: { query, earlier in Self.status(query, earlier) },
            failingStatement: failingStatement
        )
    }

    private static func connected(to server: LibPQScriptedServer) async throws -> LibPQPluginConnection {
        let connection = LibPQPluginConnection(
            host: "127.0.0.1", port: server.port, user: "postgres", password: nil, database: "postgres"
        )
        try await connection.connect()
        try await connection.finishConnecting()
        return connection
    }

    private static func connectedDriver(to server: LibPQScriptedServer) async throws -> PostgreSQLPluginDriver {
        let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: server.port, username: "postgres", password: "", database: "postgres"
        ))
        try await driver.connect()
        return driver
    }

    private static func probes(in queries: [String]) -> Int {
        queries.filter { $0.contains(probe) }.count
    }

    @Test("The first capped read sends no savepoint probe")
    func firstReadSendsNoProbe() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        _ = try await connection.boundedQuery(Self.events, rowCap: 10)

        #expect(Self.probes(in: server.queries) == 0)
        #expect(server.queries.last == Self.events)
    }

    @Test("A user's BEGIN at idle sends the probe first, once per connection")
    func userBeginProbesOnce() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }
        let before = server.queries.count

        _ = try await driver.execute(query: "BEGIN")
        _ = try await driver.execute(query: "COMMIT")
        _ = try await driver.execute(query: "BEGIN")

        let sent = Array(server.queries.dropFirst(before))
        #expect(Self.probes(in: sent) == 1)
        #expect(sent.first?.contains(Self.probe) == true)
        #expect(Array(sent.dropFirst()) == ["BEGIN", "COMMIT", "BEGIN"])
    }

    @Test("A session whose first statement is BEGIN reads a capped result through the cursor in that block")
    func blockOpenedFirstGetsTheCursor() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }

        _ = try await driver.execute(query: "BEGIN")
        _ = try await driver.executeBoundedQuery(query: Self.events, rowCap: 10)

        let sent = server.queries
        #expect(sent.contains("SAVEPOINT \(LibPQCappedCursorRead.cursorName)"))
        #expect(sent.contains { $0.hasPrefix("DECLARE \(LibPQCappedCursorRead.cursorName)") })
        #expect(!sent.contains(Self.events))
    }

    @Test("A block the host opens, as Manual Commit does, probes first, once per connection")
    func beginTransactionProbesOnce() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let driver = try await Self.connectedDriver(to: server)
        defer { driver.disconnect() }
        let before = server.queries.count

        try await driver.beginTransaction(mode: .serverDefault)
        _ = try await driver.execute(query: "COMMIT")
        try await driver.beginTransaction(mode: .serverDefault)

        let sent = Array(server.queries.dropFirst(before))
        #expect(Self.probes(in: sent) == 1)
        #expect(sent.first?.contains(Self.probe) == true)
        #expect(Array(sent.dropFirst()) == ["BEGIN", "COMMIT", "BEGIN"])
    }

    @Test("A ping or a scoped catalog read sends no probe")
    func pingAndScopedReadSendNoProbe() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        try await connection.ping()
        _ = try await connection.executeTransactionScopedRead("SELECT 1")

        #expect(Self.probes(in: server.queries) == 0)
    }

    @Test("A probe the server refuses leaves the user's block on the plain read")
    func refusedProbeKeepsThePlainRead() async throws {
        let server = try Self.server(failingStatement: Self.probe)
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        _ = try await connection.executeQuery("BEGIN", probesBeforeBlock: true)
        _ = try await connection.boundedQuery(Self.events, rowCap: 10)

        let sent = server.queries
        #expect(Self.probes(in: sent) == 1)
        #expect(sent.contains("BEGIN"))
        #expect(!sent.contains { $0.contains(LibPQCappedCursorRead.cursorName) })
        #expect(sent.last == Self.events)
    }
}
