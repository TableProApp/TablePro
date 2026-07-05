//
//  ClickHousePluginDriver+Schema.swift
//  ClickHouseDriverPlugin
//

import Foundation
import os
import TableProPluginKit

extension ClickHousePluginDriver {
    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let sql = """
            SELECT name, engine FROM system.tables
            WHERE database = currentDatabase() AND name NOT LIKE '.%'
            ORDER BY name
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let engine = row[safe: 1]?.asText
            let tableType = clickHouseTableType(forEngine: engine)
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let pkSql = """
            SELECT primary_key, sorting_key FROM system.tables
            WHERE database = currentDatabase() AND name = '\(escapedTable)'
            """
        let pkResult = try await execute(query: pkSql)
        let primaryKey = pkResult.rows.first.flatMap { $0[safe: 0]?.asText } ?? ""
        let sortingKey = pkResult.rows.first.flatMap { $0[safe: 1]?.asText } ?? ""
        let keyString = primaryKey.isEmpty ? sortingKey : primaryKey
        let pkColumns = Set(keyString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

        let sql = """
            SELECT name, type, default_kind, default_expression, comment
            FROM system.columns
            WHERE database = currentDatabase() AND table = '\(escapedTable)'
            ORDER BY position
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let dataType = (row[safe: 1]?.asText) ?? "String"
            let defaultKind = row[safe: 2]?.asText
            let defaultExpr = row[safe: 3]?.asText
            let comment = row[safe: 4]?.asText

            let isNullable = dataType.hasPrefix("Nullable(")

            var defaultValue: String?
            if let kind = defaultKind, !kind.isEmpty, let expr = defaultExpr, !expr.isEmpty {
                defaultValue = expr
            }

