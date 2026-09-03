//
//  ExportFormatCatalog.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// How the export dialog orders and describes the formats it offers.
///
/// A format that is not listed here is still shown: it sorts after the curated ones by display
/// name and describes itself from its own `pluginDescription`. A registry format installed after
/// this app was built would otherwise tie with every other unknown format at the end of the list
/// and show no description at all, which is how Parquet shipped.
internal enum ExportFormatCatalog {
    private static let displayOrder = [
        "csv", "json", "sql", "xlsx", "md", "html", "xml", "parquet", "mql"
    ]

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
        case "html": String(localized: "An HTML table. Open in a browser or paste into a page.")
        case "xml": String(localized: "One element per row. Use where a parser expects XML.")
        case "parquet": String(localized: "Columnar format. Read by DuckDB, Spark, pandas and BigQuery.")
        case "mql": String(localized: "MongoDB query language. Use to import into MongoDB.")
        default: nil
        }
    }
}
