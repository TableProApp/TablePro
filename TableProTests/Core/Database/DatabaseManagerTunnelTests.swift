//
//  DatabaseManagerTunnelTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("DatabaseManager tunnel rewrite")
@MainActor
struct DatabaseManagerTunnelTests {
    @Test("Tunneled connection rewrites the endpoint and keeps the password source")
    func tunnelPreservesPasswordSource() {
        var connection = DatabaseConnection(
            name: "tunneled",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.passwordSource = .env(variable: "DB_PASS")

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 61_234)

        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 61_234)
        #expect(tunneled.passwordSource == .env(variable: "DB_PASS"))
    }
}
