//
//  ConnectionFormClipboardTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionFormClipboardTests {
    private func formApplyingClipboard(_ text: String) throws -> ConnectionFormCoordinator {
        let candidate = try #require(ClipboardConnectionCandidate(clipboardText: text))
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.start()
        coordinator.applyClipboardCandidate(candidate)
        return coordinator
    }

    private func formImporting(_ url: String) throws -> ConnectionFormCoordinator {
        guard case .success(let parsed) = ConnectionURLParser.parse(url) else {
            throw ConnectionURLParseError.invalidURL
        }
        let coordinator = ConnectionFormCoordinator(connectionId: nil, initialParsedURL: parsed)
        coordinator.start()
        return coordinator
    }

    @Test("sslmode=verify-full on the clipboard opens the form on Verify Identity")
    func verifyFullKeepsIdentityVerification() throws {
        let coordinator = try formApplyingClipboard("postgresql://u@db.example.com/app?sslmode=verify-full")
        #expect(coordinator.ssl.mode == .verifyIdentity)
    }

    @Test("sslmode=verify-ca on the clipboard opens the form on Verify CA")
    func verifyCaKeepsCertificateVerification() throws {
        let coordinator = try formApplyingClipboard("postgresql://u@db.example.com/app?sslmode=verify-ca")
        #expect(coordinator.ssl.mode == .verifyCa)
    }

    @Test("sslmode=disable on the clipboard opens the form on Disabled")
    func disableTurnsTLSOff() throws {
        let coordinator = try formApplyingClipboard("postgresql://u@db.example.com/app?sslmode=disable")
        #expect(coordinator.ssl.mode == .disabled)
    }

    @Test(
        "The clipboard banner and Import from URL fill the same TLS mode",
        arguments: [
            "postgresql://u@db.example.com/app",
            "postgresql://u@db.example.com/app?sslmode=require",
            "postgresql://u@db.example.com/app?sslmode=verify-full",
            "mysql://root@db.example.com/app?ssl=true",
            "mysql://root@db.example.com/app?sslmode=verify-identity",
            "rediss://cache.example.com",
            "mongodb+srv://u:p@cluster0.example.net/test"
        ]
    )
    func clipboardMatchesImportFromURL(_ url: String) throws {
        let clipboard = try formApplyingClipboard(url)
        let imported = try formImporting(url)
        #expect(clipboard.network.type == imported.network.type)
        #expect(clipboard.network.port == imported.network.port)
        #expect(clipboard.ssl.mode == imported.ssl.mode)
    }

    @Test(
        "ssl=1 and ssl=require on the clipboard turn TLS on as ssl=true does",
        arguments: [
            "postgresql://u@db.example.com/app",
            "mysql://root@db.example.com/app",
            "redis://cache.example.com"
        ],
        ["1", "require"]
    )
    func sslFlagSpellingsTurnTLSOn(_ base: String, _ value: String) throws {
        let spelled = try formApplyingClipboard("\(base)?ssl=\(value)")
        let canonical = try formApplyingClipboard("\(base)?ssl=true")
        #expect(spelled.ssl.mode == canonical.ssl.mode)
        #expect(spelled.ssl.mode == .required)
    }

    @Test("Host, credentials and database from the clipboard reach the form")
    func connectionFieldsReachTheForm() throws {
        let coordinator = try formApplyingClipboard("postgres://alice:p%40ss@db.example.com:6000/sales")
        #expect(coordinator.network.type == .postgresql)
        #expect(coordinator.network.host == "db.example.com")
        #expect(coordinator.network.port == "6000")
        #expect(coordinator.network.database == "sales")
        #expect(coordinator.auth.username == "alice")
        #expect(coordinator.auth.password == "p@ss")
        #expect(coordinator.clipboardCandidate == nil)
    }

    @Test(
        "Clipboard text that names no server is not offered",
        arguments: [
            "just a sentence",
            "   ",
            "mysqlx://localhost:33060/test",
            "postgres://",
            "mysql:///dbonly"
        ]
    )
    func textWithoutAServerIsNotOffered(_ text: String) {
        #expect(ClipboardConnectionCandidate(clipboardText: text) == nil)
    }

    @Test("Only the first line of the clipboard is read, and its scheme is kept as typed")
    func firstLineIsTheCandidate() throws {
        let candidate = try #require(
            ClipboardConnectionCandidate(clipboardText: "  Postgres://alice@db.example.com/sales\nsecond line")
        )
        #expect(candidate.scheme == "postgres")
        #expect(candidate.parsed.host == "db.example.com")
        #expect(candidate.parsed.database == "sales")
    }

    @Test("The banner summary hides the password")
    func summaryMasksThePassword() throws {
        let candidate = try #require(
            ClipboardConnectionCandidate(clipboardText: "postgres://alice:secret@db.example.com/sales")
        )
        #expect(ClipboardConnectionBanner.summary(for: candidate) == "postgres://alice:***@db.example.com:5432/sales")
    }

    @Test(
        "The banner summary leaves out a port the engine does not use",
        arguments: [
            "libsql://my-db-org.turso.io",
            "d1://0123456789abcdef/analytics"
        ]
    )
    func summaryOmitsAnUnusedPort(_ url: String) throws {
        let candidate = try #require(ClipboardConnectionCandidate(clipboardText: url))
        #expect(ClipboardConnectionBanner.summary(for: candidate) == url)
    }

    @Test(
        "A socket URL opens the form on Socket with its path, from the clipboard or Import from URL",
        arguments: [
            "mysql://root@localhost/local?socket=%2Ftmp%2Fmysql.sock",
            "mariadb://root@/local?unix_socket=/tmp/mysql.sock"
        ]
    )
    func socketURLSelectsSocket(_ url: String) throws {
        for coordinator in [try formApplyingClipboard(url), try formImporting(url)] {
            #expect(coordinator.network.endpoint == .localSocket)
            #expect(coordinator.network.localSocketPath == "/tmp/mysql.sock")
            #expect(coordinator.transport == nil)
            #expect(coordinator.advanced.additionalFieldValues[MySQLLocalSocket.fieldKey] == nil)

            let edits = coordinator.buildEdits()
            #expect(edits.additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
            #expect(edits.applied(to: DatabaseConnection(name: "")).localSocketPath == "/tmp/mysql.sock")
        }
    }

    @Test("A socket URL pasted over an SSH form drops the tunnel")
    func socketURLClearsTheTransport() throws {
        let candidate = try #require(
            ClipboardConnectionCandidate(clipboardText: "mysql://root@localhost/local?socket=/tmp/mysql.sock")
        )
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.start()
        coordinator.transport = .ssh
        coordinator.ssh.state.host = "bastion.example.com"

        coordinator.applyClipboardCandidate(candidate)

        #expect(coordinator.network.endpoint == .localSocket)
        #expect(coordinator.transport == nil)
        #expect(coordinator.availableTransports == [nil])
    }

    @Test("A TCP URL pasted after a socket one goes back to Host and Port")
    func tcpURLLeavesSocket() throws {
        let socket = try #require(
            ClipboardConnectionCandidate(clipboardText: "mysql://root@localhost/local?socket=/tmp/mysql.sock")
        )
        let tcp = try #require(ClipboardConnectionCandidate(clipboardText: "mysql://root@db.example.com/shop"))
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.start()

        coordinator.applyClipboardCandidate(socket)
        coordinator.applyClipboardCandidate(tcp)

        #expect(coordinator.network.endpoint == .hostAndPort)
        #expect(coordinator.network.host == "db.example.com")
        #expect(coordinator.buildEdits().additionalFields[MySQLLocalSocket.fieldKey] == nil)
    }

    @Test("The banner summary names the socket and no port")
    func summaryShowsTheSocket() throws {
        let candidate = try #require(
            ClipboardConnectionCandidate(clipboardText: "mysql://root:pw@localhost/db?socket=/tmp/my.sock")
        )
        #expect(ClipboardConnectionBanner.summary(for: candidate) == "mysql://root:***@localhost/db?socket=/tmp/my.sock")
    }
}