            var extra: String?
            if let kind = defaultKind, !kind.isEmpty, kind != "DEFAULT" {
                extra = kind
            }

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: pkColumns.contains(name),
                defaultValue: defaultValue,
                extra: extra,
                comment: (comment?.isEmpty == false) ? comment : nil,
                allowedValues: EnumValueParser.parseClickHouseEnum(from: ClickHousePluginDriver.unwrapTypeWrappers(dataType))
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        // Pre-fetch PK columns for all tables. Falls back to sorting_key when
        // primary_key is empty (MergeTree without explicit PRIMARY KEY clause).
        // Note: expression-based keys like toDate(col) won't match bare column names.
        let pkSql = """
            SELECT name, primary_key, sorting_key FROM system.tables
            WHERE database = currentDatabase()
            """
        let pkResult = try await execute(query: pkSql)
        var pkLookup: [String: Set<String>] = [:]
        for row in pkResult.rows {
            guard let tableName = row[safe: 0]?.asText else { continue }
            let primaryKey = (row[safe: 1]?.asText) ?? ""
            let sortingKey = (row[safe: 2]?.asText) ?? ""
            let keyString = primaryKey.isEmpty ? sortingKey : primaryKey
            guard !keyString.isEmpty else { continue }
            let cols = Set(keyString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            pkLookup[tableName] = cols
        }

        let sql = """
            SELECT table, name, type, default_kind, default_expression, comment
            FROM system.columns
            WHERE database = currentDatabase()
            ORDER BY table, position
            """
        let result = try await execute(query: sql)
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let colName = row[safe: 1]?.asText else { continue }
            let dataType = (row[safe: 2]?.asText) ?? "String"
            let defaultKind = row[safe: 3]?.asText
            let defaultExpr = row[safe: 4]?.asText
            let comment = row[safe: 5]?.asText

            let isNullable = dataType.hasPrefix("Nullable(")

            var defaultValue: String?
            if let kind = defaultKind, !kind.isEmpty, let expr = defaultExpr, !expr.isEmpty {
                defaultValue = expr
            }

            var extra: String?
            if let kind = defaultKind, !kind.isEmpty, kind != "DEFAULT" {
                extra = kind
            }

            let colInfo = PluginColumnInfo(
                name: colName,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: pkLookup[tableName]?.contains(colName) == true,
                defaultValue: defaultValue,
                extra: extra,
                comment: (comment?.isEmpty == false) ? comment : nil,
                allowedValues: EnumValueParser.parseClickHouseEnum(from: ClickHousePluginDriver.unwrapTypeWrappers(dataType))
            )
            columnsByTable[tableName, default: []].append(colInfo)
        }
        return columnsByTable
    }

    static func unwrapTypeWrappers(_ value: String) -> String {
        for prefix in ["Nullable(", "LowCardinality("] {
            if value.hasPrefix(prefix), value.hasSuffix(")") {
                let start = value.index(value.startIndex, offsetBy: prefix.count)
                let end = value.index(before: value.endIndex)
                return unwrapTypeWrappers(String(value[start..<end]))
            }
        }
        return value
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        var indexes: [PluginIndexInfo] = []

        let sortingKeySql = """
            SELECT sorting_key FROM system.tables
            WHERE database = currentDatabase() AND name = '\(escapedTable)'
            """
        let sortingResult = try await execute(query: sortingKeySql)
        if let row = sortingResult.rows.first,
           let sortingKey = row[safe: 0]?.asText, !sortingKey.isEmpty {
            let columns = sortingKey.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            indexes.append(PluginIndexInfo(
                name: "PRIMARY (sorting key)",
                columns: columns,
                isUnique: false,
                isPrimary: true,
                type: "SORTING KEY"
            ))
        }

        let caps = ClickHouseCapabilities.parse(serverVersion)
        guard caps.hasDataSkippingIndicesTable else { return indexes }
        let skippingSql = """
            SELECT name, expr FROM system.data_skipping_indices
            WHERE database = currentDatabase() AND table = '\(escapedTable)'
            """
        let skippingResult = try await execute(query: skippingSql)
        for row in skippingResult.rows {
            guard let idxName = row[safe: 0]?.asText else { continue }
            let expr = (row[safe: 1]?.asText) ?? ""
            let columns = expr.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            indexes.append(PluginIndexInfo(
                name: idxName,
                columns: columns,
                isUnique: false,
                isPrimary: false,
                type: "DATA_SKIPPING"
            ))
        }

        return indexes
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT sum(rows) FROM system.parts
            WHERE database = currentDatabase() AND table = '\(escapedTable)' AND active = 1
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first, let cell = row.first, let str = cell.asText {
            return Int(str)
        }
        return nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let escapedTable = table.replacingOccurrences(of: "`", with: "``")
        let sql = "SHOW CREATE TABLE `\(escapedTable)`"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.asText ?? ""
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let escapedView = view.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT as_select FROM system.tables
            WHERE database = currentDatabase() AND name = '\(escapedView)'
            """
        let result = try await execute(query: sql)
        return result.rows.first?.first?.asText ?? ""
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let engineSql = """
            SELECT engine, comment FROM system.tables
            WHERE database = currentDatabase() AND name = '\(escapedTable)'
            """
        let engineResult = try await execute(query: engineSql)
        let engine = engineResult.rows.first.flatMap { $0[safe: 0]?.asText }
        let tableComment = engineResult.rows.first.flatMap { $0[safe: 1]?.asText }

        let partsSql = """
            SELECT sum(rows), sum(bytes_on_disk)
            FROM system.parts
            WHERE database = currentDatabase() AND table = '\(escapedTable)' AND active = 1
            """
        let partsResult = try await execute(query: partsSql)
        if let row = partsResult.rows.first {
            let rowCount = (row[safe: 0]?.asText).flatMap { Int64($0) }
            let sizeBytes = (row[safe: 1]?.asText).flatMap { Int64($0) } ?? 0
            return PluginTableMetadata(
                tableName: table,
                dataSize: sizeBytes,
                totalSize: sizeBytes,
                rowCount: rowCount,
                comment: (tableComment?.isEmpty == false) ? tableComment : nil,
                engine: engine
            )
        }

        return PluginTableMetadata(tableName: table, engine: engine)
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: "SHOW DATABASES")
        return result.rows.compactMap { $0.first?.asText }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let escapedDb = database.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT count() AS table_count, sum(total_bytes) AS size_bytes
            FROM system.tables WHERE database = '\(escapedDb)'
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let tableCount = (row[safe: 0]?.asText).flatMap { Int($0) } ?? 0
            let sizeBytes = (row[safe: 1]?.asText).flatMap { Int64($0) }
            return PluginDatabaseMetadata(
                name: database,
                tableCount: tableCount,
                sizeBytes: sizeBytes
            )
        }
        return PluginDatabaseMetadata(name: database)
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let sql = """
            SELECT database, count() AS table_count, sum(total_bytes) AS size_bytes
            FROM system.tables
            GROUP BY database
            ORDER BY database
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginDatabaseMetadata? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let tableCount = (row[safe: 1]?.asText).flatMap { Int($0) } ?? 0
            let sizeBytes = (row[safe: 2]?.asText).flatMap { Int64($0) }
            return PluginDatabaseMetadata(name: name, tableCount: tableCount, sizeBytes: sizeBytes)
        }
    }

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(fields: [], footnote: nil)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let escapedName = request.name.replacingOccurrences(of: "`", with: "``")
        _ = try await execute(query: "CREATE DATABASE `\(escapedName)`")
    }

    func dropDatabase(name: String) async throws {
        let escapedName = name.replacingOccurrences(of: "`", with: "``")
        _ = try await execute(query: "DROP DATABASE `\(escapedName)`")
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
        SELECT
            database as `schema`,
            name,
            engine as kind,
            total_rows as estimated_rows,
            formatReadableSize(total_bytes) as total_size,
            comment
        FROM system.tables
        WHERE database = currentDatabase()
        ORDER BY name
        """
    }

}
