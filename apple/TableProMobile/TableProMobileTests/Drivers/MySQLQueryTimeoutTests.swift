import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MySQLQueryTimeoutTests {
    @Test("Without a query timeout a statement has no socket read timeout to fail on")
    func noQueryTimeoutNoSocketTimeout() {
        #expect(Self.driver(queryTimeoutSeconds: nil).socketTimeoutSeconds == 0)
        #expect(Self.driver(queryTimeoutSeconds: 0).socketTimeoutSeconds == 0)
    }

    @Test("A query timeout keeps the socket open past the server's own limit")
    func socketTimeoutOutlastsQueryTimeout() {
        #expect(Self.driver(queryTimeoutSeconds: 45).socketTimeoutSeconds == 75)
    }

    @Test(
        "The factory hands the connection's query timeout to the MySQL driver",
        arguments: [DatabaseType.mysql, .mariadb, .tidb, .oceanbase]
    )
    func factoryPassesQueryTimeout(type: DatabaseType) throws {
        let timed = DatabaseConnection(name: "Shop", type: type, host: "db.example.com", queryTimeoutSeconds: 45)
        let untimed = DatabaseConnection(name: "Shop", type: type, host: "db.example.com")

        let timedDriver = try #require(try IOSDriverFactory().createDriver(for: timed, password: nil) as? MySQLDriver)
        let untimedDriver = try #require(try IOSDriverFactory().createDriver(for: untimed, password: nil) as? MySQLDriver)

        #expect(timedDriver.queryTimeoutSeconds == 45)
        #expect(timedDriver.socketTimeoutSeconds == 75)
        #expect(untimedDriver.socketTimeoutSeconds == 0)
    }

    @Test("A query timeout reaches the server as the session's statement limit")
    func queryTimeoutReachesServer() async throws {
        let server = try FakeMySQLServer(identity: nil)
        defer { server.close() }
        async let session = server.serveOneSession()

        let driver = Self.driver(queryTimeoutSeconds: 45, port: server.port)
        try await driver.connect()
        try await driver.disconnect()

        let served = await session
        #expect(served.queries.contains("SET SESSION max_execution_time = 45000"))
    }

    @Test("Without a query timeout the session keeps the server's own limit")
    func noQueryTimeoutSendsNoLimit() async throws {
        let server = try FakeMySQLServer(identity: nil)
        defer { server.close() }
        async let session = server.serveOneSession()

        let driver = Self.driver(queryTimeoutSeconds: nil, port: server.port)
        try await driver.connect()
        try await driver.disconnect()

        let served = await session
        let setsLimit = served.queries.contains { $0.contains("max_execution_time") }
        #expect(served.loggedIn)
        #expect(!setsLimit)
    }

    @Test("Each engine gets its own statement limit")
    func statementLimitPerEngine() {
        #expect(
            MySQLDriver.sessionSetupStatements(for: .mysql, banner: "8.4.11", queryTimeoutSeconds: 45)
                == ["SET SESSION max_execution_time = 45000"]
        )
        #expect(
            MySQLDriver.sessionSetupStatements(for: .mariadb, banner: "10.6.28-MariaDB", queryTimeoutSeconds: 45)
                == ["SET SESSION max_statement_time = 45"]
        )
        #expect(
            MySQLDriver.sessionSetupStatements(for: .tidb, banner: "8.0.11-TiDB-v8.5.0", queryTimeoutSeconds: 45)
                == ["SET SESSION max_execution_time = 45000"]
        )
        #expect(
            MySQLDriver.sessionSetupStatements(for: .oceanbase, banner: nil, queryTimeoutSeconds: 45)
                == ["SET SESSION ob_query_timeout = 45000000", "SET SESSION max_execution_time = 0"]
        )
        #expect(MySQLDriver.sessionSetupStatements(for: .mysql, banner: "8.4.11", queryTimeoutSeconds: 0).isEmpty)
    }

    private static func driver(queryTimeoutSeconds: Int?, port: Int = 3_306) -> MySQLDriver {
        MySQLDriver(
            host: "127.0.0.1", port: port, user: "app", password: "app-password", database: "",
            queryTimeoutSeconds: queryTimeoutSeconds
        )
    }
}
