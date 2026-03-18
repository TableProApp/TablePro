//
//  SchemaStatementGenerator.swift
//  TablePro
//
//  Generates ALTER TABLE SQL statements from schema changes.
//  Delegates all DDL generation to the plugin driver.
//

import Foundation
import TableProPluginKit

/// A schema SQL statement with metadata
struct SchemaStatement {
    let sql: String
    let description: String
    let isDestructive: Bool
}

/// Generates SQL statements for schema modifications by delegating to the plugin driver.
struct SchemaStatementGenerator {
    private let tableName: String

    /// Actual primary key constraint name (queried from database).
    /// Passed to plugin for databases that require it (e.g. PostgreSQL DROP CONSTRAINT).
    private let primaryKeyConstraintName: String?

    /// Plugin driver for database-specific DDL generation.
    private let pluginDriver: any PluginDatabaseDriver

    init(
        tableName: String,
        primaryKeyConstraintName: String? = nil,
        pluginDriver: any PluginDatabaseDriver
    ) {
        self.tableName = tableName
        self.primaryKeyConstraintName = primaryKeyConstraintName
        self.pluginDriver = pluginDriver
    }

    /// Generate all SQL statements from schema changes
    func generate(changes: [SchemaChange]) throws -> [SchemaStatement] {
        var statements: [SchemaStatement] = []

        let sortedChanges = sortByDependency(changes)

        for change in sortedChanges {
            guard let stmt = try generateStatement(for: change) else {
                throw NSError(
                    domain: "SchemaStatementGenerator",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Unsupported schema operation: \(change.description)")]
                )
            }
            let sql = stmt.sql.hasSuffix(";") ? stmt.sql : stmt.sql + ";"
            statements.append(SchemaStatement(sql: sql, description: stmt.description, isDestructive: stmt.isDestructive))
        }

        return statements
    }

    // MARK: - Dependency Ordering

    private func sortByDependency(_ changes: [SchemaChange]) -> [SchemaChange] {
        // Execution order for safety:
        // 1. Drop foreign keys first (includes modify FK, which requires drop+recreate)
        // 2. Drop indexes (includes modify index, which requires drop+recreate)
        // 3. Drop/modify columns
        // 4. Add columns
        // 5. Modify primary key
        // 6. Add indexes
        // 7. Add foreign keys

        var fkDeletes: [SchemaChange] = []
        var indexDeletes: [SchemaChange] = []
        var columnDeletes: [SchemaChange] = []
        var columnModifies: [SchemaChange] = []
        var columnAdds: [SchemaChange] = []
        var pkChanges: [SchemaChange] = []
        var indexAdds: [SchemaChange] = []
        var fkAdds: [SchemaChange] = []

        for change in changes {
            switch change {
            case .deleteForeignKey, .modifyForeignKey:
                fkDeletes.append(change)
            case .deleteIndex, .modifyIndex:
                indexDeletes.append(change)
            case .deleteColumn:
                columnDeletes.append(change)
            case .modifyColumn:
                columnModifies.append(change)
            case .addColumn:
                columnAdds.append(change)
            case .modifyPrimaryKey:
                pkChanges.append(change)
            case .addIndex:
                indexAdds.append(change)
            case .addForeignKey:
                fkAdds.append(change)
            }
        }

        return fkDeletes + indexDeletes + columnDeletes + columnModifies + columnAdds + pkChanges + indexAdds + fkAdds
    }

    // MARK: - Statement Generation

    private func generateStatement(for change: SchemaChange) throws -> SchemaStatement? {
        switch change {
        case .addColumn(let column):
            return generateAddColumn(column)
        case .modifyColumn(let old, let new):
            return generateModifyColumn(old: old, new: new)
        case .deleteColumn(let column):
            return generateDeleteColumn(column)
        case .addIndex(let index):
            return generateAddIndex(index)
        case .modifyIndex(let old, let new):
            return generateModifyIndex(old: old, new: new)
        case .deleteIndex(let index):
            return generateDeleteIndex(index)
        case .addForeignKey(let fk):
            return generateAddForeignKey(fk)
        case .modifyForeignKey(let old, let new):
            return generateModifyForeignKey(old: old, new: new)
        case .deleteForeignKey(let fk):
            return generateDeleteForeignKey(fk)
        case .modifyPrimaryKey(let old, let new):
            return generateModifyPrimaryKey(old: old, new: new)
        }
    }

    // MARK: - Column Operations

    private func generateAddColumn(_ column: EditableColumnDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateAddColumnSQL(table: tableName, column: toPluginColumnDefinition(column)) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Add column '\(column.name)'", isDestructive: false)
    }

