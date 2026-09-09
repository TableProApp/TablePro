import Foundation
import TableProPluginKit
import TableProTeradataCore

extension TeradataPluginDriver {
    private func qualified(_ table: String) -> String {
        TeradataSchemaQueries.qualifiedName(database: currentDatabaseName, table: table)
    }

    private func identifier(_ name: String) -> String {
        TeradataSchemaQueries.quoteIdentifier(name)
    }

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
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
        var columnDefinitions = definition.columns.compactMap { generateColumnDefinitionSQL(column: $0) }
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
