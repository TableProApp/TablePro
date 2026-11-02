//
//  WelcomeViewModelLinkedConnectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

@MainActor
struct WelcomeViewModelLinkedConnectionTests {
    @Test("A linked folder connection asks for the password its file cannot carry")
    func linkedFolderConnectionPromptsForPassword() throws {
        let linked = try linkedFromFile(exportable(type: .postgresql, port: 5_432))

        let connection = linked.databaseConnection()

        #expect(ConnectionCredentialResolver.promptsForPassword(connection))
    }

    @Test("A Team Library connection asks for the password the library does not hold")
    func teamLibraryConnectionPromptsForPassword() {
        let payload = exportable(type: .mysql, port: 3_306).sanitizedForImport()
        let linked = LinkedConnection(
            id: UUID(),
            connection: payload,
            folderId: UUID(),
            sourceFileURL: URL(fileURLWithPath: "/")
        )

        let connection = linked.databaseConnection()

        #expect(ConnectionCredentialResolver.promptsForPassword(connection))
    }

    @Test("A file-based linked connection has no password to ask for")
    func fileBasedLinkedConnectionDoesNotPrompt() throws {
        let linked = try linkedFromFile(
            exportable(type: .sqlite, port: 0, database: "/tmp/shared.sqlite", username: "")
        )

        let connection = linked.databaseConnection()

        #expect(!ConnectionCredentialResolver.promptsForPassword(connection))
    }

    @Test("A linked connection whose sign-in hides the password does not ask for one")
    func linkedConnectionWithHiddenPasswordDoesNotPrompt() throws {
        let linked = try linkedFromFile(
            exportable(type: .mssql, port: 1_433, additionalFields: ["mssqlAuthMethod": "windows"])
        )

        let connection = linked.databaseConnection()

        #expect(!ConnectionCredentialResolver.promptsForPassword(connection))
    }

    @Test("A linked folder row keeps Windows sign-in for the consent prompt; the same file imported drops it")
    func linkedRowKeepsTheSelectorAndImportDropsIt() throws {
        let data = try fileData(
            exportable(type: .mssql, port: 1_433, additionalFields: ["mssqlAuthMethod": "windows", "mssqlSchema": "sales"])
        )

        let linked = try #require(
            try LinkedFolderWatcher.linkedConnections(
                in: data,
                folderId: UUID(),
                sourceFileURL: URL(fileURLWithPath: "/tmp/shared.tablepro")
            ).first
        )
        let imported = try #require(try ConnectionBundleCodec.decode(data).connections.first).settings

        #expect(linked.connection.additionalFields == ["mssqlAuthMethod": "windows", "mssqlSchema": "sales"])
        #expect(linked.databaseConnection().origin == .linkedFolder)
        #expect(imported.additionalFields == ["mssqlSchema": "sales"])
    }

    private func fileData(_ exportable: ExportableConnection) throws -> Data {
        let bundle = try ConnectionBundle(
            appVersion: "1.0",
            connections: [BundleConnection(ref: "c1", settings: exportable)]
        )
        return try ConnectionBundleCodec.encode(bundle)
    }

    private func linkedFromFile(_ exportable: ExportableConnection) throws -> LinkedConnection {
        try #require(
            try LinkedFolderWatcher.linkedConnections(
                in: fileData(exportable),
                folderId: UUID(),
                sourceFileURL: URL(fileURLWithPath: "/tmp/shared.tablepro")
            ).first
        )
    }

    private func exportable(
        type: DatabaseType,
        port: Int,
        database: String = "app",
        username: String = "reader",
        additionalFields: [String: String]? = nil
    ) -> ExportableConnection {
        ExportableConnection(
            name: "Shared \(type.rawValue)",
            host: "db.example.com",
            port: port,
            database: database,
            username: username,
            type: type.rawValue,
            additionalFields: additionalFields
        )
    }
}
