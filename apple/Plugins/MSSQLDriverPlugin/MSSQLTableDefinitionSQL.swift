//
//  MSSQLTableDefinitionSQL.swift
//  MSSQLDriverPlugin
//
//  The `CREATE TABLE`, column, index and foreign key clauses the driver writes. Pure, so what a
//  copied table's DDL says is pinned by a test without a FreeTDS connection.
//

import Foundation
import TableProMSSQLCore
import TableProPluginKit
import TableProSQLQuoting

enum MSSQLTableDefinitionSQL {
    static func createTable(_ definition: PluginCreateTableDefinition, schema: String) -> String? {
        guard let createTable = createTableStatement(definition, schema: schema) else { return nil }
        var sql = createTable + ";"
        let indexes = indexStatements(definition, schema: schema)
        if !indexes.isEmpty {
            sql += "\n\n" + indexes.joined(separator: ";\n") + ";"
        }
        return sql
    }

    /// Column descriptions ride only here: ``createTable(_:schema:)`` keeps the shape an older app
    /// already sends.
    static func createTableStatements(_ definition: PluginCreateTableDefinition, schema: String) -> [String]? {
        guard let createTable = createTableStatement(definition, schema: schema) else { return nil }
        let descriptions = definition.columns.compactMap { column -> String? in
            guard let comment = column.comment, !comment.isEmpty else { return nil }
            return columnDescriptionStatement(
                schema: schema, table: definition.tableName, column: column.name, comment: comment
            )
        }
        return [createTable] + indexStatements(definition, schema: schema) + descriptions
    }

    private static func createTableStatement(_ definition: PluginCreateTableDefinition, schema: String) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let primaryKey = primaryKeyClause(for: definition.indexes)
        let primaryKeyColumns = definition.columns.filter(\.isPrimaryKey)
        let inlinePrimaryKey = primaryKeyColumns.count == 1 ? primaryKey : nil
        var parts: [String] = []
        for column in definition.columns {
            guard let part = columnDefinition(column, inlinePrimaryKey: inlinePrimaryKey) else { return nil }
            parts.append(part)
        }

        if primaryKeyColumns.count > 1 {
            let columns = primaryKeyColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("\(primaryKey) (\(columns))")
        }

        for foreignKey in definition.foreignKeys {
            guard let part = foreignKeyDefinition(foreignKey, defaultSchema: schema) else { return nil }
            parts.append(part)
        }