    private func generateModifyColumn(old: EditableColumnDefinition, new: EditableColumnDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateModifyColumnSQL(
            table: tableName,
            oldColumn: toPluginColumnDefinition(old),
            newColumn: toPluginColumnDefinition(new)
        ) else {
            return nil
        }
        return SchemaStatement(
            sql: sql,
            description: "Modify column '\(old.name)' to '\(new.name)'",
            isDestructive: old.dataType != new.dataType
        )
    }

    private func generateDeleteColumn(_ column: EditableColumnDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateDropColumnSQL(table: tableName, columnName: column.name) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Drop column '\(column.name)'", isDestructive: true)
    }

    // MARK: - Index Operations

    private func generateAddIndex(_ index: EditableIndexDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateAddIndexSQL(table: tableName, index: toPluginIndexDefinition(index)) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Add index '\(index.name)'", isDestructive: false)
    }

    private func generateModifyIndex(old: EditableIndexDefinition, new: EditableIndexDefinition) -> SchemaStatement? {
        guard let dropSql = pluginDriver.generateDropIndexSQL(table: tableName, indexName: old.name),
              let addSql = pluginDriver.generateAddIndexSQL(table: tableName, index: toPluginIndexDefinition(new)) else {
            return nil
        }
        let sql = "\(dropSql);\n\(addSql);"
        return SchemaStatement(
            sql: sql,
            description: "Modify index '\(old.name)' to '\(new.name)'",
            isDestructive: false
        )
    }

    private func generateDeleteIndex(_ index: EditableIndexDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateDropIndexSQL(table: tableName, indexName: index.name) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Drop index '\(index.name)'", isDestructive: false)
    }

    // MARK: - Foreign Key Operations

    private func generateAddForeignKey(_ fk: EditableForeignKeyDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateAddForeignKeySQL(
            table: tableName,
            fk: toPluginForeignKeyDefinition(fk)
        ) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Add foreign key '\(fk.name)'", isDestructive: false)
    }

    private func generateModifyForeignKey(old: EditableForeignKeyDefinition, new: EditableForeignKeyDefinition) -> SchemaStatement? {
        guard let dropSql = pluginDriver.generateDropForeignKeySQL(table: tableName, constraintName: old.name),
              let addSql = pluginDriver.generateAddForeignKeySQL(table: tableName, fk: toPluginForeignKeyDefinition(new)) else {
            return nil
        }
        let sql = "\(dropSql);\n\(addSql);"
        return SchemaStatement(
            sql: sql,
            description: "Modify foreign key '\(old.name)' to '\(new.name)'",
            isDestructive: false
        )
    }

    private func generateDeleteForeignKey(_ fk: EditableForeignKeyDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateDropForeignKeySQL(table: tableName, constraintName: fk.name) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Drop foreign key '\(fk.name)'", isDestructive: false)
    }

    // MARK: - Primary Key Operations

    private func generateModifyPrimaryKey(old: [String], new: [String]) -> SchemaStatement? {
        guard let sqls = pluginDriver.generateModifyPrimaryKeySQL(
            table: tableName, oldColumns: old, newColumns: new, constraintName: primaryKeyConstraintName
        ) else {
            return nil
        }
        let joined = sqls.joined(separator: ";\n")
        return SchemaStatement(
            sql: joined,
            description: "Modify primary key from [\(old.joined(separator: ", "))] to [\(new.joined(separator: ", "))]",
            isDestructive: true
        )
    }

    // MARK: - Plugin Type Converters

    private func toPluginColumnDefinition(_ col: EditableColumnDefinition) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: col.name,
            dataType: col.dataType,
            isNullable: col.isNullable,
            defaultValue: col.defaultValue,
            isPrimaryKey: col.isPrimaryKey,
            autoIncrement: col.autoIncrement,
            comment: col.comment,
            unsigned: col.unsigned,
            onUpdate: col.onUpdate
        )
    }

    private func toPluginIndexDefinition(_ index: EditableIndexDefinition) -> PluginIndexDefinition {
        PluginIndexDefinition(
            name: index.name,
            columns: index.columns,
            isUnique: index.isUnique,
            indexType: index.type.rawValue
        )
    }

    private func toPluginForeignKeyDefinition(_ fk: EditableForeignKeyDefinition) -> PluginForeignKeyDefinition {
        PluginForeignKeyDefinition(
            name: fk.name,
            columns: fk.columns,
            referencedTable: fk.referencedTable,
            referencedColumns: fk.referencedColumns,
            onDelete: fk.onDelete.rawValue,
            onUpdate: fk.onUpdate.rawValue
        )
    }
}
