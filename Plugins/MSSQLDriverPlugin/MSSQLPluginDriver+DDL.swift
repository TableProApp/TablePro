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
        PluginSQLDDLBuilder.columnDefinition(
            col,
            inlinePrimaryKey: inlinePK,
            quoteIdentifier: quoteIdentifier,
            formatDefaultValue: mssqlDefaultValue,
            postDataTypeSQL: { $0.autoIncrement ? "IDENTITY(1,1)" : nil }
        )
    }

    private func mssqlDefaultValue(_ value: String) -> String {
        PluginSQLDDLBuilder.defaultValue(
            value,
            rawUppercaseValues: ["NULL", "GETDATE()", "NEWID()", "GETUTCDATE()"],
            allowsParenthesizedExpressions: true,
            escapeStringLiteral: escapeStringLiteral
        )
    }

    private func mssqlIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        PluginSQLDDLBuilder.createIndexDefinition(
            index,
            quoteIdentifier: quoteIdentifier,
            tableSQL: qualifiedTable,
            indexKindSQL: { index in
                let unique = index.isUnique ? "UNIQUE " : ""
                if let type = index.indexType?.uppercased(), type == "CLUSTERED" {
                    return "\(unique)CLUSTERED INDEX"
                } else if let type = index.indexType?.uppercased(), type == "NONCLUSTERED" {
                    return "\(unique)NONCLUSTERED INDEX"
                }
                return "\(unique)INDEX"
            },
            includeWhereClause: false
        )
    }

    private func mssqlForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        PluginSQLDDLBuilder.foreignKeyDefinition(fk, quoteIdentifier: quoteIdentifier)
    }

    // MARK: - ALTER TABLE DDL

    private func mssqlQualifiedTable(_ table: String) -> String {
        "\(quoteIdentifier(_currentSchema)).\(quoteIdentifier(table))"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        PluginSQLDDLBuilder.alterTableAddColumnDefinition(
            tableSQL: mssqlQualifiedTable(table),
            columnSQL: mssqlColumnDefinition(column, inlinePK: false),
            addKeyword: "ADD"
        )
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = mssqlQualifiedTable(table)
        var stmts: [String] = []
        let needsTypeChange = oldColumn.dataType != newColumn.dataType || oldColumn.isNullable != newColumn.isNullable
        let defaultChanged = oldColumn.defaultValue != newColumn.defaultValue

        // Rename column first so subsequent statements reference the correct name
        if oldColumn.name != newColumn.name {
            let escapedPath = "\(escapeStringLiteral(_currentSchema)).\(escapeStringLiteral(table)).\(escapeStringLiteral(oldColumn.name))"
            stmts.append("EXEC sp_rename '\(escapedPath)', '\(escapeStringLiteral(newColumn.name))', 'COLUMN'")
        }

        let colName = quoteIdentifier(newColumn.name)

        // Drop existing default constraint before ALTER COLUMN or default change
        if (defaultChanged || needsTypeChange) && oldColumn.defaultValue != nil {
            let objectId = escapeStringLiteral("\(_currentSchema).\(table)")
            stmts.append("""
                DECLARE @dfName NVARCHAR(256); \
                SELECT @dfName = dc.name FROM sys.default_constraints dc \
                JOIN sys.columns c ON dc.parent_column_id = c.column_id AND dc.parent_object_id = c.object_id \
                WHERE c.name = '\(escapeStringLiteral(newColumn.name))' \
                AND dc.parent_object_id = OBJECT_ID('\(objectId)'); \
                IF @dfName IS NOT NULL EXEC('ALTER TABLE \(qt) DROP CONSTRAINT [' + @dfName + ']')
                """)
        }

        if needsTypeChange {
            let nullable = newColumn.isNullable ? "NULL" : "NOT NULL"
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) \(newColumn.dataType) \(nullable)")
        }

        if defaultChanged, let defaultValue = newColumn.defaultValue {
            stmts.append("ALTER TABLE \(qt) ADD DEFAULT \(mssqlDefaultValue(defaultValue)) FOR \(colName)")
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        PluginSQLDDLBuilder.alterTableDropColumnDefinition(
            tableSQL: mssqlQualifiedTable(table),
            columnName: columnName,
            quoteIdentifier: quoteIdentifier
        )
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        mssqlIndexDefinition(index, qualifiedTable: mssqlQualifiedTable(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        PluginSQLDDLBuilder.dropIndexDefinition(
            indexName: indexName,
            quoteIdentifier: quoteIdentifier,
            tableSQL: mssqlQualifiedTable(table)
        )
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) ADD \(mssqlForeignKeyDefinition(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        PluginSQLDDLBuilder.alterTableDropObjectDefinition(
            tableSQL: mssqlQualifiedTable(table),
            objectKind: "CONSTRAINT",
            objectName: constraintName,
            quoteIdentifier: quoteIdentifier
        )
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        PluginSQLDDLBuilder.modifyPrimaryKeyDefinitions(
            tableSQL: mssqlQualifiedTable(table),
            oldColumns: oldColumns,
            newColumns: newColumns,
            constraintName: constraintName,
            quoteIdentifier: quoteIdentifier,
            addConstraintNameSQL: constraintName.map { quoteIdentifier($0) } ?? quoteIdentifier("PK_\(table)")
        )
    }

}
