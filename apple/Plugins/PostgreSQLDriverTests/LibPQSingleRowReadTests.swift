//
//  LibPQSingleRowReadTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

private final class LateStopTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var held: LibPQPluginConnection?

    var connection: LibPQPluginConnection? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    func stop() {
        connection?.cancelCurrentQuery()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LibPQSingleRowReadTests {
    private static let events = "SELECT * FROM events"
    private static let insert = "INSERT INTO events VALUES (1)"
    private static let columns = [LibPQScriptedServer.Column(name: "id", type: 23)]

    private static func connected(to server: LibPQScriptedServer) async throws -> LibPQPluginConnection {
        let connection = LibPQPluginConnection(
            host: "127.0.0.1", port: server.port, user: "postgres", password: nil, database: "postgres"
        )
        try await connection.connect()
        try await connection.finishConnecting()
        return connection
    }

    private static func server(answering answer: LibPQScriptedServer.Answer) throws -> LibPQScriptedServer {
        try LibPQScriptedServer(answer: { query in query == Self.events ? answer : nil })
    }

    @Test("An uncapped read returns every row and the time to its first")
    func readsEveryRow() async throws {
        let rows: [[String?]] = (0..<500).map { [String($0)] }
        let server = try Self.server(answering: .init(columns: Self.columns, rows: rows))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let result = try await connection.executeSingleStatement(Self.events)

        #expect(result.rows.count == 500)
        #expect(result.rows.last == [.text("499")])
        #expect(result.affectedRows == 500)
        #expect(result.columns == ["id"])
        #expect(result.firstRowTime != nil)
        #expect(!result.isTruncated)
    }

    @Test("A read with parameters goes through the same read")
    func parametersTakeTheSameRead() async throws {
        let server = try Self.server(answering: .init(columns: Self.columns, rows: [["1"]]))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let result = try await connection.executeParameterizedQuery(Self.events, parameters: [.text("x")])

        #expect(result.rows == [[.text("1")]])
        #expect(result.firstRowTime != nil)
        #expect(server.boundParameters.last == ["x"])
    }

    @Test("A statement that fails after some of its rows fails the whole read")
    func failurePartWayFailsTheRead() async throws {
        let failure = LibPQScriptedServer.Failure(sqlState: "22012", message: "division by zero")
        let server = try Self.server(answering: .init(columns: Self.columns, rows: [["1"], ["2"]], failureAfterRows: failure))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        await #expect {
            _ = try await connection.executeSingleStatement(Self.events)
        } throws: { error in
            (error as? LibPQPluginError)?.sqlState == "22012"
        }

        let next = try await connection.executeQuery("SELECT 1")
        #expect(next.rows.isEmpty)
    }

    @Test("A Stop that comes too late leaves the finished statement's result standing")
    func lateStopKeepsTheResult() async throws {
        let target = LateStopTarget()
        let server = try LibPQScriptedServer(onQuery: { query in
            if query == Self.insert { target.stop() }
        })
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        target.connection = connection

        let result = try await connection.executeSingleStatement(Self.insert)

        #expect(result.rows.isEmpty)
        #expect(result.commandTag == "SELECT 0")
    }

    @Test("Stop ends the read and reports a cancellation")
    func stopCancelsTheRead() async throws {
        let (arrived, signal) = AsyncStream.makeStream(of: Void.self)
        let server = try LibPQScriptedServer(
            onQuery: { query in if query == Self.events { signal.yield() } },
            answer: { query in
                query == Self.events
                    ? LibPQScriptedServer.Answer(columns: Self.columns, rows: [["1"]], waitsForCancel: true)
                    : nil
            }
        )
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let read = Task { try await connection.executeSingleStatement(Self.events) }
        for await _ in arrived { break }
        connection.cancelCurrentQuery()

        await #expect(throws: CancellationError.self) { _ = try await read.value }
        #expect(server.cancelRequests == 1)
    }
}
