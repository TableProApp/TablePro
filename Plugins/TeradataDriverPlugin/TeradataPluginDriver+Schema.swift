import Foundation
import TableProPluginKit
import TableProTeradataCore

extension TeradataPluginDriver {
    private func effectiveDatabase(_ schema: String?) -> String? {
        if let schema, !schema.isEmpty { return schema }
        return currentDatabaseName
    }

    private func text(_ cell: PluginCellValue?) -> String? {
        if case .text(let value)? = cell { return value }
        return nil
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: TeradataSchemaQueries.listDatabases())
        return result.rows.compactMap { text($0.first) }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(
            name: database,
            isSystemDatabase: TeradataPlugin.systemDatabaseNames.contains { $0.caseInsensitiveCompare(database) == .orderedSame })
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let database = effectiveDatabase(schema) else { return [] }
        let result = try await execute(query: TeradataSchemaQueries.listTables(database: database))
        return result.rows.compactMap { row in
            guard let name = text(row.first) else { return nil }
            let kind = row.count > 1 ? text(row[1]) ?? "T" : "T"
            return PluginTableInfo(name: name, type: Self.tableType(kind), schema: database, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard let database = effectiveDatabase(schema) else { return [] }
        let result = try await execute(query: TeradataSchemaQueries.columns(database: database, table: table))
        return result.rows.map { row in
            let name = text(row.first) ?? ""
            let dbcType = row.count > 1 ? text(row[1]) ?? "" : ""
            let length = Int(text(row.count > 2 ? row[2] : nil) ?? "") ?? 0
            let totalDigits = Int(text(row.count > 3 ? row[3] : nil) ?? "") ?? 0
            let fractionalDigits = Int(text(row.count > 4 ? row[4] : nil) ?? "") ?? 0
            let nullable = (text(row.count > 5 ? row[5] : nil) ?? "Y") == "Y"
            let defaultValue = text(row.count > 6 ? row[6] : nil)
            return PluginColumnInfo(
                name: name,
                dataType: TeradataColumnType.displayName(
                    dbcColumnType: dbcType, length: length,
                    totalDigits: totalDigits, fractionalDigits: fractionalDigits),
                isNullable: nullable,
                defaultValue: defaultValue?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : defaultValue)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        guard let database = effectiveDatabase(schema) else { return [] }
        let result = try await execute(query: TeradataSchemaQueries.indexes(database: database, table: table))
        var byName: [String: (columns: [String], unique: Bool, primary: Bool)] = [:]
        var order: [String] = []
        for row in result.rows {
            let indexName = text(row.first)?.trimmingCharacters(in: .whitespaces) ?? ""
            let indexType = row.count > 1 ? text(row[1]) ?? "" : ""
            let unique = (row.count > 2 ? text(row[2]) ?? "N" : "N") == "Y"
            let column = row.count > 3 ? text(row[3]) ?? "" : ""
            let key = indexName.isEmpty ? indexType : indexName
            if byName[key] == nil {
                byName[key] = (columns: [], unique: unique, primary: indexType == "P" || indexType == "Q")
                order.append(key)
            }
            if !column.isEmpty { byName[key]?.columns.append(column) }
        }
        return order.compactMap { key in
            guard let info = byName[key] else { return nil }
            return PluginIndexInfo(
                name: key, columns: info.columns, isUnique: info.unique,
                isPrimary: info.primary, type: "TERADATA")
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let database = effectiveDatabase(schema)
        let result = try await execute(
            query: TeradataSchemaQueries.showTableDDL(database: database, table: table))
        return result.rows.compactMap { text($0.first) }.joined()
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        guard let database = effectiveDatabase(schema) else { return "" }
        let result = try await execute(
            query: TeradataSchemaQueries.viewDefinition(database: database, view: view))
        return text(result.rows.first?.first) ?? ""
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let rowCount = try await fetchApproximateRowCount(table: table, schema: schema)
        return PluginTableMetadata(tableName: table, rowCount: rowCount.map { Int64($0) })
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let target = TeradataSchemaQueries.qualifiedName(database: effectiveDatabase(schema), table: table)
        let result = try await execute(query: "SELECT COUNT(*) FROM \(target)")
        return text(result.rows.first?.first).flatMap { Int($0) }
    }

    func switchDatabase(to database: String) async throws {
        _ = try await execute(query: TeradataSchemaQueries.setDatabase(database))
        currentDatabaseName = database
    }

    func buildBrowseQuery(
        table: String, sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String], limit: Int, offset: Int
    ) -> String? {
        buildBrowseQuery(
            table: table, schema: nil, sortColumns: sortColumns,
            columns: columns, limit: limit, offset: offset)
    }

    func buildBrowseQuery(
        table: String, schema: String?, sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String], limit: Int, offset: Int
    ) -> String? {
        let sorts: [(name: String, ascending: Bool)] = sortColumns.compactMap { sort in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            return (columns[sort.columnIndex], sort.ascending)
        }
        return TeradataSchemaQueries.browse(
            database: effectiveDatabase(schema), table: table,
            columns: columns.isEmpty ? nil : columns, sortColumns: sorts,
            limit: limit, offset: offset)
    }

    private static func tableType(_ kind: String) -> String {
        kind.trimmingCharacters(in: .whitespaces) == "V" ? "VIEW" : "TABLE"
    }
}
