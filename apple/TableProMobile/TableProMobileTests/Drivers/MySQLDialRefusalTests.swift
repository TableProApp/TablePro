import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MySQLDialRefusalTests {
    @Test(
        "A database refused at sign-in is told apart, and reads as any failed connect",
        arguments: [
            FakeMySQLServer.LoginRefusal(code: 1_049, sqlState: "42000", message: "Unknown database 'app_archive'"),
            FakeMySQLServer.LoginRefusal(
                code: 1_044, sqlState: "42000", message: "Access denied for user 'app'@'%' to database 'app_archive'"
            ),
        ]
    )
    func refusedDatabase(_ refusal: FakeMySQLServer.LoginRefusal) async throws {
        let error = try await connectError(answering: refusal)

        guard case MySQLError.databaseRefused(let message)? = error else {
            Issue.record("Expected a refused database, got \(String(describing: error))")
            return
        }
        #expect(message == refusal.message)
        #expect(error?.localizedDescription == "MySQL connection failed: \(refusal.message)")
    }

    // 1524 is a sign-in plugin the server has not loaded; 1105 is what another server may send for anything.
    @Test(
        "Any other refusal stays a failed connect, whatever database the dial names",
        arguments: [
            FakeMySQLServer.LoginRefusal(
                code: 1_045, sqlState: "28000", message: "Access denied for user 'app'@'10.0.0.2' (using password: YES)"
            ),
            FakeMySQLServer.LoginRefusal(
                code: 1_698, sqlState: "28000", message: "Access denied for user 'app'@'10.0.0.2'"
            ),
            FakeMySQLServer.LoginRefusal(
                code: 4_151, sqlState: "HY000", message: "Access denied, this account is locked"
            ),
            FakeMySQLServer.LoginRefusal(code: 1_040, sqlState: "08004", message: "Too many connections"),
            FakeMySQLServer.LoginRefusal(
                code: 1_524, sqlState: "HY000", message: "Plugin 'mysql_native_password' is not loaded"
            ),
            FakeMySQLServer.LoginRefusal(code: 1_105, sqlState: "HY000", message: "Unknown database 'app_archive'"),
        ]
    )
    func refusedSignIn(_ refusal: FakeMySQLServer.LoginRefusal) async throws {
        let error = try await connectError(answering: refusal)

        guard case MySQLError.connectionFailed(let message)? = error else {
            Issue.record("Expected a failed connect, got \(String(describing: error))")
            return
        }
        #expect(message == refusal.message)
    }

    // Preferred asks for TLS first, then signs in again without it, where the server refuses the database.
    @Test("A database refused after Preferred falls back to plaintext is still told apart")
    func refusedDatabaseAfterPlaintextRetry() async throws {
        let refusal = FakeMySQLServer.LoginRefusal(code: 1_049, sqlState: "42000", message: "Unknown database 'app_archive'")
        let error = try await connectError(
            answering: refusal,
            ssl: DriverSSLConfiguration(mode: .require, isPreferred: true),
            sessions: 2
        )

        guard case MySQLError.databaseRefused(let message)? = error else {
            Issue.record("Expected a refused database, got \(String(describing: error))")
            return
        }
        #expect(message == refusal.message)
    }

    private func connectError(
        answering refusal: FakeMySQLServer.LoginRefusal,
        ssl: DriverSSLConfiguration = .disabled,
        sessions: Int = 1
    ) async throws -> (any Error)? {
        let server = try FakeMySQLServer(identity: nil, refusesLogin: refusal)
        defer { server.close() }
        async let served = server.serve(sessions: sessions)
        let driver = MySQLDriver(
            host: "127.0.0.1", port: server.port, user: "app", password: "app-password", database: "app_archive",
            ssl: ssl
        )
        var thrown: (any Error)?
        do {
            try await driver.connect()
        } catch {
            thrown = error
        }
        _ = await served
        return thrown
    }
}
