import Foundation
import TableProPluginKit

internal struct InstallableExportFormat: Equatable, Sendable {
    internal let formatId: String
    internal let displayName: String
    internal let registryPluginId: String
}

internal enum ExportFormatCatalog {
    internal static let dataDictionaryFormatId = "datadict"

    private static let displayOrder = [
        "csv", "json", "sql", "xlsx", "md", "parquet", "mql", dataDictionaryFormatId
    ]

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
        sorted(plugins.filter { plugin in
            let pluginType = type(of: plugin)
            if writesStructureOnly(plugin), !listsDatabaseObjects || columnsAreSampled {
                return false
            }
            return accepts(
                databaseTypeId: databaseTypeId,
                supportedDatabaseTypeIds: pluginType.supportedDatabaseTypeIds,
                excludedDatabaseTypeIds: pluginType.excludedDatabaseTypeIds
            )
        })
    }

    internal static func writesStructureOnly(_ plugin: any ExportFormatPlugin) -> Bool {
        !plugin.readsRows(optionValues: plugin.defaultTableOptionValues(), kind: .table)
    }

    internal static func accepts(
        databaseTypeId: String,
        supportedDatabaseTypeIds: [String],
        excludedDatabaseTypeIds: [String]
    ) -> Bool {
        guard supportedDatabaseTypeIds.isEmpty else {
            return supportedDatabaseTypeIds.contains(databaseTypeId)
        }
        return !excludedDatabaseTypeIds.contains(databaseTypeId)
    }

    internal static func sorted(_ plugins: [any ExportFormatPlugin]) -> [any ExportFormatPlugin] {
        plugins.sorted { first, second in
            let firstRank = rank(of: type(of: first).formatId)
            let secondRank = rank(of: type(of: second).formatId)
            guard firstRank == secondRank else { return firstRank < secondRank }
            return type(of: first).formatDisplayName
                .localizedCaseInsensitiveCompare(type(of: second).formatDisplayName) == .orderedAscending
        }
    }

    internal static func description(for plugin: any ExportFormatPlugin) -> String {
        let pluginType = type(of: plugin)
        return curatedDescription(for: pluginType.formatId) ?? pluginType.pluginDescription
    }

    private static func rank(of formatId: String) -> Int {
        displayOrder.firstIndex(of: formatId) ?? displayOrder.count
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
