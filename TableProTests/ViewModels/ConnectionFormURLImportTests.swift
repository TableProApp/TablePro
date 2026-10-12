//
//  ConnectionFormURLImportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionFormURLImportTests {
    private func formImporting(_ url: String) throws -> ConnectionFormCoordinator {
        guard case .success(let parsed) = ConnectionURLParser.parse(url) else {
            throw ConnectionURLParseError.invalidURL
        }
        let coordinator = ConnectionFormCoordinator(connectionId: nil, initialParsedURL: parsed)
        coordinator.start()
        return coordinator
    }

    @Test("sslmode=verify-full opens the form on Verify Identity")
    func verifyFullKeepsIdentityVerification() throws {
        let coordinator = try formImporting("postgresql://u@db.example.com/app?sslmode=verify-full")
        #expect(coordinator.ssl.mode == .verifyIdentity)
    }

    @Test("sslmode=verify-ca opens the form on Verify CA")
    func verifyCaKeepsCertificateVerification() throws {
        let coordinator = try formImporting("postgresql://u@db.example.com/app?sslmode=verify-ca")
        #expect(coordinator.ssl.mode == .verifyCa)
    }

    @Test("sslmode=disable opens the form on Disabled")
    func disableTurnsTLSOff() throws {
        let coordinator = try formImporting("postgresql://u@db.example.com/app?sslmode=disable")
        #expect(coordinator.ssl.mode == .disabled)
    }

    @Test(
        "ssl=1 and ssl=require turn TLS on as ssl=true does",
        arguments: [
            "postgresql://u@db.example.com/app",
            "mysql://root@db.example.com/app",
            "redis://cache.example.com"
        ],
        ["1", "require"]
    )
    func sslFlagSpellingsTurnTLSOn(_ base: String, _ value: String) throws {
        let spelled = try formImporting("\(base)?ssl=\(value)")
        let canonical = try formImporting("\(base)?ssl=true")
        #expect(spelled.ssl.mode == canonical.ssl.mode)
        #expect(spelled.ssl.mode == .required)
    }

    @Test("Host, credentials and database from the URL reach the form")
    func connectionFieldsReachTheForm() throws {
        let coordinator = try formImporting("postgres://alice:p%40ss@db.example.com:6000/sales")
        #expect(coordinator.network.type == .postgresql)
        #expect(coordinator.network.host == "db.example.com")
        #expect(coordinator.network.port == "6000")
        #expect(coordinator.network.database == "sales")
        #expect(coordinator.auth.username == "alice")
        #expect(coordinator.auth.password == "p@ss")
    }

    @Test(
        "A socket URL opens the form on Socket with its path",
        arguments: [
            "mysql://root@localhost/local?socket=%2Ftmp%2Fmysql.sock",
            "mariadb://root@/local?unix_socket=/tmp/mysql.sock"
        ]
    )
    func socketURLSelectsSocket(_ url: String) throws {
        let coordinator = try formImporting(url)
        #expect(coordinator.network.endpoint == .localSocket)
        #expect(coordinator.network.localSocketPath == "/tmp/mysql.sock")
        #expect(coordinator.transport == nil)
        #expect(coordinator.advanced.additionalFieldValues[MySQLLocalSocket.fieldKey] == nil)

        let edits = coordinator.buildEdits()
        #expect(edits.additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
        #expect(edits.applied(to: DatabaseConnection(name: "")).localSocketPath == "/tmp/mysql.sock")
    }
}
