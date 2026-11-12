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
        MSSQLTableDefinitionSQL.createTable(definition, schema: currentSchemaName)
    }

    func generateCreateTableStatements(definition: PluginCreateTableDefinition) -> [String]? {
        MSSQLTableDefinitionSQL.createTableStatements(definition, schema: currentSchemaName)
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        MSSQLTableDefinitionSQL.commentStatement(
            objectType: objectType, schema: effectiveSchema(schema), object: name, comment: comment
        )
    }

    // MARK: - ALTER TABLE DDL

    private func mssqlQualifiedTable(_ table: String) -> String {
        MSSQLTableDefinitionSQL.qualifiedTable(table, schema: currentSchemaName)
    }

    func schemaOperationRefusal(_ operation: PluginSchemaOperation) -> String? {
        switch operation {
        case .addColumn(let column):
            return MSSQLTableDefinitionSQL.refusal(for: column)
        case .modifyColumn(let old, let new):
            let alteration = Self.columnAlteration(from: old, to: new)
            return MSSQLTableDefinitionSQL.refusal(
                for: new,
                writesType: alteration.writesType,
                writesDefault: alteration.writesType || old.defaultValue != new.defaultValue,
                collation: alteration.writesType ? alteration.collation : nil
            )
        default:
            return nil
        }
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        guard let columnSQL = MSSQLTableDefinitionSQL.columnDefinition(column, inlinePrimaryKey: nil) else { return nil }
        let addColumn = "ALTER TABLE \(mssqlQualifiedTable(table)) ADD \(columnSQL)"
        guard let comment = column.comment, !comment.isEmpty else { return addColumn }
        let description = MSSQLTableDefinitionSQL.columnDescriptionStatement(
            schema: currentSchemaName, table: table, column: column.name, comment: comment
        )
        return addColumn + ";\n" + description
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = mssqlQualifiedTable(table)
        var stmts: [String] = []
        let alteration = Self.columnAlteration(from: oldColumn, to: newColumn)
        let needsTypeChange = alteration.writesType
        let defaultChanged = oldColumn.defaultValue != newColumn.defaultValue

        // Rename column first so subsequent statements reference the correct name
        if oldColumn.name != newColumn.name {
            let path = MSSQLStringLiteral.quoted("\(currentSchemaName).\(table).\(oldColumn.name)")
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
            guard let alter = try? MSSQLSchemaQueries.alterColumnStatement(
                qualifiedTable: qt,
                column: newColumn.name,
                type: newColumn.dataType,
                collation: alteration.collation,
                isNullable: newColumn.isNullable
            ) else { return nil }
            stmts.append(alter)
        }

        // The re-add mirrors the drop above. A type or nullability change drops the constraint too,
        // so re-adding only on a default change left a column the user never touched with no
        // default at all, and every later INSERT that omitted it failed.
        if defaultChanged || needsTypeChange, let defaultValue = newColumn.defaultValue {
            guard let expression = MSSQLDefinitionText.expression(defaultValue) else { return nil }
            stmts.append("ALTER TABLE \(qt) ADD DEFAULT \(expression) FOR \(colName)")
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    // ALTER COLUMN also runs when only the collation changes, since it is the one statement that sets it.
    private static func columnAlteration(
        from old: PluginColumnDefinition,
        to new: PluginColumnDefinition
    ) -> (writesType: Bool, collation: String?) {
        let collation = MSSQLSchemaQueries.alterColumnCollation(
            type: new.dataType, collation: new.collation, previous: old.collation
        )
        let changesCollation = collation.map { $0 != old.collation } ?? false
        return (old.dataType != new.dataType || old.isNullable != new.isNullable || changesCollation, collation)
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        MSSQLTableDefinitionSQL.indexDefinition(index, qualifiedTable: mssqlQualifiedTable(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(indexName)) ON \(mssqlQualifiedTable(table))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        MSSQLTableDefinitionSQL.foreignKeyDefinition(fk, defaultSchema: currentSchemaName).map {
            "ALTER TABLE \(mssqlQualifiedTable(table)) ADD \($0)"
        }
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(mssqlQualifiedTable(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        let expression = constraint.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let check = "(" + expression + ")"
        guard !expression.isEmpty, !constraint.name.isEmpty, MSSQLDefinitionText.isParenthesizedExpression(check) else {
            return nil
        }
        return "ALTER TABLE \(mssqlQualifiedTable(table)) ADD CONSTRAINT "
            + "\(quoteIdentifier(constraint.name)) CHECK \(check)"
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
