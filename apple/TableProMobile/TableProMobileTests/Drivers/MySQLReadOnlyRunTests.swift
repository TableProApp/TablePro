import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

// The fake server gives the first session thread id 1; a kill arrives on a second session.
@Suite(.timeLimit(.minutes(1)))
struct MySQLReadOnlyRunTests {
    private static let scan = "SELECT body FROM events"
    private static let purge = "SELECT purge_events()"
    private static let readOnly = StreamOptions(maxRows: 100, enforcesReadOnly: true)

    private static func wrapped(_ statement: String) -> [String] {
        [MySQLReadOnlyTransaction.begin, statement, MySQLReadOnlyTransaction.end, "SELECT 2"]
    }

    @Test("A Read-Only statement runs inside START TRANSACTION READ ONLY, and ROLLBACK follows its last row")
    func statementRunsInReadOnlyTransaction() async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: 3)
        let run = try await Self.run(on: server) { driver in
            #expect(driver.enforcesReadOnlyMode)
            return try await Self.read(driver.executeStreaming(query: Self.scan, options: Self.readOnly))
        }

        #expect(run.read.rows == 3)
        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped(Self.scan))
    }

    @Test("A session holding LOCK TABLES takes no read-only transaction, which would release the lock")
    func tableLockKeepsTheReadOnlyTransactionOut() async throws {
        let server = try FakeMySQLServer(identity: nil)
        let run = try await Self.run(on: server) { driver in
            let before = await driver.entersReadOnlyMode()
            _ = try await driver.execute(query: "LOCK TABLES events READ")
            let locked = await driver.entersReadOnlyMode()
            _ = try await driver.execute(query: "UNLOCK TABLES")
            return (before: before, locked: locked, unlocked: await driver.entersReadOnlyMode())
        }

        #expect(run.read.before)
        #expect(!run.read.locked)
        #expect(run.read.unlocked)
    }

    @Test("A statement with no result set ends its read-only transaction too")
    func noResultEndsTheTransaction() async throws {
        let server = try FakeMySQLServer(identity: nil)
        let run = try await Self.run(on: server) { driver in
            try await Self.read(driver.executeStreaming(query: "DO 1", options: Self.readOnly))
        }

        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped("DO 1"))
    }

    @Test("Without Read-Only, on TiDB and on a server older than READ ONLY, the statement runs with no transaction around it", arguments: [
        (DatabaseType.mysql, "8.0.36", false), (.tidb, "8.0.11-TiDB-v8.5.1", true), (.mysql, "5.6.4-log", true),
        (.mariadb, "5.5.64-MariaDB", true),
    ])
    func otherRunsAreNotWrapped(type: DatabaseType, banner: String, enforcesReadOnly: Bool) async throws {
        let server = try FakeMySQLServer(
            identity: nil, streamsRowsStarting: Self.scan, streamedRows: 3, serverVersion: banner
        )
        let options = StreamOptions(maxRows: 100, enforcesReadOnly: enforcesReadOnly)
        let run = try await Self.run(on: server, databaseType: type) { driver in
            try await Self.read(driver.executeStreaming(query: Self.scan, options: options))
        }

        #expect(run.read.rows == 3)
        #expect(Array(run.served.queries.suffix(2)) == [Self.scan, "SELECT 2"])
        #expect(!run.served.queries.contains(MySQLReadOnlyTransaction.begin))
    }

    @Test("A statement that fails stays a query error, and its read-only transaction still ends")
    func failedStatementEndsTheTransaction() async throws {
        let missing = FakeMySQLServer.Failure(code: 1_146, sqlState: "42S02", message: "Table 'app.events' doesn't exist")
        let server = try FakeMySQLServer(identity: nil, failures: [Self.scan: missing])
        let run = try await Self.run(on: server) { driver in
            await #expect(throws: MySQLError.self) {
                _ = try await Self.read(driver.executeStreaming(query: Self.scan, options: Self.readOnly))
            }
        }

        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped(Self.scan))
    }

    @Test("1792 is Read-Only's refusal, whether it ends the statement or its rows", arguments: [nil, 2] as [Int?])
    func refusalCodeIsReadOnlysRefusal(rowsFirst: Int?) async throws {
        let server = try FakeMySQLServer(
            identity: nil, failures: [Self.purge: .readOnlyRefusal(rowsFirst: rowsFirst)]
        )
        let run = try await Self.run(on: server) { driver in
            await #expect(throws: ReadOnlyModeRefusal.self) {
                _ = try await Self.read(driver.executeStreaming(query: Self.purge, options: Self.readOnly))
            }
        }

        guard case .refused(let message, let serverMessage)? = run.read else {
            Issue.record("expected Read-Only's refusal, got \(String(describing: run.read))")
            return
        }
        #expect(message == MySQLReadOnlyTransaction.refusalMessage(.safeMode))
        #expect(serverMessage.contains("Cannot execute statement in a READ ONLY transaction."))
        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped(Self.purge))
    }

    @Test("A session with a transaction open is refused before anything is sent")
    func openTransactionIsRefused() async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: 3)
        let run = try await Self.run(on: server, closingWith: "ROLLBACK") { driver in
            _ = try await driver.execute(query: "BEGIN")
            return await #expect(throws: ReadOnlyModeRefusal.self) {
                _ = try await Self.read(driver.executeStreaming(query: Self.scan, options: Self.readOnly))
            }
        }

        #expect(run.read == .sessionNotIdle(message: MySQLReadOnlyTransaction.notIdleMessage(.safeMode)))
        #expect(Array(run.served.queries.suffix(2)) == ["BEGIN", "ROLLBACK"])
    }

    @Test("A Read-Only read on a session holding LOCK TABLES is refused before the read-only transaction goes out")
    func tableLockIsRefusedByTheDriver() async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: 3)
        let run = try await Self.run(on: server, closingWith: "UNLOCK TABLES") { driver in
            _ = try await driver.execute(query: "LOCK TABLES events READ")
            return await #expect(throws: ReadOnlyModeRefusal.self) {
                _ = try await Self.read(driver.executeStreaming(query: Self.scan, options: Self.readOnly))
            }
        }

        #expect(run.read == .sessionNotIdle(message: MySQLReadOnlyTransaction.notIdleMessage(.safeMode)))
        #expect(Array(run.served.queries.suffix(2)) == ["LOCK TABLES events READ", "UNLOCK TABLES"])
    }

    @Test("The session reads as idle during and after a Read-Only read")
    func streamReadsAsIdle() async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: 10_000)
        let run = try await Self.run(on: server) { driver in
            var midStream: DriverTransactionState?
            let options = StreamOptions(maxRows: 100_000, enforcesReadOnly: true)
            for try await element in driver.executeStreaming(query: Self.scan, options: options) {
                guard case .row = element, midStream == nil else { continue }
                midStream = await driver.sessionTransactionState()
            }
            return (midStream: midStream, after: await driver.sessionTransactionState())
        }

        #expect(run.read.midStream == .idle)
        #expect(run.read.after == .idle)
    }

    @Test("At the row cap the statement is killed and its read-only transaction ends")
    func rowCapEndsTheTransaction() async throws {
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: 1_000_000)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2)
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        let read = try await Self.read(driver.executeStreaming(query: Self.scan, options: Self.readOnly))
        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()

        let served = await sessions
        #expect(read.rows == 100)
        #expect(read.cappedAt == 100)
        #expect(served[1].queries == ["KILL QUERY 1"])
        #expect(served[0].streamWasKilled)
        #expect(Array(served[0].queries.suffix(4)) == Self.wrapped(Self.scan))
    }

    @Test("A query sent while a Read-Only read streams reaches the server after its ROLLBACK")
    func replacedStreamEndsTheTransaction() async throws {
        let rows = 50_000
        let server = try FakeMySQLServer(identity: nil, streamsRowsStarting: Self.scan, streamedRows: rows)
        let run = try await Self.run(on: server, closingWith: nil) { driver in
            var read = Read()
            let options = StreamOptions(maxRows: 100_000, enforcesReadOnly: true)
            for try await element in driver.executeStreaming(query: Self.scan, options: options) {
                guard case .row = element else { continue }
                read.rows += 1
                if read.rows == 1 { _ = try await driver.execute(query: "SELECT 2") }
            }
            return read
        }

        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped(Self.scan))
    }

    private struct Read {
        var rows = 0
        var cappedAt: Int?
    }

    private struct Run<Value> {
        let read: Value
        let served: FakeMySQLServer.Session
    }

    // Connects, runs `body`, sends `closingWith` so the server shows what came after it, and disconnects.
    private static func run<Value>(
        on server: FakeMySQLServer,
        databaseType: DatabaseType = .mysql,
        closingWith closing: String? = "SELECT 2",
        _ body: (MySQLDriver) async throws -> Value
    ) async throws -> Run<Value> {
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = Self.driver(port: server.port, databaseType: databaseType)
        try await driver.connect()
        let read = try await body(driver)
        if let closing { _ = try await driver.execute(query: closing) }
        try await driver.disconnect()
        return Run(read: read, served: await session)
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
