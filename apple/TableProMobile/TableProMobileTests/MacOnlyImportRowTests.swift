import Foundation
import TableProImport
import TableProModels
import Testing

@testable import TableProMobile

@MainActor
struct MacOnlyImportRowTests {
    private let fixture: AppStateFixture
    private let appState: AppState

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false)
    }

    private func analyzed(type: String) throws -> ImportPreview {
        try analyzed(ExportableConnection(
            name: "Search",
            host: "db.example.com",
            port: 9_200,
            database: "",
            username: "app",
            type: type
        ))
    }

    private func analyzed(_ settings: ExportableConnection) throws -> ImportPreview {
        let bundle = try ConnectionBundle(appVersion: "Tests", connections: [BundleConnection(ref: "c1", settings: settings)])
        return ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: bundle, source: .file(name: "Tests.tablepro")),
            library: ImportLibrarySnapshot(),
            environment: IOSConnectionImportService.environment(for: appState)
        )
    }

    private func isPreselected(_ row: ConnectionRow, in preview: ImportPreview) -> Bool {
        ImportSelection.defaults(for: preview).resolution(for: row.ref) != nil
    }

    @Test("A Mac plugin type is recognized, preselected and marked Mac only", arguments: [
        "Elasticsearch", "SAP HANA", "Typesense", "PGlite", "Presto", "KingbaseES",
    ])
    func macPluginTypeIsMarked(_ typeId: String) throws {
        let preview = try analyzed(type: typeId)
        let row = try #require(preview.connections.first)

        #expect(row.unsupportedTypeId == nil)
        #expect(row.settings.type == typeId)
        #expect(isPreselected(row, in: preview))
        #expect(MacOnlyConnection.importStatus(for: row.settings) == MacOnlyConnection.status)
    }

    @Test("A Cassandra row stays preselected and reads the Mac only status")
    func cassandraRowIsMarked() throws {
        let preview = try analyzed(type: DatabaseType.cassandra.rawValue)
        let row = try #require(preview.connections.first)

        #expect(row.unsupportedTypeId == nil)
        #expect(isPreselected(row, in: preview))
        #expect(MacOnlyConnection.importStatus(for: row.settings) == MacOnlyConnection.status)
    }

    @Test("A type this device opens reads no Mac only status")
    func supportedTypeIsNotMarked() throws {
        let preview = try analyzed(type: DatabaseType.postgresql.rawValue)
        let row = try #require(preview.connections.first)

        #expect(isPreselected(row, in: preview))
        #expect(MacOnlyConnection.importStatus(for: row.settings) == nil)
    }

    @Test("A MySQL row that dials a Mac socket reads the Mac only status")
    func socketRowIsMarked() throws {
        var settings = ExportableConnection(name: "Local", host: "localhost", port: 3_306, database: "app", username: "root", type: "MySQL")
        settings.additionalFields = ["localSocketPath": "/tmp/mysql.sock"]
        let row = try #require(try analyzed(settings).connections.first)

        #expect(MacOnlyConnection.importStatus(for: row.settings) == MacOnlyConnection.status)
    }

    @Test("A socket row behind an SSH tunnel dials TCP and reads no Mac only status")
    func tunnelledSocketRowIsNotMarked() throws {
        var settings = ExportableConnection(name: "Local", host: "localhost", port: 3_306, database: "app", username: "root", type: "MySQL")
        settings.additionalFields = ["localSocketPath": "/tmp/mysql.sock"]
        settings.sshConfig = ExportableSSHConfig(
            enabled: true,
            host: "bastion.example.com",
            port: nil,
            username: "deploy",
            authMethod: "Private Key",
            privateKeyPath: "",
            agentSocketPath: "",
            jumpHosts: nil,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
        let row = try #require(try analyzed(settings).connections.first)

        #expect(MacOnlyConnection.importStatus(for: row.settings) == nil)
    }

    @Test("A type no TablePro knows stays unsupported and unselected")
    func unknownTypeStaysUnsupported() throws {
        let preview = try analyzed(type: "Vertica")
        let row = try #require(preview.connections.first)

        #expect(row.unsupportedTypeId == "Vertica")
        #expect(!isPreselected(row, in: preview))
    }
}
