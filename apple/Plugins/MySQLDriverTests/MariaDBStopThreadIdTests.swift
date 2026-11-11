//
//  MariaDBStopThreadIdTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// Stop runs off the statement queue, where a disconnect's queued close can free the handle under it, so the kill's
// thread id is the one the handshake gave, held beside the handle and cleared with it.
@Suite(.timeLimit(.minutes(1)))
struct MariaDBStopThreadIdTests {
    @Test("The kill's thread id is the session's own, and none is left once the session is closed")
    func threadIdFollowsTheSession() async throws {
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
        let signedIn = connection.currentThreadId
        connection.disconnect()
        let closed = connection.currentThreadId
        _ = await session

        // The fake server's handshake names connection 1.
        #expect(signedIn == 1)
        #expect(closed == 0)
    }
}
