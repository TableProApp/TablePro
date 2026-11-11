//
//  LibPQBoundedReadOnlyTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// A scripted server sends every row at once and, where the answer says so, holds the statement open until a cancel
// arrives, so a read that does not stop and cancel would end only after the server gives up waiting. Where the server
// takes no cancel, `CursorTable` counts the rows the cursor's FETCHes were sent.
@Suite(.timeLimit(.minutes(1)))
struct LibPQBoundedReadOnlyTests {
    private static let events = "SELECT * FROM events"

    private static let columns = [
        LibPQScriptedServer.Column(name: "id", table: 16_400, attribute: 1, type: 23),
        LibPQScriptedServer.Column(name: "body", table: 16_400, attribute: 3, type: 25),
    ]

    private static func rows(_ count: Int, width: Int = 10) -> [[String?]] {
        (0..<count).map { index in [String(index), String(repeating: "x", count: width)] }
    }

    private static func status(_ query: String, _ earlier: [String]) -> UInt8 {
        let controls = [LibPQReadOnlyTransaction.begin, LibPQReadOnlyTransaction.end, "BEGIN"]
        let last = (earlier + [query]).last { controls.contains($0) }
        guard let last, last != LibPQReadOnlyTransaction.end else { return LibPQScriptedServer.idle }
        return LibPQScriptedServer.inTransaction
    }

    private static func server(answering answer: LibPQScriptedServer.Answer) throws -> LibPQScriptedServer {
        try LibPQScriptedServer(
            status: { query, earlier in Self.status(query, earlier) },
            answer: { query in query == Self.events ? answer : nil }
        )
    }

    private static func connected(
        to server: LibPQScriptedServer,
        suppressingCancel: Bool = false
    ) async throws -> LibPQPluginConnection {
        let connection = LibPQPluginConnection(
            host: "127.0.0.1",
            port: server.port,
            user: "postgres",
            password: nil,
            database: "postgres",
            suppressServerSideCancel: suppressingCancel
        )
        try await connection.connect()
        try await connection.finishConnecting()
        return connection
    }

    private static func read(
        _ connection: LibPQPluginConnection,
        rowCap: Int,
        byteLimit: Int? = nil,
        parameters: [PluginCellValue]? = nil,
        query: String = LibPQBoundedReadOnlyTests.events
    ) async throws -> LibPQPluginQueryResult {
        try await connection.boundedReadOnlyStatement(
            query,
            parameters: parameters,
            bound: LibPQReadBound(rowCap: rowCap, byteLimit: byteLimit),
            reason: .safeMode
        )
    }

    @Test("A read past the row cap keeps the cap, cancels the rest and still rolls back its transaction")
    func stopsAtTheRowCap() async throws {
        let server = try Self.server(answering: .init(columns: Self.columns, rows: Self.rows(50), waitsForCancel: true))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        let before = server.queries.count

        let result = try await Self.read(connection, rowCap: 3)

        let sent = Array(server.queries.dropFirst(before))
        #expect(result.rows.count == 3)
        #expect(result.rows.first == [.text("0"), .text("xxxxxxxxxx")])
        #expect(result.isTruncated)
        #expect(server.cancelRequests == 1)
        #expect(sent == [LibPQReadOnlyTransaction.begin, Self.events, LibPQReadOnlyTransaction.end])
    }

    @Test("A read that passes the byte limit stops there and keeps the row that crossed it")
    func stopsAtTheByteLimit() async throws {
        let wide = Self.rows(50, width: 100)
        let server = try Self.server(answering: .init(columns: Self.columns, rows: wide, waitsForCancel: true))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let result = try await Self.read(connection, rowCap: 1_000, byteLimit: 250)

        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(server.cancelRequests == 1)
        #expect(server.queries.last == LibPQReadOnlyTransaction.end)
    }

    @Test("A result within the cap is read to its end with no cancel")
    func shortResultReadsWhole() async throws {
        let server = try Self.server(answering: .init(columns: Self.columns, rows: Self.rows(2)))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        let before = server.queries.count

        let result = try await Self.read(connection, rowCap: 3, byteLimit: 1_000)

        let sent = Array(server.queries.dropFirst(before))
        #expect(result.rows.count == 2)
        #expect(!result.isTruncated)
        #expect(server.cancelRequests == 0)
        #expect(sent == [LibPQReadOnlyTransaction.begin, Self.events, LibPQReadOnlyTransaction.end])
    }

