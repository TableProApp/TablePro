import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProTeradataCore

extension TeradataPluginDriver {
    private func qualified(_ table: String) -> String {
        TeradataSchemaQueries.qualifiedName(database: currentDatabaseName, table: table)
    }

    private func identifier(_ name: String) -> String {
        TeradataSchemaQueries.quoteIdentifier(name)
    }

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? {
        switch operation {
        case .addColumn(let column):
            return Self.refusal(for: column)
        case .modifyColumn(let old, let new) where old.name == new.name:
            return Self.refusal(for: new)
        default:
            return nil
        }
    }

    // A copy or a sync takes the type and the default from the source's catalog, and a request runs every statement in it.
    static func refusal(for column: PluginColumnDefinition) -> String? {
        if !SQLExpressionFragment.isSingleType(column.dataType, databaseTypeId: "Teradata") {
            return String(
                format: String(localized: "The type of column %@ does not read as one type: %@"),
                column.name,
                column.dataType
            )
        }
        if let value = column.defaultValue, !value.isEmpty,
           !SQLExpressionFragment.isSingleExpression(value, databaseTypeId: "Teradata") {
            return String(
                format: String(localized: "The default of column %@ is not one SQL expression, so it cannot be written."),
                column.name
            )
        }
        return nil
    }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        guard Self.refusal(for: column) == nil else { return nil }
        var parts = ["\(identifier(column.name)) \(column.dataType)"]
        if column.autoIncrement {
            parts.append("GENERATED ALWAYS AS IDENTITY")
        }
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            parts.append("DEFAULT \(defaultValue)")
        }
        parts.append(column.isNullable ? "" : "NOT NULL")
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Teradata's referential constraints carry no `ON DELETE` or `ON UPDATE` action, so none is
    /// written. `ForeignKeyDialect` offers the editor only NO ACTION for the same reason.
    private func foreignKeyDefinition(_ foreignKey: PluginForeignKeyDefinition) -> String {
        let columns = foreignKey.columns.map(identifier).joined(separator: ", ")
        let constraint = foreignKey.name.isEmpty ? "" : "CONSTRAINT \(identifier(foreignKey.name)) "
        let referenced = foreignKey.referencedSchema.flatMap { $0.isEmpty ? nil : $0 }
            .map { "\(identifier($0)).\(identifier(foreignKey.referencedTable))" }
            ?? qualified(foreignKey.referencedTable)
        var definition = "\(constraint)FOREIGN KEY (\(columns)) REFERENCES \(referenced)"
        if !foreignKey.referencedColumns.isEmpty {
            definition += " (\(foreignKey.referencedColumns.map(identifier).joined(separator: ", ")))"
        }
        return definition
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        var columnDefinitions: [String] = []
        for column in definition.columns {
            guard let sql = generateColumnDefinitionSQL(column: column) else { return nil }
            columnDefinitions.append(sql)
        }
        guard !columnDefinitions.isEmpty else { return nil }
        columnDefinitions.append(contentsOf: definition.foreignKeys.map(foreignKeyDefinition))
        var sql = "CREATE MULTISET TABLE \(qualified(definition.tableName)) (\n"
        sql += "    " + columnDefinitions.joined(separator: ",\n    ")
        sql += "\n)"
        if !definition.primaryKeyColumns.isEmpty {
            let keys = definition.primaryKeyColumns.map(identifier).joined(separator: ", ")
            sql += " PRIMARY INDEX (\(keys))"
        }
        return sql
    }

    func generateCreateTableStatements(definition: PluginCreateTableDefinition) -> [String]? {
        guard let createTable = generateCreateTableSQL(definition: definition) else { return nil }
        let comments = TeradataSchemaQueries.columnCommentStatements(
            qualifiedTable: qualified(definition.tableName),
            comments: definition.columns.map { (column: $0.name, comment: $0.comment) }
        )
        return [createTable] + comments
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        TeradataSchemaQueries.commentStatement(
            objectType: objectType,
            qualifiedName: TeradataSchemaQueries.qualifiedName(database: effectiveDatabase(schema), table: name),
            comment: comment
        )
    }

    // Teradata has no TRUNCATE; DELETE ... ALL is its documented way to empty a table, and it has no CASCADE.
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["DELETE FROM \(TeradataSchemaQueries.qualifiedName(database: effectiveDatabase(schema), table: table)) ALL"]
    }

    func createViewTemplate() -> String? {
        "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        guard let definition = generateColumnDefinitionSQL(column: column) else { return nil }
        return "ALTER TABLE \(qualified(table)) ADD \(definition)"
    }

    func generateModifyColumnSQL(
        table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition
    ) -> String? {
        if oldColumn.name != newColumn.name {
            return "ALTER TABLE \(qualified(table)) "
                + "RENAME \(identifier(oldColumn.name)) TO \(identifier(newColumn.name))"
        }
        guard let definition = generateColumnDefinitionSQL(column: newColumn) else { return nil }
        return "ALTER TABLE \(qualified(table)) ADD \(definition)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualified(table)) DROP \(identifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        let columns = index.columns.map(identifier).joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        return "CREATE \(unique)INDEX \(identifier(index.name)) (\(columns)) ON \(qualified(table))"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(identifier(indexName)) ON \(qualified(table))"
    }
}
