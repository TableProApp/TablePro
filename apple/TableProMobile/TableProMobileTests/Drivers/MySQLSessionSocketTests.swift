import Foundation
@testable import TableProMobile
import TableProTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MySQLSessionSocketTests {
    @Test("A session without a query timeout has no read timeout, and its keepalive fails a dead path in about 90 s")
    func deadPathFailsOnTheKeepalive() async throws {
        let server = try FakeMySQLServer(identity: nil)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = Self.driver(port: server.port, queryTimeoutSeconds: nil)
        try await driver.connect()

        let socket = try #require(SessionSocketProbe.clientSocket(connectedTo: server.port))
        let readTimeout = SessionSocketProbe.receiveTimeout(socket)
        let keepalive = SessionSocketProbe.keepalive(socket)
        try await driver.disconnect()
        _ = await session

        #expect(readTimeout == 0)
        #expect(keepalive == SessionSocketProbe.expected)
    }

    @Test("The setup statements keep the sign-in's 30 s bound, and the session takes its own after them")
    func setupKeepsTheSignInBound() async throws {
        let server = try FakeMySQLServer(identity: nil, holdsQueriesStarting: "SET SESSION max_execution_time")
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = Self.driver(port: server.port, queryTimeoutSeconds: 45)

        let connecting = Task { try await driver.connect() }
        try await waitUntil { server.heldQueries == 1 }
        let socket = try #require(SessionSocketProbe.clientSocket(connectedTo: server.port))
        let duringSetup = SessionSocketProbe.receiveTimeout(socket)
        server.release(1)
        try await connecting.value
        let afterSetup = SessionSocketProbe.receiveTimeout(socket)
        try await driver.disconnect()
        _ = await session

        #expect(duringSetup == 30)
        #expect(afterSetup == 75)
    }

    private static func driver(port: Int, queryTimeoutSeconds: Int?) -> MySQLDriver {
        MySQLDriver(
            host: "127.0.0.1", port: port, user: "app", password: "app-password", database: "",
            queryTimeoutSeconds: queryTimeoutSeconds
        )
    }
}
