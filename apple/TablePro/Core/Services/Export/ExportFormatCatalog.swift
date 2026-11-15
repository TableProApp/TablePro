import Foundation
import TableProPluginKit

internal struct InstallableExportFormat: Equatable, Sendable {
    internal let formatId: String
    internal let displayName: String
    internal let registryPluginId: String
}

internal enum ExportFormatCatalog {
    internal static let dataDictionaryFormatId = ExportFormatOffer.dataDictionaryFormatId

    internal static func installable(in manifest: RegistryManifest?) -> [InstallableExportFormat] {
        (manifest?.plugins ?? []).flatMap { plugin in
            plugin.exportFormatIds.map { formatId in
                InstallableExportFormat(formatId: formatId, displayName: plugin.name, registryPluginId: plugin.id)
            }
        }
    }

    internal static func notInstalled(
        installedFormatIds: Set<String>,
        manifest: RegistryManifest?
    ) -> [InstallableExportFormat] {
        installable(in: manifest).filter { !installedFormatIds.contains($0.formatId) }
    }

    // A format that writes structure alone describes the catalog, so it needs objects to describe
    // and an engine whose columns are declared rather than sampled from rows.
    internal static func available(
        _ plugins: [any ExportFormatPlugin],
        forDatabaseTypeId databaseTypeId: String,
        listsDatabaseObjects: Bool,
        columnsAreSampled: Bool
    ) -> [any ExportFormatPlugin] {
        ExportFormatOffer.offered(
            plugins.filter { !writesStructureOnly($0) || (listsDatabaseObjects && !columnsAreSampled) },
            forDatabaseTypeId: databaseTypeId
        )
    }

    internal static func writesStructureOnly(_ plugin: any ExportFormatPlugin) -> Bool {
        !plugin.readsRows(optionValues: plugin.defaultTableOptionValues(), kind: .table)
    }

    internal static func description(for plugin: any ExportFormatPlugin) -> String {
        let pluginType = type(of: plugin)
        return curatedDescription(for: pluginType.formatId) ?? pluginType.pluginDescription
    }

    private static func curatedDescription(for formatId: String) -> String? {
        switch formatId {
        case "csv": String(localized: "Comma-separated values. Compatible with Excel and most tools.")
        case "json": String(localized: "Structured data format. Ideal for APIs and web applications.")
        case "sql": String(localized: "SQL INSERT statements. Use to recreate data in another database.")
        case "xlsx": String(localized: "Excel spreadsheet with formatting support.")
        case "md": String(localized: "Markdown tables. Paste into a README, an issue or a wiki.")
        case "parquet": String(localized: "Columnar format. Read by DuckDB, Spark, pandas and BigQuery.")
        case "mql": String(localized: "MongoDB query language. Use to import into MongoDB.")
        case dataDictionaryFormatId:
            String(localized: "Every column's type, key, default and comment, with indexes and foreign keys. Reads no rows.")
        default: nil
        }
    }
}
