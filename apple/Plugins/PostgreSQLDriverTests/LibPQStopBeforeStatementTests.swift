//
//  LibPQStopBeforeStatementTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// A Stop that arrives while the driver runs a round trip of its own (the savepoint probe, the cursor read's savepoint)
// is spent on that round trip, so the user's statement must not go out after it.
@Suite(.timeLimit(.minutes(1)))
struct LibPQStopBeforeStatementTests {
    private final class ConnectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var held: LibPQPluginConnection?

        var connection: LibPQPluginConnection? {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }

        func stop() {
            _ = connection?.cancellationGate.cancel()
        }
    }

    private static func connected(to server: LibPQScriptedServer, box: ConnectionBox) async throws -> LibPQPluginConnection {
        let connection = LibPQPluginConnection(
            host: "127.0.0.1", port: server.port, user: "postgres", password: nil, database: "postgres"
        )
        box.connection = connection
        try await connection.connect()
        try await connection.finishConnecting()
        return connection
    }

    @Test("A Stop during the savepoint probe sends none of the user's statement and reports cancelled")
    func stopDuringProbeSendsNothing() async throws {
        let box = ConnectionBox()
        let server = try LibPQScriptedServer(onQuery: { query in
            if query.contains("tablepro_probe") { box.stop() }
        })
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server, box: box)
        defer { connection.disconnect() }

        var failure: Error?
        do {
            _ = try await connection.boundedQuery("DELETE FROM big WHERE flagged", rowCap: 1_000)
        } catch {
            failure = error
        }

        let sent = server.queries
        let probed = sent.contains { $0.contains("tablepro_probe") }
        let deleteSent = sent.contains { $0.contains("DELETE FROM big") }
        #expect(failure is CancellationError)
        #expect(probed)
        #expect(!deleteSent)
    }

    @Test("A Stop during the cursor read's savepoint sends no cursor and reports cancelled")
    func stopDuringCursorSavepointSendsNothing() async throws {
        let box = ConnectionBox()
        let server = try LibPQScriptedServer(
            status: { query, earlier in
                (earlier + [query]).contains("BEGIN") ? LibPQScriptedServer.inTransaction : LibPQScriptedServer.idle
            },
            onQuery: { query in
                if query.hasPrefix("SAVEPOINT tablepro_capped_read") { box.stop() }
            }
        )
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server, box: box)
        defer { connection.disconnect() }

        _ = try await connection.boundedQuery("SELECT 1", rowCap: 10)
        _ = try await connection.executeQuery("BEGIN")
        var failure: Error?
        do {
            _ = try await connection.boundedQuery("SELECT * FROM events", rowCap: 1_000)
        } catch {
            failure = error
        }

        let sent = server.queries
        let savepointSent = sent.contains { $0.hasPrefix("SAVEPOINT tablepro_capped_read") }
        let readSent = sent.contains { $0.contains("DECLARE") || $0.contains("FROM events") }
        #expect(failure is CancellationError)
        #expect(savepointSent)
        #expect(!readSent)
    }

    @Test("A Stop during a stream's savepoint probe sends none of the user's statement and ends cancelled")
    func stopDuringStreamProbeSendsNothing() async throws {
        let box = ConnectionBox()
        let server = try LibPQScriptedServer(onQuery: { query in
            if query.contains("tablepro_probe") { box.stop() }
        })
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server, box: box)
        defer { connection.disconnect() }

        var failure: Error?
        do {
            for try await _ in connection.streamQuery("SELECT * FROM events") {}
        } catch {
            failure = error
        }

        let sent = server.queries
        let probed = sent.contains { $0.contains("tablepro_probe") }
        let readSent = sent.contains { $0.contains("FROM events") }
        #expect(failure is CancellationError)
        #expect(probed)
        #expect(!readSent)
    }
}
