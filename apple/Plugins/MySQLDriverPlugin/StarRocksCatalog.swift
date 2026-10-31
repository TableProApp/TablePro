//
//  StarRocksCatalog.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

// StarRocks puts catalogs above databases, so its catalogs fill the database level and a catalog's
// databases the schema level.
nonisolated internal enum StarRocksCatalog {
    static let defaultCatalog = "default_catalog"

    static let showCatalogs = "SHOW CATALOGS"

    static let showDatabases = "SHOW DATABASES"

    struct Scope: Equatable, Sendable {
        let catalog: String
        let database: String

        init(catalog: String, database: String) {
            self.catalog = catalog
            self.database = database
        }

        // `catalog.database`, the form StarRocks clients take; a bare name is a database in default_catalog.
        init(configuredDatabase text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let dot = trimmed.firstIndex(of: ".") else {
                self.init(catalog: StarRocksCatalog.defaultCatalog, database: trimmed)
                return
            }
            let catalog = String(trimmed[..<dot])
            self.init(
                catalog: catalog.isEmpty ? StarRocksCatalog.defaultCatalog : catalog,
                database: String(trimmed[trimmed.index(after: dot)...])
            )
        }

        // `USE` splits one identifier at its dot; quoting each part fails with 5501 Unknown database.
        var enterStatement: String {
            guard !database.isEmpty else { return "SET CATALOG \(mysqlQuoteIdentifier(catalog))" }
            return "USE \(mysqlQuoteIdentifier("\(catalog).\(database)"))"
        }

        var isServerDefault: Bool {
            catalog == StarRocksCatalog.defaultCatalog && database.isEmpty
        }

        // Table status and materialized views exist only in default_catalog. Elsewhere `SHOW TABLE STATUS`
        // answers for the default_catalog database of the same name.
        var keepsTableStatus: Bool {
            catalog == StarRocksCatalog.defaultCatalog
        }

        // Entering the catalog again keeps the database; entering another leaves none selected.
        func entering(catalog target: String) -> Scope {
            Scope(catalog: target, database: target == catalog ? database : "")
        }
    }

    static func names(from rows: [[PluginCellValue]]) -> [String] {
        rows.compactMap { $0[safe: 0]?.asText?.nilIfEmpty }
    }

    static func materializedViewNames(database: String) -> String {
        """
        SELECT TABLE_NAME FROM information_schema.materialized_views
        WHERE TABLE_SCHEMA = '\(mysqlEscapeStringLiteral(database))'
        """
    }

    // `SHOW FULL TABLES` types a materialized view as `VIEW`.
    static func markingMaterializedViews(_ names: Set<String>, in tables: [PluginTableInfo]) -> [PluginTableInfo] {
        guard !names.isEmpty else { return tables }
        return tables.map { table in
            guard names.contains(table.name) else { return table }
            return PluginTableInfo(
                name: table.name, type: "MATERIALIZED VIEW", rowCount: table.rowCount, schema: table.schema,
                comment: table.comment, partitionCount: nil, ownedByTable: nil, ownedByColumn: nil
            )
        }
    }

    // `SHOW FULL COLUMNS` on an Iceberg table adds the connector's `_file` and `_pos`, which `SELECT *` never returns.
    static func columns(database: String, table: String?) -> String {
        let tableFilter = table.map { " AND TABLE_NAME = '\(mysqlEscapeStringLiteral($0))'" } ?? ""
        return """
            SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, COLUMN_COMMENT
            FROM information_schema.columns
            WHERE TABLE_SCHEMA = '\(mysqlEscapeStringLiteral(database))'\(tableFilter)
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """
    }

    // `COLUMN_KEY` names the key model. A duplicate key (`DUP`) holds any number of equal rows.
    static let rowIdentifyingKeys: Set<String> = ["PRI", "UNI", "AGG"]

    static func columnsByTable(from rows: [[PluginCellValue]]) -> [String: [PluginColumnInfo]] {
        var columns: [String: [PluginColumnInfo]] = [:]
        for row in rows {
            guard let table = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText,
                  let dataType = row[safe: 2]?.asText
            else { continue }
            let isNullable = row[safe: 3]?.asText == "YES"
            columns[table, default: []].append(PluginColumnInfo(
                name: name,
                dataType: dataType.uppercased(),
                isNullable: isNullable,
                isPrimaryKey: rowIdentifyingKeys.contains(row[safe: 4]?.asText ?? ""),
                defaultValue: mysqlColumnDefault(
                    .bare(row[safe: 5]?.asText), extra: nil, dataType: dataType, isNullable: isNullable
                ),
                comment: row[safe: 6]?.asText?.nilIfEmpty
            ))
        }
        return columns
    }
}
