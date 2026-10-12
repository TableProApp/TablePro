//
//  ExportFormatCatalog.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct InstallableExportFormat: Equatable, Sendable {
    internal let formatId: String
    internal let displayName: String
    internal let registryPluginId: String
}

internal enum ExportFormatCatalog {
    private static let displayOrder = [
        "csv", "json", "sql", "xlsx", "md", "parquet", "mql"
    ]

    // The registry manifest names no format id, so the app keeps the one mapping it offers.
    internal static let installable = [
        InstallableExportFormat(
            formatId: "parquet",
            displayName: "Parquet",
            registryPluginId: "com.TablePro.ParquetExportPlugin"
        )
    ]

    internal static func notInstalled(installedFormatIds: Set<String>) -> [InstallableExportFormat] {
        installable.filter { !installedFormatIds.contains($0.formatId) }
    }

    internal static func available(
        _ plugins: [any ExportFormatPlugin],
        forDatabaseTypeId databaseTypeId: String
    ) -> [any ExportFormatPlugin] {
        sorted(plugins.filter { plugin in
            let pluginType = type(of: plugin)
            return accepts(
                databaseTypeId: databaseTypeId,
                supportedDatabaseTypeIds: pluginType.supportedDatabaseTypeIds,
                excludedDatabaseTypeIds: pluginType.excludedDatabaseTypeIds
            )
        })
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
        default: nil
        }
    }
}