        let table = qualifiedTable(definition.tableName, schema: schema)
        return "CREATE TABLE \(table) (\n  " + parts.joined(separator: ",\n  ") + "\n)"
    }

    private static func indexStatements(_ definition: PluginCreateTableDefinition, schema: String) -> [String] {
        let table = qualifiedTable(definition.tableName, schema: schema)
        return definition.indexes.map { indexDefinition($0, qualifiedTable: table) }
    }

    // MARK: - Descriptions

    /// SQL Server keeps a comment as the `MS_Description` extended property. Adding one that exists
    /// fails, and so does dropping one that does not, so both are guarded in the same batch.
    static func commentStatement(objectType: String, schema: String, object: String, comment: String?) -> String? {
        let kind: String
        switch objectType.uppercased() {
        case "TABLE": kind = "TABLE"
        case "VIEW": kind = "VIEW"
        default: return nil
        }
        let target = descriptionTarget(schema: schema, kind: kind, object: object, column: nil)
        let exists = "IF EXISTS (SELECT 1 FROM \(descriptionSource(schema: schema, kind: kind, object: object)))"
        guard let comment, !comment.isEmpty else {
            return "\(exists)\n    EXEC sys.sp_dropextendedproperty @name = N'MS_Description', \(target)"
        }
        let value = "@value = \(MSSQLStringLiteral.quoted(comment))"
        return """
            \(exists)
                EXEC sys.sp_updateextendedproperty @name = N'MS_Description', \(value), \(target)
            ELSE
                EXEC sys.sp_addextendedproperty @name = N'MS_Description', \(value), \(target)
            """
    }

    /// The column is new, so there is no description to update yet.
    static func columnDescriptionStatement(schema: String, table: String, column: String, comment: String) -> String {
        let target = descriptionTarget(schema: schema, kind: "TABLE", object: table, column: column)
        return "EXEC sys.sp_addextendedproperty @name = N'MS_Description', "
            + "@value = \(MSSQLStringLiteral.quoted(comment)), \(target)"
    }

    static func descriptionQuery(schema: String, objectKind: String, object: String) -> String {
        let source = descriptionSource(schema: schema, kind: objectKind, object: object)
        return "SELECT CAST(value AS NVARCHAR(MAX)) FROM \(source)"
    }

    private static func descriptionSource(schema: String, kind: String, object: String) -> String {
        "sys.fn_listextendedproperty(N'MS_Description', N'SCHEMA', \(MSSQLStringLiteral.quoted(schema)), "
            + "N'\(kind)', \(MSSQLStringLiteral.quoted(object)), NULL, NULL)"
    }

    private static func descriptionTarget(schema: String, kind: String, object: String, column: String?) -> String {
        var target = "@level0type = N'SCHEMA', @level0name = \(MSSQLStringLiteral.quoted(schema)), "
            + "@level1type = N'\(kind)', @level1name = \(MSSQLStringLiteral.quoted(object))"
        if let column {
            target += ", @level2type = N'COLUMN', @level2name = \(MSSQLStringLiteral.quoted(column))"
        }
        return target
    }

    /// A table holds one clustered index, and a primary key is clustered unless it says otherwise.
    /// So when another index on the table is `CLUSTERED`, as a copied SQL Server table's can be, the
    /// key has to be written `NONCLUSTERED` or the server refuses that index with "Cannot create more
    /// than one clustered index".
    static func primaryKeyClause(for indexes: [PluginIndexDefinition]) -> String {
        let hasClusteredIndex = indexes.contains { $0.indexType?.uppercased() == "CLUSTERED" }
        return hasClusteredIndex ? "PRIMARY KEY NONCLUSTERED" : "PRIMARY KEY"
    }

    // Nil when `refusal(for:)` names a reason. `inlinePrimaryKey` is written after the table's only key column.
    static func columnDefinition(_ column: PluginColumnDefinition, inlinePrimaryKey: String?) -> String? {
        guard MSSQLDefinitionText.isColumnType(column.dataType) else { return nil }
        var definition = "\(quoteIdentifier(column.name)) \(column.dataType)"
        if column.autoIncrement {
            definition += " IDENTITY(1,1)"
        }
        definition += column.isNullable ? " NULL" : " NOT NULL"
        if let defaultValue = column.defaultValue {
            guard let expression = MSSQLDefinitionText.expression(defaultValue) else { return nil }
            definition += " DEFAULT \(expression)"
        }
        if let inlinePrimaryKey, column.isPrimaryKey {
            definition += " \(inlinePrimaryKey)"
        }
        return definition
    }

    static func refusal(
        for column: PluginColumnDefinition,
        writesType: Bool = true,
        writesDefault: Bool = true,
        collation: String? = nil
    ) -> String? {
        if writesType, !MSSQLDefinitionText.isColumnType(column.dataType) {
            return MSSQLDefinitionRefusal.columnType(column.name, column.dataType).reason
        }
        if let collation, !MSSQLDefinitionText.isCollationName(collation) {
            return MSSQLDefinitionRefusal.collation(column.name, collation).reason
        }
        if writesDefault, let value = column.defaultValue, MSSQLDefinitionText.expression(value) == nil {
            return MSSQLDefinitionRefusal.columnDefault(column.name).reason
        }
        return nil
    }

    static func indexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let columns = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        let kind: String
        switch index.indexType?.uppercased() {
        case "CLUSTERED": kind = "CLUSTERED "
        case "NONCLUSTERED": kind = "NONCLUSTERED "
        default: kind = ""
        }
        return "CREATE \(unique)\(kind)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(columns))"
    }

    // The referenced table is schema-qualified: unqualified, it resolves against the login's default schema.
    static func foreignKeyDefinition(_ foreignKey: PluginForeignKeyDefinition, defaultSchema: String) -> String? {
        guard let onDelete = MSSQLDefinitionText.referentialAction(foreignKey.onDelete),
              let onUpdate = MSSQLDefinitionText.referentialAction(foreignKey.onUpdate)
        else { return nil }
        let columns = foreignKey.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let referencedColumns = foreignKey.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let referencedSchema = foreignKey.referencedSchema.flatMap { $0.isEmpty ? nil : $0 } ?? defaultSchema
        let referencedTable = qualifiedTable(foreignKey.referencedTable, schema: referencedSchema)
        let constraint = foreignKey.name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(foreignKey.name)) "
        var definition = "\(constraint)FOREIGN KEY (\(columns)) REFERENCES \(referencedTable)"
        if !referencedColumns.isEmpty {
            definition += " (\(referencedColumns))"
        }
        if onDelete != "NO ACTION" {
            definition += " ON DELETE \(onDelete)"
        }
        if onUpdate != "NO ACTION" {
            definition += " ON UPDATE \(onUpdate)"
        }
        return definition
    }

    static func qualifiedTable(_ table: String, schema: String) -> String {
        "\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
    }

    static func quoteIdentifier(_ name: String) -> String {
        SQLQuoting.identifier(name, quote: .bracket)
    }
}
