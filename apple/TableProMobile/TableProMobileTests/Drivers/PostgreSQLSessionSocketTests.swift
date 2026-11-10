import Foundation
@testable import TableProMobile
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PostgreSQLSessionSocketTests {
    // libpq here drops keepalives_idle without a word, so only the socket shows whether the idle time took.
    @Test("A PostgreSQL session's socket fails a dead path in about 90 s, idle time included")
    func keepaliveIsOnTheSocket() async throws {
        let server = try FakePostgreSQLServer()
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = PostgreSQLDriver(
            host: "127.0.0.1", port: server.port, user: "app", password: "app-password", database: "app"
        )
        try await driver.connect()

        let socket = try #require(SessionSocketProbe.clientSocket(connectedTo: server.port))
        let keepalive = SessionSocketProbe.keepalive(socket)
        try await driver.disconnect()
        let served = await session

        #expect(served.startedUp)
        #expect(keepalive == SessionSocketProbe.expected)
    }
}
