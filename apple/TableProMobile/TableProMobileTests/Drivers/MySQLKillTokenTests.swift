import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProTestSupport
import Testing

// The factory gets the session's refresh from ConnectionManager, which resolves it for the connection as saved, so a
// session behind a tunnel mints for the real endpoint too. Against the TLS fake, which records each cleartext sign-in.
// Each session is aged past the ten minutes its own token serves kills for.
@Suite(.timeLimit(.minutes(1)))
struct MySQLKillTokenTests {
    private static let held = "UPDATE orders SET archived = 1 WHERE placed_at < '2020-01-01'"

    @Test("An IAM session's kill signs in with the token the manager's refresh mints")
    func iamKillUsesTheRefresh() async throws {
        let served = try await killSessions(
            fields: [IAMSignIn.Field.method: IAMSignIn.awsAccessKey.pickerValue],
            preTunnelHost: nil
        )

        #expect(served[0].cleartextPassword == "connect-token")
        #expect(served[1].cleartextPassword == "kill-token")
        #expect(served[1].queries == ["KILL QUERY 1"])
    }

    @Test("Behind a tunnel the kill still signs in with the refreshed token")
    func tunneledKillUsesTheRefresh() async throws {
        let served = try await killSessions(
            fields: [IAMSignIn.Field.method: IAMSignIn.awsAccessKey.pickerValue],
            preTunnelHost: "mydb.abc123.us-east-1.rds.amazonaws.com"
        )

        #expect(served[1].cleartextPassword == "kill-token")
    }

    @Test("A password session's kill signs in with its password, without calling the refresh")
    func passwordKillKeepsThePassword() async throws {
        let served = try await killSessions(fields: [:], preTunnelHost: nil)

        #expect(served[1].cleartextPassword == "connect-token")
        #expect(served[1].queries == ["KILL QUERY 1"])
    }

    private func killSessions(fields: [String: String], preTunnelHost: String?) async throws -> [FakeMySQLServer.Session] {
        let server = try FakeMySQLServer(identity: .localhost, asksForCleartext: true, holdsQueriesStarting: Self.held)
        defer { server.close() }
        async let sessions = server.serveConcurrently(sessions: 2)
        let connection = DatabaseConnection(
            type: .mysql,
            host: "127.0.0.1",
            port: server.port,
            username: "iam_user",
            additionalFields: fields,
            sslEnabled: true
        )
        let clock = ManualClock()
        let created = try IOSDriverFactory(clock: clock).createDriver(
            for: connection,
            password: "connect-token",
            preTunnelHost: preTunnelHost,
            refreshPassword: { "kill-token" }
        )
        let driver = try #require(created as? MySQLDriver)
        try await driver.connect()
        clock.advance(by: MySQLKillSignIn.reuseWindow)

        let reader = Task {
            for try await _ in driver.executeStreaming(query: Self.held, options: StreamOptions(maxRows: 100)) {}
        }
        try await waitUntil { server.heldQueries == 1 }
        reader.cancel()

        _ = try await driver.execute(query: "SELECT 2")
        try await driver.disconnect()
        return await sessions
    }
}
