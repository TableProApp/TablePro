import CMariaDB
import Foundation
import TableProPluginKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MySQLFoundRowsTests {
    // A save holds a keyed UPDATE to the one row it matched, which only reads right when the server counts a row
    // that already held the value: scripts/probes/check-mysql-found-rows.sh measures that against real servers.
    @Test("A session signs in asking for CLIENT_FOUND_ROWS, so an UPDATE counts the rows it matched")
    func signInAsksForFoundRows() async throws {
        let server = try PlaintextMySQLServer(asksForCleartext: false)
        defer { server.close() }
        async let session = server.serveOneSession()
        let connection = MariaDBPluginConnection(
            transport: .tcp(host: "127.0.0.1", port: UInt32(server.port)),
            user: "app",
            password: "app-password",
            database: "",
            sslConfig: SSLConfiguration(mode: .disabled),
            enableCleartextPlugin: false
        )

        try await connection.connect()
        connection.disconnect()
        let received = await session.received

        // The first packet is the sign-in: a 4-byte header, then the client's capability flags, little-endian.
        try #require(received.count >= 8)
        let flags = received[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        #expect(flags & UInt32(CLIENT_FOUND_ROWS) != 0)
    }
}
