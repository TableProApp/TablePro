import Foundation
import TableProPluginKit

nonisolated enum RedshiftTableCatalog {
    static func listingQuery(schema: String) -> String {
        """
        SELECT table_name, table_type
        FROM information_schema.tables
        WHERE table_schema = \(PostgreSQLObjectQueries.quoteLiteral(schema))
        ORDER BY table_name
        """
    }

    static func table(fromListingRow row: [String?]) -> PluginTableInfo? {
        guard let name = row[safe: 0] ?? nil else { return nil }
        let listedType = (row[safe: 1] ?? nil) ?? "BASE TABLE"
        return PluginTableInfo(name: name, type: listedType.contains("VIEW") ? "VIEW" : "TABLE")
    }

    static func keysQuery(schema: String, table: String) -> String {
        """
        SELECT
            "column",
            type,
            distkey,
            sortkey
        FROM pg_table_def
        WHERE schemaname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
          AND tablename = \(PostgreSQLObjectQueries.quoteLiteral(table))
          AND (distkey = true OR sortkey != 0)
        ORDER BY sortkey
        """
    }

    static func keys(fromRows rows: [[String?]]) -> [PluginIndexInfo] {
        var distkeyColumns: [String] = []
        var sortkeyColumns: [String] = []
        for row in rows {
            guard let column = row[safe: 0] ?? nil else { continue }
            if PostgreSQLCatalogBoolean.isTrue(row[safe: 2] ?? nil) {
                distkeyColumns.append(column)
            }
            let sortKeyPosition = (row[safe: 3] ?? nil).flatMap { Int($0) } ?? 0
            if sortKeyPosition != 0 {
                sortkeyColumns.append(column)
            }
        }

        var keys: [PluginIndexInfo] = []
        if !distkeyColumns.isEmpty {
            keys.append(PluginIndexInfo(name: "DISTKEY", columns: distkeyColumns, type: "DISTKEY"))
        }
        if !sortkeyColumns.isEmpty {
            keys.append(PluginIndexInfo(name: "SORTKEY", columns: sortkeyColumns, type: "SORTKEY"))
        }
        return keys
    }
}
