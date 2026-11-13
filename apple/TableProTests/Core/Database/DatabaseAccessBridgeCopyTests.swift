//
//  DatabaseAccessBridgeCopyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite(.serialized)
@MainActor
struct DatabaseAccessBridgeCopyTests {
    @Test("An external caller's COPY FROM STDIN is refused before anything is sent, rows or not", arguments: [
        "COPY t FROM stdin;\n1\tone\n\\.\n",
        "COPY t FROM stdin;",
    ])
    func copyIsRefused(sql: String) async throws {
        let driver = ScriptAnsweringDriver(
            connection: TestFixtures.makeConnection(database: "app", type: .postgresql),
            sendsBatchesWhole: false
        )
        var session = ConnectionSession(connection: driver.connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: driver.connection.id)
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let scope = DatabaseScope(connectionId: driver.connection.id, database: "app", schema: nil)

        await #expect {
            _ = try await DatabaseAccessBridge().plannedScript(scope: scope, query: sql, maxRows: 10)
        } throws: { error in
            guard case .invalidArgument(let message) = error as? DatabaseAccessError else { return false }
            return message.contains("COPY FROM STDIN")
        }
        #expect(driver.sentStatements.isEmpty)
    }
}
