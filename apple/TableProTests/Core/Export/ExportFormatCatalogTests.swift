import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// The catalog only reads a plugin's statics, so these stand in for the real formats without
/// pulling in a bundle. Plugins never load under XCTest, so the real ones are not available.
private protocol StubExportFormat: ExportFormatPlugin {}

private extension StubExportFormat {
    static var defaultFileExtension: String { formatId }
    static var iconName: String { "doc" }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        ExportFormatResult()
    }
}

private final class StubCSV: StubExportFormat, @unchecked Sendable {
    static let pluginName = "CSV"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to CSV format"
    static let formatId = "csv"
    static let formatDisplayName = "CSV"
    init() {}
}

private final class StubSQL: StubExportFormat, @unchecked Sendable {
    static let pluginName = "SQL"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to SQL format"
    static let formatId = "sql"
    static let formatDisplayName = "SQL"
    init() {}
}

private final class StubParquet: StubExportFormat, @unchecked Sendable {
    static let pluginName = "Parquet"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to Apache Parquet"
    static let formatId = "parquet"
    static let formatDisplayName = "Parquet"
    init() {}
}

private final class StubZebra: StubExportFormat, @unchecked Sendable {
    static let pluginName = "Zebra"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Writes zebra files"
    static let formatId = "zebra"
    static let formatDisplayName = "Zebra"
    init() {}
}

private final class StubAardvark: StubExportFormat, @unchecked Sendable {
    static let pluginName = "Aardvark"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Writes aardvark files"
    static let formatId = "aardvark"
    static let formatDisplayName = "Aardvark"
    init() {}
}

private final class StubDictionary: StubExportFormat, @unchecked Sendable {
    static let pluginName = "Dictionary"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Describes tables"
    static let formatId = "datadict"
    static let formatDisplayName = "Data Dictionary"
    init() {}

    func readsRows(optionValues: [Bool], kind: PluginExportObjectKind) -> Bool { false }
}

struct ExportFormatCatalogTests {
    private func ids(_ plugins: [any ExportFormatPlugin]) -> [String] {
        plugins.map { type(of: $0).formatId }
    }

    /// Parquet shipped in neither the order nor the description table, so it tied with every other
    /// unknown format at the end of the list and showed no description at all.
    @Test("Parquet is ordered and described like the formats that shipped before it")
    func parquetIsCurated() {
        let sorted = ExportFormatCatalog.sorted([StubParquet(), StubCSV(), StubSQL()])
        #expect(ids(sorted) == ["csv", "sql", "parquet"])

        let description = ExportFormatCatalog.description(for: StubParquet())
        #expect(!description.isEmpty)
        #expect(description != StubParquet.pluginDescription)
    }

    /// A registry format installed after this app was built is not in the curated list. It has to
    /// land somewhere stable rather than tying with every other unknown one.
    @Test("An unknown format sorts after the curated ones, by display name")
    func unknownFormatsSortLast() {
        let sorted = ExportFormatCatalog.sorted([StubZebra(), StubAardvark(), StubSQL()])
        #expect(ids(sorted) == ["sql", "aardvark", "zebra"])
    }

    @Test("An unknown format describes itself from the plugin")
    func unknownFormatDescribesItself() {
        #expect(ExportFormatCatalog.description(for: StubZebra()) == "Writes zebra files")
    }

    @Test("A curated format is described by the catalog, not by the plugin")
    func curatedFormatUsesTheCatalog() {
        #expect(ExportFormatCatalog.description(for: StubCSV()) != StubCSV.pluginDescription)
        #expect(ExportFormatCatalog.description(for: StubCSV()).contains("Excel"))
    }

    @Test("Sorting does not depend on the order it is handed")
    func sortIsOrderIndependent() {
        let forwards = ids(
            ExportFormatCatalog.sorted([StubCSV(), StubSQL(), StubParquet(), StubZebra()]))
        let backwards = ids(
            ExportFormatCatalog.sorted([StubZebra(), StubParquet(), StubSQL(), StubCSV()]))
        #expect(forwards == backwards)
        #expect(forwards == ["csv", "sql", "parquet", "zebra"])
    }