    // Serves the cursor's FETCHes from a table and counts every row it sent.
    private final class CursorTable: @unchecked Sendable {
        private static let fetchPrefix = "FETCH FORWARD "
        private let lock = NSLock()
        private let rows: [[String?]]
        private var position = 0

        init(_ rows: [[String?]]) {
            self.rows = rows
        }

        var served: Int {
            lock.withLock { position }
        }

        func answer(_ query: String) -> LibPQScriptedServer.Answer? {
            guard query.hasPrefix(Self.fetchPrefix),
                  let count = Int(query.dropFirst(Self.fetchPrefix.count).prefix { $0.isNumber })
            else { return nil }
            return lock.withLock {
                let batch = Array(rows[position..<min(position + count, rows.count)])
                position += batch.count
                return LibPQScriptedServer.Answer(columns: LibPQBoundedReadOnlyTests.columns, rows: batch)
            }
        }
    }

    private static func cursorServer(_ table: CursorTable) throws -> LibPQScriptedServer {
        try LibPQScriptedServer(
            status: { query, earlier in Self.status(query, earlier) },
            answer: { query in table.answer(query) }
        )
    }

    private static let declaredEvents = LibPQBoundedCursor.declaration(of: LibPQBoundedReadOnlyTests.events)

    // PGlite has one connection and takes no cancel request.
    @Test("Without a server cancel the read goes through a cursor and no row past the cap is sent")
    func cursorStopsAtTheRowCap() async throws {
        let table = CursorTable(Self.rows(50))
        let server = try Self.cursorServer(table)
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server, suppressingCancel: true)
        defer { connection.disconnect() }
        let before = server.queries.count

        let result = try await Self.read(connection, rowCap: 3)

