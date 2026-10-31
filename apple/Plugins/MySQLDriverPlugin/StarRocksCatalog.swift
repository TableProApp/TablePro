//
//  StarRocksCatalog.swift
//  MySQLDriverPlugin
//
//  StarRocks puts catalogs above databases: `default_catalog` holds its own tables, and an external
//  catalog fronts Iceberg, Hive, Delta Lake or another engine. The connection browses catalogs where
//  MySQL browses databases, and a catalog's databases where a schema-switching engine browses schemas.
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

nonisolated internal enum StarRocksCatalog {
    static let defaultCatalog = "default_catalog"

    static let showCatalogs = "SHOW CATALOGS"

    static let showDatabases = "SHOW DATABASES"

    static func setCatalog(_ catalog: String) -> String {
        "SET CATALOG \(mysqlQuoteIdentifier(catalog))"
    }

    static func useDatabase(_ database: String) -> String {
        "USE \(mysqlQuoteIdentifier(database))"
    }

    /// What the Database field of a connection names.
    ///
    /// `catalog.database` is the form StarRocks itself takes in its handshake and in `USE`, and the one
    /// a connection imported from another client carries. Sent whole as one quoted name, the server
    /// reads it as a database called `catalog.database` and an Iceberg REST catalog refuses it as a
    /// malformed namespace. A name without a dot is ambiguous: a pooled metadata connection fills the
    /// field with the browsed catalog, while a connection typed by hand means a database in
    /// `default_catalog`, so it is settled against the server when the session opens.
    enum ConfiguredTarget: Equatable, Sendable {
        case serverDefault
        case qualified(catalog: String, database: String)
        case bareName(String)
    }

    static func target(fromConfiguredDatabase text: String) -> ConfiguredTarget {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .serverDefault }
        guard let dot = trimmed.firstIndex(of: ".") else { return .bareName(trimmed) }
        let catalog = String(trimmed[..<dot])
        let database = String(trimmed[trimmed.index(after: dot)...])
        guard !catalog.isEmpty else { return .bareName(database) }
        return .qualified(catalog: catalog, database: database)
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

    /// A `SHOW TABLE STATUS` row, at MySQL's positions. StarRocks reports a view's rows and sizes as
    /// -1 and never an index length, so the data length is the whole size.
    static func tableMetadata(fromStatusRow row: [PluginCellValue], tableName: String) -> PluginTableMetadata {
        let dataSize = measured(row[safe: 6])
        return PluginTableMetadata(
            tableName: tableName,
            dataSize: dataSize,
            totalSize: dataSize,
            avgRowLength: measured(row[safe: 5]),
            rowCount: measured(row[safe: 4]),
            comment: row[safe: 17]?.asText?.nilIfEmpty,
            engine: row[safe: 1]?.asText?.nilIfEmpty,
            collation: row[safe: 14]?.asText?.nilIfEmpty
        )
    }

    static func rowCount(fromStatusRow row: [PluginCellValue]) -> Int? {
        measured(row[safe: 4]).map { Int($0) }
    }

    private static func measured(_ cell: PluginCellValue?) -> Int64? {
        cell?.asText.flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil }
    }

    static func columns(database: String, table: String?) -> String {
        let tableFilter = table.map { " AND TABLE_NAME = '\(mysqlEscapeStringLiteral($0))'" } ?? ""
        return """
            SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, COLUMN_COMMENT
            FROM information_schema.columns
            WHERE TABLE_SCHEMA = '\(mysqlEscapeStringLiteral(database))'\(tableFilter)
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """
    }

    /// `COLUMN_KEY` names the table's key model on each key column. A primary, unique or aggregate key
    /// holds one row per key, so it picks out the row a grid edit means; a duplicate key holds any number.
    static let rowIdentifyingKeys: Set<String> = ["PRI", "UNI", "AGG"]

    static func columnsByTable(from rows: [[PluginCellValue]]) -> [String: [PluginColumnInfo]] {
        var columns: [String: [PluginColumnInfo]] = [:]
        for row in rows {
            guard let table = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText,
                  let dataType = row[safe: 2]?.asText
            else { continue }
            columns[table, default: []].append(PluginColumnInfo(
                name: name,
                dataType: dataType.uppercased(),
                isNullable: row[safe: 3]?.asText == "YES",
                isPrimaryKey: rowIdentifyingKeys.contains(row[safe: 4]?.asText ?? ""),
                defaultValue: row[safe: 5]?.asText,
                comment: row[safe: 6]?.asText?.nilIfEmpty
            ))
        }
        return columns
    }
}
