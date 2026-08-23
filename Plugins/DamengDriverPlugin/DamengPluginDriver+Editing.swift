import Foundation
import TableProPluginKit

extension DamengPluginDriver {
    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generateStatements(
            table: table,
            schema: nil,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            changes: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    func generateStatements(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let qualifiedTable = qualifiedName(schema: schema, object: table)
        var statements: [(statement: String, parameters: [PluginCellValue])] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let row = insertedRowData[change.rowIndex],
                      let statement = insertStatement(table: qualifiedTable, columns: columns, values: row) else {
                    continue
                }
                statements.append(statement)
            case .update:
                guard let statement = updateStatement(
                    table: qualifiedTable,
                    columns: columns,
                    primaryKeyColumns: primaryKeyColumns,
                    change: change
                ) else {
                    continue
                }
                statements.append(statement)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex),
                      let statement = deleteStatement(
                          table: qualifiedTable,
                          columns: columns,
                          primaryKeyColumns: primaryKeyColumns,
                          change: change
                      ) else {
                    continue
                }
                statements.append(statement)
            }
        }
        return statements.isEmpty ? nil : statements
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }
        let table = qualifiedName(schema: nil, object: definition.tableName)
        let primaryKeys = definition.columns.filter(\.isPrimaryKey)
        let inlinePrimaryKey = primaryKeys.count == 1
        var definitions = definition.columns.map { columnDefinition($0, inlinePrimaryKey: inlinePrimaryKey) }
        if primaryKeys.count > 1 {
            definitions.append("PRIMARY KEY (\(primaryKeys.map { quoteIdentifier($0.name) }.joined(separator: ", ")))")
        }
        definitions.append(contentsOf: definition.foreignKeys.map(foreignKeyDefinition))
        let createTable = "CREATE TABLE \(table) (\n    " + definitions.joined(separator: ",\n    ") + "\n)"
        let indexes = definition.indexes.map { indexDefinition($0, table: table) }
        let comments = definition.columns.compactMap { column -> String? in
            guard let comment = column.comment, !comment.isEmpty else { return nil }
            return "COMMENT ON COLUMN \(table).\(quoteIdentifier(column.name)) IS \(stringLiteral(comment))"
        }
        let statements = [createTable] + indexes + comments
        return statements.joined(separator: ";\n") + ";"
    }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        columnDefinition(column, inlinePrimaryKey: false)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        indexDefinition(index, table: tableName.map { qualifiedName(schema: nil, object: $0) } ?? "\"table\"")
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        foreignKeyDefinition(fk)
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(qualifiedName(schema: nil, object: table)) ADD \(columnDefinition(column, inlinePrimaryKey: false))"
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        let qualifiedTable = qualifiedName(schema: nil, object: table)
        var statements: [String] = []
        if oldColumn.name != newColumn.name {
            statements.append(
                "ALTER TABLE \(qualifiedTable) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))"
            )
        }
        let attributesChanged = oldColumn.dataType != newColumn.dataType ||
            oldColumn.isNullable != newColumn.isNullable ||
            oldColumn.defaultValue != newColumn.defaultValue
        if attributesChanged {
            statements.append(
                "ALTER TABLE \(qualifiedTable) MODIFY \(columnDefinition(newColumn, inlinePrimaryKey: false))"
            )
        }
        return statements.isEmpty ? nil : statements.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualifiedName(schema: nil, object: table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        indexDefinition(index, table: qualifiedName(schema: nil, object: table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(qualifiedName(schema: nil, object: indexName))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(qualifiedName(schema: nil, object: table)) ADD \(foreignKeyDefinition(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(qualifiedName(schema: nil, object: table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateModifyPrimaryKeySQL(
        table: String,
        oldColumns: [String],
        newColumns: [String],
        constraintName: String?
    ) -> [String]? {
        let qualifiedTable = qualifiedName(schema: nil, object: table)
        var statements: [String] = []
        if !oldColumns.isEmpty {
            if let constraintName, !constraintName.isEmpty {
                statements.append("ALTER TABLE \(qualifiedTable) DROP CONSTRAINT \(quoteIdentifier(constraintName))")
            } else {
                statements.append("ALTER TABLE \(qualifiedTable) DROP PRIMARY KEY")
            }
        }
        if !newColumns.isEmpty {
            let columns = newColumns.map(quoteIdentifier).joined(separator: ", ")
            statements.append("ALTER TABLE \(qualifiedTable) ADD PRIMARY KEY (\(columns))")
        }
        return statements.isEmpty ? nil : statements
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["TRUNCATE TABLE \(qualifiedName(schema: schema, object: table))"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        let normalizedType: String
        switch objectType.uppercased() {
        case "VIEW":
            normalizedType = "VIEW"
        case "MATERIALIZED VIEW":
            normalizedType = "MATERIALIZED VIEW"
        default:
            normalizedType = "TABLE"
        }
        let suffix = cascade && normalizedType == "TABLE" ? " CASCADE" : ""
        return "DROP \(normalizedType) \(qualifiedName(schema: schema, object: name))\(suffix)"
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        "SELECT * FROM \(qualifiedName(schema: schema, object: table))"
    }

    private func insertStatement(
        table: String,
        columns: [String],
        values: [PluginCellValue]
    ) -> (statement: String, parameters: [PluginCellValue])? {
        var insertColumns: [String] = []
        var placeholders: [String] = []
        var parameters: [PluginCellValue] = []
        for (index, value) in values.enumerated() where index < columns.count {
            insertColumns.append(quoteIdentifier(columns[index]))
            if value.asText == "__DEFAULT__" {
                placeholders.append("DEFAULT")
            } else {
                placeholders.append("?")
                parameters.append(value)
            }
        }
        guard !insertColumns.isEmpty else { return nil }
        return (
            "INSERT INTO \(table) (\(insertColumns.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))",
            parameters
        )
    }

    private func updateStatement(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty, let original = change.originalRow else { return nil }
        var parameters = change.cellChanges.map(\.newValue)
        let assignments = change.cellChanges.map { "\(quoteIdentifier($0.columnName)) = ?" }
        guard let predicate = rowPredicate(
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            original: original,
            parameters: &parameters
        ) else {
            return nil
        }
        return (
            "UPDATE \(table) SET \(assignments.joined(separator: ", ")) WHERE \(predicate) AND ROWNUM = 1",
            parameters
        )
    }

    private func deleteStatement(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard let original = change.originalRow else { return nil }
        var parameters: [PluginCellValue] = []
        guard let predicate = rowPredicate(
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            original: original,
            parameters: &parameters
        ) else {
            return nil
        }
        return ("DELETE FROM \(table) WHERE \(predicate) AND ROWNUM = 1", parameters)
    }

    private func rowPredicate(
        columns: [String],
        primaryKeyColumns: [String],
        original: [PluginCellValue],
        parameters: inout [PluginCellValue]
    ) -> String? {
        let selectedColumns = primaryKeyColumns.isEmpty ? columns : primaryKeyColumns
        let keyed = !primaryKeyColumns.isEmpty
        var predicates: [String] = []
        for column in selectedColumns {
            guard let index = columns.firstIndex(of: column), index < original.count else {
                // Dropping a declared key column would leave an under-determined predicate,
                // and ROWNUM = 1 would then write to an arbitrary matching row.
                if keyed { return nil }
                continue
            }
            let value = original[index]
            if value.isNull {
                predicates.append("\(quoteIdentifier(column)) IS NULL")
            } else {
                predicates.append("\(quoteIdentifier(column)) = ?")
                parameters.append(value)
            }
        }
        return predicates.isEmpty ? nil : predicates.joined(separator: " AND ")
    }

    private func columnDefinition(_ column: PluginColumnDefinition, inlinePrimaryKey: Bool) -> String {
        var definition = "\(quoteIdentifier(column.name)) \(column.dataType.uppercased())"
        if column.autoIncrement {
            definition += " IDENTITY(1,1)"
        }
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            definition += " DEFAULT \(defaultExpression(defaultValue))"
        }
        if !column.isNullable {
            definition += " NOT NULL"
        }
        if inlinePrimaryKey, column.isPrimaryKey {
            definition += " PRIMARY KEY"
        }
        return definition
    }

    private func indexDefinition(_ index: PluginIndexDefinition, table: String) -> String {
        let unique = index.isUnique ? "UNIQUE " : ""
        let columns = index.columns.map(quoteIdentifier).joined(separator: ", ")
        return "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(table) (\(columns))"
    }

    private func foreignKeyDefinition(_ foreignKey: PluginForeignKeyDefinition) -> String {
        let columns = foreignKey.columns.map(quoteIdentifier).joined(separator: ", ")
        let referencedColumns = foreignKey.referencedColumns.map(quoteIdentifier).joined(separator: ", ")
        let referencedTable = qualifiedName(schema: foreignKey.referencedSchema, object: foreignKey.referencedTable)
        let constraint = foreignKey.name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(foreignKey.name)) "
        let onDelete = foreignKey.onDelete.uppercased() == "NO ACTION" ? "" : " ON DELETE \(foreignKey.onDelete)"
        return "\(constraint)FOREIGN KEY (\(columns)) REFERENCES \(referencedTable) (\(referencedColumns))\(onDelete)"
    }

    private func defaultExpression(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = normalized.uppercased()
        if PluginNumericLiteral.isValid(normalized) || [
            "NULL", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "SYSDATE"
        ].contains(uppercased) || normalized.hasPrefix("'") || normalized.hasPrefix("\"") {
            return normalized
        }
        return stringLiteral(normalized)
    }

    /// Routes through the driver's single escaping seam. `replacingOccurrences` matches whole
    /// grapheme clusters, so a quote carrying a combining mark would not be doubled and the
    /// value would escape its own literal.
    private func stringLiteral(_ value: String) -> String {
        "'\(escapeStringLiteral(value))'"
    }

    private func qualifiedName(schema: String?, object: String) -> String {
        "\(quoteIdentifier(effectiveSchema(schema))).\(quoteIdentifier(object))"
    }
}
