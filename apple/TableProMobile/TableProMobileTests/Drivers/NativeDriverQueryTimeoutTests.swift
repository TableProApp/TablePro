import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite(.timeLimit(.minutes(1)))
struct NativeDriverQueryTimeoutTests {
    @Test("A PostgreSQL query timeout reaches the server as the session's statement_timeout")
    func postgreSQLTimeoutReachesServer() async throws {
        let statements = try await Self.postgreSQLSession(queryTimeoutSeconds: 45)
        #expect(statements.contains("SET statement_timeout = 45000"))
    }

    @Test("Without a query timeout a PostgreSQL session keeps the server's own limit")
    func postgreSQLWithoutTimeoutSendsNone() async throws {
        let statements = try await Self.postgreSQLSession(queryTimeoutSeconds: nil)
        #expect(!statements.contains { $0.contains("statement_timeout") })
        #expect(PostgreSQLDriver.sessionSetupStatements(queryTimeoutSeconds: 0).isEmpty)
    }

    @Test("The factory hands the connection's query timeout to PostgreSQL and Redshift", arguments: [
        DatabaseType.postgresql, .redshift,
    ])
    func factoryPassesPostgreSQLTimeout(type: DatabaseType) throws {
        let connection = DatabaseConnection(name: "Shop", type: type, host: "db.example.com", queryTimeoutSeconds: 45)
        let driver = try #require(try IOSDriverFactory().createDriver(for: connection, password: nil) as? PostgreSQLDriver)
        #expect(driver.queryTimeoutSeconds == 45)
    }

    @Test("SQL Server takes a query timeout as its lock wait, as the Mac does")
    func sqlServerTimeoutIsLockWait() throws {
        let connection = DatabaseConnection(name: "Shop", type: .mssql, host: "db.example.com", queryTimeoutSeconds: 45)
        let driver = try #require(try IOSDriverFactory().createDriver(for: connection, password: nil) as? MSSQLDriver)

        #expect(driver.queryTimeoutSeconds == 45)
        #expect(MSSQLDriver.sessionSetupStatements(queryTimeoutSeconds: 45) == ["SET LOCK_TIMEOUT 45000"])
        #expect(MSSQLDriver.sessionSetupStatements(queryTimeoutSeconds: nil).isEmpty)
        #expect(MSSQLDriver.sessionSetupStatements(queryTimeoutSeconds: 0).isEmpty)
    }

    @Test("An Oracle query timeout reaches the core that ends a statement past it")
    func oracleTimeoutReachesCore() throws {
        let timed = DatabaseConnection(name: "Shop", type: .oracle, host: "db.example.com", queryTimeoutSeconds: 45)
        let untimed = DatabaseConnection(name: "Shop", type: .oracle, host: "db.example.com")

        let timedDriver = try #require(try IOSDriverFactory().createDriver(for: timed, password: nil) as? OracleDriver)
        let untimedDriver = try #require(try IOSDriverFactory().createDriver(for: untimed, password: nil) as? OracleDriver)

        #expect(timedDriver.queryTimeoutSeconds == 45)
        #expect(untimedDriver.queryTimeoutSeconds == 0)
    }

    private static func postgreSQLSession(queryTimeoutSeconds: Int?) async throws -> [String] {
        let server = try FakePostgreSQLServer()
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = PostgreSQLDriver(
            host: "127.0.0.1", port: server.port, user: "app", password: "app-password", database: "app",
            queryTimeoutSeconds: queryTimeoutSeconds
        )
        try await driver.connect()
        try await driver.disconnect()
        let served = await session
        #expect(served.startedUp)
        return served.queries
    }
}
