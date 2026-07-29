//
//  ConnectionExportDataTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import Testing

@testable import TablePro

@Suite("Connection Export Data")
@MainActor
struct ConnectionExportDataTests {
    private func makeConnection(name: String = "Dev") -> DatabaseConnection {
        DatabaseConnection(
            name: name, host: "db.example.com", port: 5_432,
            database: "app", username: "admin", type: .postgresql
        )
    }

    @Test("exportData round-trips connections through decodeData")
    func testPlaintextRoundTrip() throws {
        let connections = [makeConnection(name: "Primary"), makeConnection(name: "Replica")]
        let data = try ConnectionExportService.exportData(connections)

        let envelope = try ConnectionImportDecoder.decodeData(data)
        #expect(envelope.connections.count == 2)
        #expect(envelope.connections.map(\.name) == ["Primary", "Replica"])
        #expect(envelope.credentials == nil)
    }

    @Test("exportEncryptedData decrypts with the right passphrase")
    func testEncryptedRoundTrip() throws {
        let connections = [makeConnection(name: "Secret")]
        let data = try ConnectionExportService.exportEncryptedData(connections, passphrase: "correct horse")

        #expect(ConnectionExportCrypto.isEncrypted(data))
        let envelope = try ConnectionImportDecoder.decodeEncryptedData(data, passphrase: "correct horse")
        #expect(envelope.connections.map(\.name) == ["Secret"])
    }

    @Test("exportEncryptedData fails to decrypt with the wrong passphrase")
    func testEncryptedWrongPassphrase() throws {
        let data = try ConnectionExportService.exportEncryptedData([makeConnection()], passphrase: "right-one")

        #expect(throws: (any Error).self) {
            try ConnectionImportDecoder.decodeEncryptedData(data, passphrase: "wrong-one")
        }
    }
}

@Suite("Connection Export Passphrase State")
struct ConnectionExportPassphraseStateTests {
    @Test("empty passphrase is not exportable")
    func testEmpty() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "", confirmation: "")
        #expect(state == .empty)
        #expect(!state.allowsExport)
    }

    @Test("passphrase under the minimum length is too short")
    func testTooShort() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "1234567", confirmation: "1234567")
        #expect(state == .tooShort)
        #expect(!state.allowsExport)
    }

    @Test("valid passphrase with empty confirmation is incomplete")
    func testIncomplete() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "longenough", confirmation: "")
        #expect(state == .incomplete)
        #expect(!state.allowsExport)
    }

    @Test("non-matching confirmation is a mismatch")
    func testMismatch() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "longenough", confirmation: "different1")
        #expect(state == .mismatch)
        #expect(!state.allowsExport)
    }

    @Test("matching passphrase at the minimum length is exportable")
    func testOk() {
        let state = ConnectionExportPassphraseState.evaluate(passphrase: "12345678", confirmation: "12345678")
        #expect(state == .ok)
        #expect(state.allowsExport)
    }
}
