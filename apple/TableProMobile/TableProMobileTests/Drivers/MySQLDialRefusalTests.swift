import Foundation
@testable import TableProMobile
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MySQLDialRefusalTests {
    @Test(
        "A database the server refuses at sign-in is told apart, and reads as any failed connect",
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

    @Test("A refused sign-in stays a failed connect, whatever database the dial names")
    func refusedSignIn() async throws {
        let refusal = FakeMySQLServer.LoginRefusal(
            code: 1_045, sqlState: "28000", message: "Access denied for user 'app'@'10.0.0.2' (using password: YES)"
        )
        let error = try await connectError(answering: refusal)

        guard case MySQLError.connectionFailed(let message)? = error else {
            Issue.record("Expected a failed connect, got \(String(describing: error))")
            return
        }
        #expect(message == refusal.message)
    }

    private func connectError(answering refusal: FakeMySQLServer.LoginRefusal) async throws -> (any Error)? {
        let server = try FakeMySQLServer(identity: nil, refusesLogin: refusal)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = MySQLDriver(
            host: "127.0.0.1", port: server.port, user: "app", password: "app-password", database: "app_archive"
        )
        var thrown: (any Error)?
        do {
            try await driver.connect()
        } catch {
            thrown = error
        }
        _ = await session
        return thrown
    }
}
