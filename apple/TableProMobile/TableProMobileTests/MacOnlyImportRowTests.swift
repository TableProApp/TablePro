import Foundation
import TableProImport
import TableProModels
import Testing

@testable import TableProMobile

@MainActor
struct MacOnlyImportRowTests {
    private func analyzed(type: String) throws -> ImportPreview {
        let settings = ExportableConnection(
            name: "Search",
            host: "db.example.com",
            port: 9_200,
            database: "",
            username: "app",
            type: type
        )
        let bundle = try ConnectionBundle(appVersion: "Tests", connections: [BundleConnection(ref: "c1", settings: settings)])
        return ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: bundle, source: .file(name: "Tests.tablepro")),
            library: ImportLibrarySnapshot(),
            environment: IOSConnectionImportService.environment()
        )
    }

    private func isPreselected(_ row: ConnectionRow, in preview: ImportPreview) -> Bool {
        ImportSelection.defaults(for: preview).resolution(for: row.ref) != nil
    }

    @Test("A Mac plugin type is recognized, preselected and marked Mac only", arguments: ["Elasticsearch", "SAP HANA", "Typesense", "PGlite"])
    func macPluginTypeIsMarked(_ typeId: String) throws {
        let preview = try analyzed(type: typeId)
        let row = try #require(preview.connections.first)

        #expect(row.unsupportedTypeId == nil)
        #expect(row.settings.type == typeId)
        #expect(isPreselected(row, in: preview))
        #expect(MacOnlyConnection.importStatus(typeId: row.settings.type) == MacOnlyConnection.status)
    }

    @Test("A MongoDB row stays preselected and reads the Mac only status")
    func mongoDBRowIsMarked() throws {
        let preview = try analyzed(type: DatabaseType.mongodb.rawValue)
        let row = try #require(preview.connections.first)

        #expect(row.unsupportedTypeId == nil)
        #expect(isPreselected(row, in: preview))
        #expect(MacOnlyConnection.importStatus(typeId: row.settings.type) == MacOnlyConnection.status)
    }

    @Test("A type this device opens reads no Mac only status")
    func supportedTypeIsNotMarked() throws {
        let preview = try analyzed(type: DatabaseType.postgresql.rawValue)
        let row = try #require(preview.connections.first)

        #expect(isPreselected(row, in: preview))
        #expect(MacOnlyConnection.importStatus(typeId: row.settings.type) == nil)
    }

    @Test("A type no TablePro knows stays unsupported and unselected")
    func unknownTypeStaysUnsupported() throws {
        let preview = try analyzed(type: "Vertica")
        let row = try #require(preview.connections.first)

        #expect(row.unsupportedTypeId == "Vertica")
        #expect(!isPreselected(row, in: preview))
    }
}
