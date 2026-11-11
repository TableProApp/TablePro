import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

// The fake server gives the first session thread id 1; a kill arrives on a second session.
@Suite(.timeLimit(.minutes(1)))
struct MySQLRowCapTests {
    private static let scan = "SELECT body FROM events"

    @Test("At the row cap the statement is stopped on the server instead of read to its end")
    func rowCapKillsTheRest() async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: 1_000_000)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2)
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        let read = try await Self.read(driver.executeStreaming(query: Self.scan, options: StreamOptions(maxRows: 100)))
        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(read.rows == 100)
        #expect(read.cappedAt == 100)
        #expect(served[1].queries == ["KILL QUERY 1"])
        #expect(served[0].streamWasKilled)
        #expect(served[0].streamedRowsSent < 1_000_000)
        #expect(Array(served[0].queries.suffix(2)) == [Self.scan, "SELECT 2"])
    }

    @Test("A result that exactly fills the cap is complete, and nothing is killed")
    func filledCapIsComplete() async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: 100)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        let read = try await Self.read(driver.executeStreaming(query: Self.scan, options: StreamOptions(maxRows: 100)))
        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await session
        #expect(read.rows == 100)
        #expect(read.cappedAt == nil)
        #expect(!served.streamWasKilled)
        #expect(Array(served.queries.suffix(2)) == [Self.scan, "SELECT 2"])
    }

    @Test("On TiDB the cap reads the rest rather than kill, which would drop the session once the statement ended")
    func tidbRowCapSendsNoKill() async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: 300)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2, acceptingWithin: 2_000)
        let driver = Self.driver(port: server.port, databaseType: .tidb)
        try await driver.connect()

        let read = try await Self.read(driver.executeStreaming(query: Self.scan, options: StreamOptions(maxRows: 100)))
        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(read.rows == 100)
        #expect(read.cappedAt == 100)
        #expect(served[1].queries.isEmpty)
        #expect(served[0].streamedRowsSent == 300)
        #expect(Array(served[0].queries.suffix(2)) == [Self.scan, "SELECT 2"])
    }

    // A kill would roll back the delete on InnoDB, or leave it half done on Aria or MyISAM.
    @Test("A DELETE ... RETURNING past the cap is read to its end, with no kill")
    func deleteReturningPastCapRunsToEnd() async throws {
        try await Self.expectReadToEnd(
            "DELETE FROM events WHERE created < '2020-01-01' RETURNING id", databaseType: .mariadb
        )
    }

    // A kill would stop the procedure in its SELECT, or in the statements after it.
    @Test("A CALL whose first result passes the cap is read to its end, with no kill")
    func callPastCapRunsToEnd() async throws {
        try await Self.expectReadToEnd("CALL archive_events()", databaseType: .mysql)
    }

    @Test("Only a lone read is stopped at the cap", arguments: [
        ("SELECT body FROM events", DatabaseType.mysql),
        ("WITH recent AS (SELECT * FROM events) SELECT * FROM recent", DatabaseType.mysql),
        ("TABLE events", DatabaseType.mysql),
        ("VALUES ROW(1), ROW(2)", DatabaseType.mysql),
        ("SELECT body FROM events", DatabaseType.mariadb),
    ])
    func loneReadIsCapped(sql: String, databaseType: DatabaseType) {
        #expect(CappedRead.qualifies(sql, databaseType: databaseType))
    }

    @Test("A statement that writes or runs more is never stopped at the cap", arguments: [
        ("DELETE FROM events RETURNING id", DatabaseType.mariadb),
        ("INSERT INTO archive SELECT * FROM events RETURNING id", DatabaseType.mariadb),
        ("REPLACE INTO archive SELECT * FROM events RETURNING id", DatabaseType.mariadb),
        ("CALL archive_events()", DatabaseType.mysql),
        ("WITH old AS (SELECT id FROM events) DELETE FROM events WHERE id IN (SELECT id FROM old)", DatabaseType.mysql),
        ("SELECT * FROM events INTO OUTFILE '/tmp/events.csv'", DatabaseType.mysql),
        ("SHOW PROCESSLIST", DatabaseType.mysql),
    ])
    func writeIsNeverCapped(sql: String, databaseType: DatabaseType) {
        #expect(!CappedRead.qualifies(sql, databaseType: databaseType))
    }

    private static func expectReadToEnd(_ statement: String, databaseType: DatabaseType) async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: statement, streamedRows: 300)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2, acceptingWithin: 2_000)
        let driver = Self.driver(port: server.port, databaseType: databaseType)
        try await driver.connect()

        let read = try await Self.read(driver.executeStreaming(query: statement, options: StreamOptions(maxRows: 100)))
        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(read.rows == 100)
        #expect(read.cappedAt == 100)
        #expect(served[1].queries.isEmpty)
        #expect(!served[0].streamWasKilled)
        #expect(served[0].streamedRowsSent == 300)
        #expect(Array(served[0].queries.suffix(2)) == [statement, "SELECT 2"])
    }

    private struct Read {
        var rows = 0
        var cappedAt: Int?
    }

    private static func read(_ stream: AsyncThrowingStream<StreamElement, Error>) async throws -> Read {
        var read = Read()
        for try await element in stream {
            switch element {
            case .row:
                read.rows += 1
            case .truncated(let reason):
                if case .rowCap(let cap) = reason { read.cappedAt = cap }
            default:
                break
            }
        }
        return read
    }

    private static func driver(port: Int, databaseType: DatabaseType = .mysql) -> MySQLDriver {
        MySQLDriver(
            host: "127.0.0.1", port: port, user: "app", password: "app-password", database: "",
            databaseType: databaseType
        )
    }
}