        let sent = Array(server.queries.dropFirst(before))
        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(table.served == 4)
        #expect(server.cancelRequests == 0)
        #expect(result.columnSources == [
            PostgreSQLColumnOrigins.Source(relation: 16_400, attribute: 1),
            PostgreSQLColumnOrigins.Source(relation: 16_400, attribute: 3),
        ])
        #expect(sent == [
            LibPQReadOnlyTransaction.begin,
            LibPQBoundedCursor.savepoint,
            Self.declaredEvents,
            LibPQBoundedCursor.fetch(4),
            LibPQReadOnlyTransaction.end,
        ])
    }

    @Test("Through a cursor, the byte limit sizes each fetch, so the read stops with no row left to drain")
    func cursorStopsAtTheByteLimit() async throws {
        let table = CursorTable(Self.rows(50, width: 100))
        let server = try Self.cursorServer(table)
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server, suppressingCancel: true)
        defer { connection.disconnect() }
        let before = server.queries.count

        let result = try await Self.read(connection, rowCap: 1_000, byteLimit: 250)

        let sent = Array(server.queries.dropFirst(before))
        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(table.served == 3)
        #expect(sent.filter { $0.hasPrefix("FETCH") } == [LibPQBoundedCursor.fetch(1), LibPQBoundedCursor.fetch(2)])
        #expect(sent.last == LibPQReadOnlyTransaction.end)
    }

    @Test("Through a cursor, a result within the cap ends with the first short fetch")
    func cursorReadsAShortResultWhole() async throws {
        let table = CursorTable(Self.rows(2))
        let server = try Self.cursorServer(table)
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server, suppressingCancel: true)
        defer { connection.disconnect() }

        let result = try await Self.read(connection, rowCap: 3)

        #expect(result.rows.count == 2)
        #expect(!result.isTruncated)
        #expect(server.queries.filter { $0.hasPrefix("FETCH") } == [LibPQBoundedCursor.fetch(4)])
    }

    @Test("A DECLARE the server refuses is rolled back to its savepoint, and the statement runs the plain way")
    func refusedDeclarationRunsThePlainWay() async throws {
        let refused = LibPQScriptedServer.Failure(sqlState: "42601", message: "syntax error at or near \"DECLARE\"")
        let server = try LibPQScriptedServer(
            status: { query, earlier in Self.status(query, earlier) },
            answer: { query in
                if query.hasPrefix("DECLARE") { return LibPQScriptedServer.Answer(failure: refused) }
                return query == Self.events ? LibPQScriptedServer.Answer(columns: Self.columns, rows: Self.rows(2)) : nil
            }
        )
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server, suppressingCancel: true)
        defer { connection.disconnect() }
        let before = server.queries.count

        let result = try await Self.read(connection, rowCap: 3)

        let sent = Array(server.queries.dropFirst(before))
        #expect(result.rows.count == 2)
        #expect(sent == [
            LibPQReadOnlyTransaction.begin,
            LibPQBoundedCursor.savepoint,
            Self.declaredEvents,
            LibPQBoundedCursor.savepointRollback,
            Self.events,
            LibPQReadOnlyTransaction.end,
        ])
    }

    // `LibPQCappedCursorRead.cursorBody` refuses any semicolon, even one inside a literal.
    @Test("Without a server cancel, a statement no cursor can hold still stops at the cap and drains the rest")
    func drainsWhatNoCursorCanHold() async throws {
        let marked = "SELECT ';' AS mark FROM events"
        let server = try LibPQScriptedServer(
            status: { query, earlier in Self.status(query, earlier) },
            answer: { query in
                query == marked ? LibPQScriptedServer.Answer(columns: Self.columns, rows: Self.rows(50)) : nil
            }
        )
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server, suppressingCancel: true)
        defer { connection.disconnect() }
        let before = server.queries.count

        let result = try await Self.read(connection, rowCap: 3, query: marked)

        #expect(result.rows.count == 3)
        #expect(result.isTruncated)
        #expect(server.cancelRequests == 0)
        #expect(Array(server.queries.dropFirst(before)) == [
            LibPQReadOnlyTransaction.begin, marked, LibPQReadOnlyTransaction.end,
        ])
    }

    @Test("Each column keeps the relation column the first row description named, so masking by origin still works")
    func keepsColumnSources() async throws {
        let columns = Self.columns + [LibPQScriptedServer.Column(name: "total")]
        let server = try Self.server(answering: .init(columns: columns, rows: [["1", "a", "2"]]))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let result = try await Self.read(connection, rowCap: 10)

        #expect(result.columns == ["id", "body", "total"])
        #expect(result.columnSources == [
            PostgreSQLColumnOrigins.Source(relation: 16_400, attribute: 1),
            PostgreSQLColumnOrigins.Source(relation: 16_400, attribute: 3),
            nil,
        ])
    }

    @Test("A write the server refuses at Read-Only names Safe Mode, and the rollback still goes out")
    func refusalNamesSafeMode() async throws {
        let refused = LibPQScriptedServer.Failure(
            sqlState: "25006", message: "cannot execute DELETE in a read-only transaction"
        )
        let server = try Self.server(answering: .init(failure: refused))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let error = await #expect(throws: LibPQPluginError.self) {
            _ = try await Self.read(connection, rowCap: 10)
        }

        #expect(error?.sqlState == "25006")
        #expect(error?.message == LibPQReadOnlyTransaction.refusalMessage(.safeMode))
        #expect(error?.detail?.contains("read-only transaction") == true)
        #expect(server.queries.last == LibPQReadOnlyTransaction.end)
    }

    @Test("A session holding a transaction is refused at Read-Only before anything is sent")
    func refusesAnOpenTransaction() async throws {
        let server = try Self.server(answering: .init(columns: Self.columns, rows: Self.rows(2)))
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        _ = try await connection.executeQuery("BEGIN")
        let before = server.queries.count

        let error = await #expect(throws: LibPQPluginError.self) {
            _ = try await Self.read(connection, rowCap: 10)
        }

        #expect(error?.message == LibPQReadOnlyTransaction.safeModeSessionNotIdle.message)
        #expect(server.queries.count == before)
    }

    @Test("Parameters go out with the statement, a null as a null")
    func bindsParameters() async throws {
        let server = try Self.server(answering: .init())
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        _ = try await Self.read(
            connection,
            rowCap: 10,
            parameters: [.text("7"), .null],
            query: "SELECT * FROM events WHERE id = $1 AND note = $2"
        )

        #expect(server.boundParameters.last == ["7", nil])
        #expect(server.queries.last == LibPQReadOnlyTransaction.end)
    }
}
