//
//  MSSQLPluginDriver+DDL.swift
//  MSSQLDriverPlugin
//

import Foundation
import os
import TableProMSSQLCore
import TableProPluginKit

extension MSSQLPluginDriver {
    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let schema = _currentSchema
        let qualifiedTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(definition.tableName))"
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { mssqlColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(mssqlForeignKeyDefinition(fk))
        }

        var sql = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        var indexStatements: [String] = []
        for index in definition.indexes {
            indexStatements.append(mssqlIndexDefinition(index, qualifiedTable: qualifiedTable))
        }
        if !indexStatements.isEmpty {
            sql += "\n\n" + indexStatements.joined(separator: ";\n") + ";"
        }

        return sql
    }

    private func mssqlColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        var def = "\(quoteIdentifier(col.name)) \(col.dataType)"
        if col.autoIncrement {
            def += " IDENTITY(1,1)"
        }
        if col.isNullable {
            def += " NULL"
        } else {
            def += " NOT NULL"
        }
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(defaultValue)"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    private func mssqlIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        var def = "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
        if let type = index.indexType?.uppercased(), type == "CLUSTERED" {
            def = "CREATE \(unique)CLUSTERED INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
        } else if let type = index.indexType?.uppercased(), type == "NONCLUSTERED" {
            def = "CREATE \(unique)NONCLUSTERED INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
        }
        return def
    }

    /// The referenced table is schema-qualified. An unqualified name resolves against the caller's
    /// own default schema rather than the schema the table is being created in, so a foreign key
    /// pointing at `sales.orders` used to be created against whatever `orders` that login could see,
    /// or to fail with nothing naming the schema as the reason.
    private func mssqlForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refSchema = fk.referencedSchema.flatMap { $0.isEmpty ? nil : $0 } ?? _currentSchema
        let refTable = "\(quoteIdentifier(refSchema)).\(quoteIdentifier(fk.referencedTable))"
        let constraint = fk.name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(fk.name)) "
        var def = "\(constraint)FOREIGN KEY (\(cols)) REFERENCES \(refTable)"
        if !refCols.isEmpty {
            def += " (\(refCols))"
        }
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }

    // MARK: - ALTER TABLE DDL

    private func mssqlQualifiedTable(_ table: String) -> String {
        "\(quoteIdentifier(_currentSchema)).\(quoteIdentifier(table))"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) ADD \(mssqlColumnDefinition(column, inlinePK: false))"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = mssqlQualifiedTable(table)
        var stmts: [String] = []
        let needsTypeChange = oldColumn.dataType != newColumn.dataType || oldColumn.isNullable != newColumn.isNullable
        let defaultChanged = oldColumn.defaultValue != newColumn.defaultValue

        // Rename column first so subsequent statements reference the correct name
        if oldColumn.name != newColumn.name {
            let path = MSSQLStringLiteral.quoted("\(_currentSchema).\(table).\(oldColumn.name)")
            let renamed = MSSQLStringLiteral.quoted(newColumn.name)
            stmts.append("EXEC sp_rename \(path), \(renamed), 'COLUMN'")
        }

        let colName = quoteIdentifier(newColumn.name)

        // Drop existing default constraint before ALTER COLUMN or default change
        if (defaultChanged || needsTypeChange) && oldColumn.defaultValue != nil {
            let objectLiteral = MSSQLStringLiteral.quoted(qt)
            let dropPrefix = MSSQLStringLiteral.quoted("ALTER TABLE \(qt) DROP CONSTRAINT ")
            stmts.append("""
                DECLARE @dfName NVARCHAR(256); \
                SELECT @dfName = dc.name FROM sys.default_constraints dc \
                JOIN sys.columns c ON dc.parent_column_id = c.column_id AND dc.parent_object_id = c.object_id \
                WHERE c.name = \(MSSQLStringLiteral.quoted(newColumn.name)) \
                AND dc.parent_object_id = OBJECT_ID(\(objectLiteral)); \
                IF @dfName IS NOT NULL BEGIN DECLARE @dropSql NVARCHAR(MAX) = \(dropPrefix) + QUOTENAME(@dfName); \
                EXEC(@dropSql); END
                """)
        }

        if needsTypeChange {
            let nullable = newColumn.isNullable ? "NULL" : "NOT NULL"
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) \(newColumn.dataType) \(nullable)")
        }

        // The re-add mirrors the drop above. A type or nullability change drops the constraint too,
        // so re-adding only on a default change left a column the user never touched with no
        // default at all, and every later INSERT that omitted it failed.
        if defaultChanged || needsTypeChange, let defaultValue = newColumn.defaultValue {
            stmts.append("ALTER TABLE \(qt) ADD DEFAULT \(defaultValue) FOR \(colName)")
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        mssqlIndexDefinition(index, qualifiedTable: mssqlQualifiedTable(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(indexName)) ON \(mssqlQualifiedTable(table))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) ADD \(mssqlForeignKeyDefinition(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        let expression = constraint.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !constraint.name.isEmpty else { return nil }
        return "ALTER TABLE \(mssqlQualifiedTable(table)) ADD CONSTRAINT "
            + "\(quoteIdentifier(constraint.name)) CHECK (\(expression))"
    }

    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? {
        guard !constraintName.isEmpty else { return nil }
        return "ALTER TABLE \(mssqlQualifiedTable(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    /// `sys.check_constraints.parent_column_id` is 0 for a multi-column check, so the columns come
    /// from `sys.sql_expression_dependencies`, which lists them for both shapes.
    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        let targetLiteral = MSSQLStringLiteral.quoted(mssqlQualifiedTable(table))
        let query = """
            SELECT cc.name, cc.definition, cc.is_not_trusted,
                   COL_NAME(d.referenced_id, d.referenced_minor_id)
            FROM sys.check_constraints cc
            LEFT JOIN sys.sql_expression_dependencies d
                ON d.referencing_id = cc.object_id AND d.referenced_minor_id > 0
            WHERE cc.parent_object_id = OBJECT_ID(\(targetLiteral))
            ORDER BY cc.name
            """
        let result = try await execute(query: query)
        // One row per referenced column rather than a FOR XML aggregate, which entity-escapes
        // &, < and > and cannot be split safely when a name contains a comma.
        var ordered: [String] = []
        var byName: [String: PluginCheckConstraintInfo] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText,
                  let definition = row[safe: 1]?.asText else { continue }
            let existing = byName[name]
            if existing == nil { ordered.append(name) }
            var columns = existing?.columns ?? []
            if let column = row[safe: 3]?.asText?.nilIfEmpty { columns.append(column) }
            byName[name] = PluginCheckConstraintInfo(
                name: name,
                expression: MSSQLCheckConstraintDefinition.expression(fromDefinition: definition),
                columns: columns,
                isValidated: row[safe: 2]?.asText != "1"
            )
        }
        return ordered.compactMap { byName[$0] }
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        let qt = mssqlQualifiedTable(table)
        var stmts: [String] = []
        if !oldColumns.isEmpty {
            let name = constraintName.map { quoteIdentifier($0) } ?? "/* unknown constraint */"
            stmts.append("ALTER TABLE \(qt) DROP CONSTRAINT \(name)")
        }
        if !newColumns.isEmpty {
            let cols = newColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
            let pkName = constraintName.map { quoteIdentifier($0) } ?? quoteIdentifier("PK_\(table)")
            stmts.append("ALTER TABLE \(qt) ADD CONSTRAINT \(pkName) PRIMARY KEY (\(cols))")
        }
        return stmts.isEmpty ? nil : stmts
    }

}
