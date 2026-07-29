//
//  NavicatImporterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing
import UniformTypeIdentifiers

@Suite("NavicatImporter", .serialized)
struct NavicatImporterTests {
    private var tempDir: URL
    private var importer: NavicatImporter

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavicatImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var imp = NavicatImporter()
        imp.ncxFileURL = tempDir.appendingPathComponent("connections.ncx")
        importer = imp
    }

    // MARK: - Fixture Helpers

    private func writeNCX(_ connections: [String]) throws {
        guard let url = importer.ncxFileURL else { return }
        let body = connections.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Connections Ver="1.1">
        \(body)
        </Connections>
        """
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    private func conn(
        name: String = "Test",
        type: String = "MYSQL",
        host: String = "db.example.com",
        port: String = "3306",
        user: String = "admin",
        database: String = "mydb",
        savePassword: String = "false",
        password: String = "",
        extra: [String: String] = [:]
    ) -> String {
        var attributes: [String: String] = [
            "ConnectionName": name,
            "ConnType": type,
            "Host": host,
            "Port": port,
            "UserName": user,
            "Database": database,
            "SavePassword": savePassword,
            "Password": password
        ]
        attributes.merge(extra) { _, new in new }
        let rendered = attributes
            .map { "\($0.key)=\"\(xmlEscape($0.value))\"" }
            .joined(separator: " ")
        return "<Connection \(rendered)/>"
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Availability

    @Test("isAvailable is true through the protocol existential without an installed app")
    func isAvailableThroughExistential() {
        let importer: any ForeignAppImporter = NavicatImporter()
        #expect(importer.isAvailable() == true)
    }

    @Test("Declares a file type that a real .ncx file matches")
    func ncxFileMatchesImportFileTypes() throws {
        let url = tempDir.appendingPathComponent("sample.ncx")
        try "<Connections Ver=\"1.1\"/>".write(to: url, atomically: true, encoding: .utf8)
        let resolved = try #require(url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        let types = try #require(NavicatImporter().importFileTypes)
        #expect(types.contains { resolved.conforms(to: $0) })
    }

    @Test("readsPasswordsFromKeychain is false")
    func readsPasswordsFromKeychainIsFalse() {
        #expect(NavicatImporter().readsPasswordsFromKeychain == false)
    }

    // MARK: - connectionCount

    @Test("connectionCount is 0 without a file")
    func connectionCountZeroWithoutFile() {
        #expect(NavicatImporter().connectionCount() == 0)
    }

    @Test("connectionCount reflects the file contents")
    func connectionCountReflectsFile() throws {
        try writeNCX([conn(name: "A"), conn(name: "B")])
        #expect(importer.connectionCount() == 2)
    }

    // MARK: - Errors

    @Test("Importing without a file throws")
    func importWithoutFileThrows() {
        let bare = NavicatImporter()
        #expect(throws: ForeignAppImportError.self) {
            _ = try bare.importConnections(includePasswords: true)
        }
    }

    @Test("Malformed XML throws a parse error")
    func malformedXMLThrows() throws {
        guard let url = importer.ncxFileURL else { return }
        try "<<<not xml".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ForeignAppImportError.self) {
            _ = try importer.importConnections(includePasswords: true)
        }
    }

    @Test("A file with no connections throws")
    func noConnectionsThrows() throws {
        try writeNCX([])
        #expect(throws: ForeignAppImportError.self) {
            _ = try importer.importConnections(includePasswords: true)
        }
    }

    // MARK: - Mapping

    @Test("Maps every known ConnType")
    func mapsKnownConnTypes() throws {
        try writeNCX([
            conn(type: "MYSQL"), conn(type: "MARIADB"), conn(type: "POSTGRESQL"),
            conn(type: "ORACLE"), conn(type: "SQLITE"), conn(type: "SQLSERVER"), conn(type: "MONGODB")
        ])
        let types = try importer.importConnections(includePasswords: false).envelope.connections.map(\.type)
        #expect(types == ["MySQL", "MariaDB", "PostgreSQL", "Oracle", "SQLite", "SQL Server", "MongoDB"])
    }

    @Test("Passes an unknown ConnType through unchanged")
    func passesUnknownConnTypeThrough() throws {
        try writeNCX([conn(type: "COCKROACHDB")])
        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.type == "COCKROACHDB")
    }

    @Test("Falls back to the default port when Port is absent")
    func usesDefaultPortWhenPortMissing() throws {
        try writeNCX([conn(type: "POSTGRESQL", port: "")])
        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.port == 5_432)
    }

    @Test("Maps SQLite to its file path")
    func mapsSQLiteByFilePath() throws {
        try writeNCX([conn(
            type: "SQLITE", host: "", port: "", user: "", database: "",
            extra: ["DatabaseFileName": "/Users/me/data.db"]
        )])
        let connection = try importer.importConnections(includePasswords: false).envelope.connections[0]
        #expect(connection.type == "SQLite")
        #expect(connection.database == "/Users/me/data.db")
        #expect(connection.host == "")
        #expect(connection.port == 0)
        #expect(connection.username == "")
    }

    @Test("Maps an SSH tunnel")
    func mapsSSHTunnel() throws {
        try writeNCX([conn(extra: [
            "SSH": "true",
            "SSH_Host": "bastion.example.com",
            "SSH_Port": "2222",
            "SSH_UserName": "deploy",
            "SSH_AuthenMethod": "PASSWORD"
        ])])
        let ssh = try importer.importConnections(includePasswords: false).envelope.connections[0].sshConfig
        #expect(ssh?.host == "bastion.example.com")
        #expect(ssh?.port == 2_222)
        #expect(ssh?.username == "deploy")
        #expect(ssh?.authMethod == "Password")
    }

    @Test("Maps SSL verify mode and CA path")
    func mapsSSLConfig() throws {
        try writeNCX([conn(extra: [
            "SSL": "true",
            "SSL_PGSSLMode": "VERIFY-CA",
            "SSL_CACert": "/certs/ca.pem"
        ])])
        let ssl = try importer.importConnections(includePasswords: false).envelope.connections[0].sslConfig
        #expect(ssl?.mode == "Verify CA")
        #expect(ssl?.caCertificatePath == "/certs/ca.pem")
    }

    // MARK: - Passwords

    @Test("Decrypts the database and SSH passwords")
    func decryptsPasswords() throws {
        try writeNCX([conn(
            savePassword: "true",
            password: "B75D320B6211468D63EB3B67C9E85933",
            extra: [
                "SSH": "true",
                "SSH_Host": "bastion.example.com",
                "SSH_AuthenMethod": "PASSWORD",
                "SSH_SavePassword": "true",
                "SSH_Password": "B75D320B6211468D63EB3B67C9E85933"
            ]
        )])
        let credentials = try importer.importConnections(includePasswords: true).envelope.credentials
        #expect(credentials?["0"]?.password == "This is a test")
        #expect(credentials?["0"]?.sshPassword == "This is a test")
    }

    @Test("Maps credentials to the right index when some connections have no saved password")
    func mapsSparseCredentialsByIndex() throws {
        try writeNCX([
            conn(name: "Zero", type: "MYSQL", savePassword: "true", password: "B75D320B6211468D63EB3B67C9E85933"),
            conn(name: "One", type: "POSTGRESQL", savePassword: "false"),
            conn(name: "Two", type: "MARIADB", savePassword: "true", password: "2E6C8CF471EB0268D3239A0AD531F1B1")
        ])
        let result = try importer.importConnections(includePasswords: true)
        let credentials = result.envelope.credentials
        #expect(result.envelope.connections.count == 3)
        #expect(Set(credentials?.keys.map { $0 } ?? []) == Set(["0", "2"]))
        #expect(credentials?["0"]?.password == "This is a test")
        #expect(credentials?["1"] == nil)
        #expect(credentials?["2"]?.password == "Sup3rSecret!Pass")
    }

    @Test("Skips the password when SavePassword is false")
    func skipsPasswordWhenNotSaved() throws {
        try writeNCX([conn(savePassword: "false", password: "B75D320B6211468D63EB3B67C9E85933")])
        let result = try importer.importConnections(includePasswords: true)
        #expect(result.envelope.connections.count == 1)
        #expect(result.envelope.credentials == nil)
    }

    @Test("Skips passwords entirely when includePasswords is false")
    func skipsPasswordsWhenExcluded() throws {
        try writeNCX([conn(savePassword: "true", password: "B75D320B6211468D63EB3B67C9E85933")])
        let result = try importer.importConnections(includePasswords: false)
        #expect(result.envelope.credentials == nil)
    }

    // MARK: - Envelope

    @Test("Stamps the envelope and source metadata")
    func stampsEnvelopeMetadata() throws {
        try writeNCX([conn()])
        let result = try importer.importConnections(includePasswords: true)
        #expect(result.envelope.formatVersion == 1)
        #expect(result.envelope.appVersion == "Navicat Import")
        #expect(result.sourceName == "Navicat")
    }
}
