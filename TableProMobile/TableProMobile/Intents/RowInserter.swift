import Foundation
import TableProDatabase
import TableProModels

enum RowInsertPlanner {
    static func statements(
        table: String,
        type: DatabaseType,
        columns: [ColumnInfo],
        rows: [PayloadRow]
    ) throws -> [String] {
        guard !columns.isEmpty else { throw IntentDataError.noColumns(table) }
        let columnNames = Set(columns.map(\.name))
        let primaryKeys = Set(columns.filter(\.isPrimaryKey).map(\.name))

        return try rows.compactMap { row in
            let unknown = row.keys.filter { !columnNames.contains($0) }
            guard unknown.isEmpty else { throw IntentDataError.unknownColumns(unknown.sorted(), table) }

            var insertColumns: [String] = []
            var insertValues: [String?] = []
            for column in columns {
                guard let value = row.value(for: column.name) else { continue }
                if primaryKeys.contains(column.name), value.isEmptyOrNull { continue }
                insertColumns.append(column.name)
                insertValues.append(value.sqlValue)
            }
            guard !insertColumns.isEmpty else { return nil }
            return SQLBuilder.buildInsert(
                table: table,
                type: type,
                columns: insertColumns,
                values: insertValues
            )
        }
    }
}

enum RowInserter {
    static func insert(
        driver: any DatabaseDriver,
        table: String,
        type: DatabaseType,
        schema: String?,
        rows: [PayloadRow]
    ) async throws -> Int {
        let columns = try await driver.fetchColumns(table: table, schema: schema)
        let statements = try RowInsertPlanner.statements(table: table, type: type, columns: columns, rows: rows)
        var affected = 0
        for statement in statements {
            let result = try await driver.execute(query: statement)
            affected += max(result.rowsAffected, 0)
        }
        return affected
    }
}