    @Test("A format that writes structure alone is offered for database objects with declared columns")
    func structureOnlyFormatNeedsDeclaredObjects() {
        let plugins: [any ExportFormatPlugin] = [StubCSV(), StubDictionary()]
        let objects = ExportFormatCatalog.available(
            plugins, forDatabaseTypeId: "PostgreSQL", listsDatabaseObjects: true, columnsAreSampled: false)
        let oneResult = ExportFormatCatalog.available(
            plugins, forDatabaseTypeId: "PostgreSQL", listsDatabaseObjects: false, columnsAreSampled: false)
        let sampled = ExportFormatCatalog.available(
            plugins, forDatabaseTypeId: "MongoDB", listsDatabaseObjects: true, columnsAreSampled: true)

        #expect(ids(objects) == ["csv", "datadict"])
        #expect(ids(oneResult) == ["csv"])
        #expect(ids(sampled) == ["csv"])
        #expect(ExportFormatCatalog.writesStructureOnly(StubDictionary()))
        #expect(!ExportFormatCatalog.writesStructureOnly(StubCSV()))
        #expect(ExportFormatCatalog.description(for: StubDictionary()) != StubDictionary.pluginDescription)
    }

    private func manifest(_ plugins: [RegistryPlugin]) -> RegistryManifest {
        RegistryManifest(schemaVersion: RegistryManifest.supportedSchemaVersion, plugins: plugins)
    }

    private func registryPlugin(id: String, name: String, exportFormatIds: [String]) -> RegistryPlugin {
        RegistryPlugin(
            id: id,
            name: name,
            databaseTypeIds: [],
            exportFormatIds: exportFormatIds,
            releases: []
        )
    }

    @Test("No manifest, or one that lists no export format, offers no install")
    func noManifestOffersNoInstall() {
        let unlisted = manifest([
            registryPlugin(id: "com.TablePro.OracleDriver", name: "Oracle Driver", exportFormatIds: [])
        ])

        #expect(ExportFormatCatalog.installable(in: nil).isEmpty)
        #expect(ExportFormatCatalog.installable(in: unlisted).isEmpty)
        #expect(ExportFormatCatalog.notInstalled(installedFormatIds: [], manifest: nil).isEmpty)
    }

    @Test("A manifest entry's exportFormatIds decode into an install offer")
    func decodedManifestOffersItsFormats() throws {
        let json = """
        {"schemaVersion": 3, "retainFromPluginKit": 39, "plugins": [{
            "id": "com.TablePro.ParquetExportPlugin", "name": "Parquet Export",
            "databaseTypeIds": [], "exportFormatIds": ["parquet"], "releases": []
        }]}
        """
        let decoded = try JSONDecoder().decode(RegistryManifest.self, from: Data(json.utf8))
        let parquet = InstallableExportFormat(
            formatId: "parquet",
            displayName: "Parquet Export",
            registryPluginId: "com.TablePro.ParquetExportPlugin"
        )

        #expect(ExportFormatCatalog.installable(in: decoded) == [parquet])
    }

    @Test("Each format the manifest lists is offered under its plugin's name")
    func manifestFormatsAreOffered() {
        let listed = manifest([
            registryPlugin(id: "com.TablePro.ParquetExportPlugin", name: "Parquet Export", exportFormatIds: ["parquet"]),
            registryPlugin(id: "com.example.AvroExport", name: "Avro Export", exportFormatIds: ["avro"])
        ])
        let parquet = InstallableExportFormat(
            formatId: "parquet",
            displayName: "Parquet Export",
            registryPluginId: "com.TablePro.ParquetExportPlugin"
        )
        let avro = InstallableExportFormat(
            formatId: "avro",
            displayName: "Avro Export",
            registryPluginId: "com.example.AvroExport"
        )

        #expect(ExportFormatCatalog.installable(in: listed) == [parquet, avro])
        #expect(ExportFormatCatalog.notInstalled(installedFormatIds: ["parquet"], manifest: listed) == [avro])
    }
}
