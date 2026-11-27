import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PostgreSQLReadOnlyRunTests {
    private static let report = "SELECT n FROM orders"
    private static let purge = "SELECT purge_orders()"
    private static let readOnly = StreamOptions(maxRows: 100, enforcesReadOnly: true)
    private static let wrapped = [LibPQReadOnlyTransaction.begin, report, LibPQReadOnlyTransaction.end, "SELECT 2"]

    @Test("A Read-Only statement runs alone through the extended protocol inside a read-only transaction, then ROLLBACK")
    func statementRunsInReadOnlyTransaction() async throws {
        let server = try FakePostgreSQLServer(replies: [Self.report: .rows(3)])
        let run = try await Self.run(on: server) { driver in
            try await Self.read(driver.executeStreaming(query: Self.report, options: Self.readOnly))
        }

        #expect(run.read.rows == 3)
        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped)
        #expect(run.served.extendedQueries == [Self.report])
    }

    @Test("Without Read-Only, and on Redshift, the statement goes out as a simple query with no transaction around it", arguments: [
        (DatabaseType.postgresql, false), (.redshift, true),
    ])
    func otherRunsAreNotWrapped(type: DatabaseType, enforcesReadOnly: Bool) async throws {
        let server = try FakePostgreSQLServer(replies: [Self.report: .rows(3)])
        let options = StreamOptions(maxRows: 100, enforcesReadOnly: enforcesReadOnly)
        let run = try await Self.run(on: server, databaseType: type) { driver in
            try await Self.read(driver.executeStreaming(query: Self.report, options: options))
        }

        #expect(run.read.rows == 3)
        #expect(Array(run.served.queries.suffix(2)) == [Self.report, "SELECT 2"])
        #expect(run.served.extendedQueries.isEmpty)
    }

    @Test("A statement that fails stays a query error, and its read-only transaction still ends")
    func failedStatementEndsTheTransaction() async throws {
        let server = try FakePostgreSQLServer(replies: [
            Self.report: .failure(sqlState: "42P01", message: "relation \"orders\" does not exist"),
        ])
        let run = try await Self.run(on: server) { driver in
            await #expect(throws: PostgreSQLError.self) {
                _ = try await Self.read(driver.executeStreaming(query: Self.report, options: Self.readOnly))
            }
        }

        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped)
    }

    @Test("The server refusing a write in the read-only transaction is Read-Only's refusal, before or after rows", arguments: [
        0, 2,
    ])
    func refusalStateIsReadOnlysRefusal(rowsFirst: Int) async throws {
        let server = try FakePostgreSQLServer(replies: [
            Self.purge: .failure(
                sqlState: "25006", message: "cannot execute DELETE in a read-only transaction", rowsFirst: rowsFirst
            ),
        ])
        let run = try await Self.run(on: server) { driver in
            await #expect(throws: ReadOnlyModeRefusal.self) {
                _ = try await Self.read(driver.executeStreaming(query: Self.purge, options: Self.readOnly))
            }
        }

        guard case .refused(let message, let serverMessage)? = run.read else {
            Issue.record("expected Read-Only's refusal, got \(String(describing: run.read))")
            return
        }
        #expect(message == LibPQReadOnlyTransaction.refusalMessage(.safeMode))
        #expect(serverMessage.contains("cannot execute DELETE in a read-only transaction"))
        #expect(Array(run.served.queries.suffix(4)) == [
            LibPQReadOnlyTransaction.begin, Self.purge, LibPQReadOnlyTransaction.end, "SELECT 2",
        ])
    }

    @Test("A session with a transaction open is refused before anything is sent")
    func openTransactionIsRefused() async throws {
        let server = try FakePostgreSQLServer(replies: [Self.report: .rows(3)])
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = Self.driver(port: server.port)
        try await driver.connect()

        _ = try await driver.execute(query: "BEGIN")
        let error = await #expect(throws: ReadOnlyModeRefusal.self) {
            _ = try await Self.read(driver.executeStreaming(query: Self.report, options: Self.readOnly))
        }
        _ = try await driver.execute(query: "ROLLBACK")
        try await driver.disconnect()

        let served = await session
        #expect(error == .sessionNotIdle(message: LibPQReadOnlyTransaction.notIdleMessage(.safeMode)))
        #expect(Array(served.queries.suffix(2)) == ["BEGIN", "ROLLBACK"])
        #expect(served.extendedQueries.isEmpty)
    }

    @Test("At the row cap the statement is cancelled and its read-only transaction ends")
    func rowCapEndsTheTransaction() async throws {
        let server = try FakePostgreSQLServer(replies: [Self.report: .rows(1_000)])
        let run = try await Self.run(on: server) { driver in
            try await Self.read(driver.executeStreaming(query: Self.report, options: Self.readOnly))
        }

        #expect(run.read.rows == 100)
        #expect(run.read.cappedAt == 100)
        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped)
    }

    @Test("A query sent while a Read-Only read streams reaches the server after its ROLLBACK")
    func replacedStreamEndsTheTransaction() async throws {
        let rows = 50_000
        let server = try FakePostgreSQLServer(replies: [Self.report: .rows(rows)])
        let run = try await Self.run(on: server, closingWith: nil) { driver in
            var read = Read()
            let options = StreamOptions(maxRows: 100_000, enforcesReadOnly: true)
            for try await element in driver.executeStreaming(query: Self.report, options: options) {
                guard case .row = element else { continue }
                read.rows += 1
                if read.rows == 1 { _ = try await driver.execute(query: "SELECT 2") }
            }
            return read
        }

        #expect(Array(run.served.queries.suffix(4)) == Self.wrapped)
    }

    private struct Read {
        var rows = 0
        var cappedAt: Int?
    }

    private struct Run<Value> {
        let read: Value
        let served: FakePostgreSQLServer.Session
    }

    // Connects, runs `body`, sends `closingWith` so the server shows what came after it, and disconnects.
    private static func run<Value>(
        on server: FakePostgreSQLServer,
        databaseType: DatabaseType = .postgresql,
        closingWith closing: String? = "SELECT 2",
        _ body: (PostgreSQLDriver) async throws -> Value
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

    private static func driver(port: Int, databaseType: DatabaseType = .postgresql) -> PostgreSQLDriver {
        PostgreSQLDriver(
            host: "127.0.0.1", port: port, user: "app", password: "app-password", database: "app",
            databaseType: databaseType
        )
    }
}
