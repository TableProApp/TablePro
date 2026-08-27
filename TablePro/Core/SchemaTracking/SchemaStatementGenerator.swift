//
//  SchemaStatementGenerator.swift
//  TablePro
//
//  Generates ALTER TABLE SQL statements from schema changes.
//  Delegates all DDL generation to the plugin driver.
//

import Foundation
import TableProPluginKit

/// A schema SQL statement with metadata.
/// `carriesCredentials` marks statements whose SQL embeds a plaintext password, so they are never
/// written to the on-disk query history.
struct SchemaStatement {
    let sql: String
    let description: String
    let isDestructive: Bool
    var carriesCredentials = false
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
            let stmts = try generateStatements(for: change)
            guard !stmts.isEmpty else {
                throw NSError(
                    domain: "SchemaStatementGenerator",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "Unsupported schema operation: %@"), change.description)]
                )
            }
            for stmt in stmts {
                let sql = stmt.sql.hasSuffix(";") ? stmt.sql : stmt.sql + ";"
                statements.append(SchemaStatement(sql: sql, description: stmt.description, isDestructive: stmt.isDestructive))
            }
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

        var constraintDeletes: [SchemaChange] = []
        var constraintModifies: [SchemaChange] = []
        var fkDeletes: [SchemaChange] = []
        var indexDeletes: [SchemaChange] = []
        var columnDeletes: [SchemaChange] = []
        var columnModifies: [SchemaChange] = []
        var columnAdds: [SchemaChange] = []
        var pkChanges: [SchemaChange] = []
        var indexAdds: [SchemaChange] = []
        var fkAdds: [SchemaChange] = []
        var constraintAdds: [SchemaChange] = []

        for change in changes {
            switch change {
            case .deleteCheckConstraint:
                constraintDeletes.append(change)
            case .modifyCheckConstraint(let old, let new):
                // An expression change is a drop and a re-add, and the two halves belong on
                // opposite sides of the column work: the replacement may reference a column this
                // same save adds, and the old one may reference a column it drops. Keeping them
                // contiguous fails whenever either is true. A rename is one statement and stays put.
                if old.expression == new.expression {
                    constraintModifies.append(change)
                } else {
                    constraintDeletes.append(.deleteCheckConstraint(old))
                    constraintAdds.append(.addCheckConstraint(new))
                }
            case .addCheckConstraint:
                constraintAdds.append(change)
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

        return constraintDeletes + constraintModifies + fkDeletes + indexDeletes + columnDeletes
            + columnModifies + columnAdds + pkChanges + indexAdds + fkAdds + constraintAdds
    }

    // MARK: - Statement Generation

    private func generateStatements(for change: SchemaChange) throws -> [SchemaStatement] {
        switch change {
        case .addColumn(let column):
            return generateAddColumn(column).map { [$0] } ?? []
        case .modifyColumn(let old, let new):
            return generateModifyColumn(old: old, new: new).map { [$0] } ?? []
        case .deleteColumn(let column):
            return generateDeleteColumn(column).map { [$0] } ?? []
        case .addIndex(let index):
            return generateAddIndex(index).map { [$0] } ?? []
        case .modifyIndex(let old, let new):
            return generateModifyIndex(old: old, new: new)
        case .deleteIndex(let index):
            return generateDeleteIndex(index).map { [$0] } ?? []
        case .addForeignKey(let fk):
            return generateAddForeignKey(fk).map { [$0] } ?? []
        case .modifyForeignKey(let old, let new):
            return generateModifyForeignKey(old: old, new: new)
        case .deleteForeignKey(let fk):
            return generateDeleteForeignKey(fk).map { [$0] } ?? []
        case .modifyPrimaryKey(let old, let new):
            return generateModifyPrimaryKey(old: old, new: new)
        case .addCheckConstraint(let constraint):
            return generateAddCheckConstraint(constraint).map { [$0] } ?? []
        case .modifyCheckConstraint(let old, let new):
            return generateModifyCheckConstraint(old: old, new: new)
        case .deleteCheckConstraint(let constraint):
            return generateDeleteCheckConstraint(constraint).map { [$0] } ?? []
        }
    }

    // MARK: - Column Operations

    private func generateAddColumn(_ column: EditableColumnDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateAddColumnSQL(table: tableName, column: column.toPlugin()) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Add column '\(column.name)'", isDestructive: false)
    }

    private func generateModifyColumn(old: EditableColumnDefinition, new: EditableColumnDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateModifyColumnSQL(
            table: tableName,
            oldColumn: old.toPlugin(),
            newColumn: new.toPlugin()
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
        guard let sql = pluginDriver.generateAddIndexSQL(table: tableName, index: index.toPlugin()) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Add index '\(index.name)'", isDestructive: false)
    }

    private func generateModifyIndex(old: EditableIndexDefinition, new: EditableIndexDefinition) -> [SchemaStatement] {
        guard let dropSql = pluginDriver.generateDropIndexSQL(table: tableName, indexName: old.name),
              let addSql = pluginDriver.generateAddIndexSQL(table: tableName, index: new.toPlugin()) else {
            return []
        }
        return [
            SchemaStatement(sql: dropSql, description: "Drop index '\(old.name)'", isDestructive: false),
            SchemaStatement(sql: addSql, description: "Add index '\(new.name)'", isDestructive: false)
        ]
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
            fk: fk.toPlugin()
        ) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Add foreign key '\(fk.name)'", isDestructive: false)
    }

    private func generateModifyForeignKey(old: EditableForeignKeyDefinition, new: EditableForeignKeyDefinition) -> [SchemaStatement] {
        guard let dropSql = pluginDriver.generateDropForeignKeySQL(table: tableName, constraintName: old.name),
              let addSql = pluginDriver.generateAddForeignKeySQL(table: tableName, fk: new.toPlugin()) else {
            return []
        }
        return [
            SchemaStatement(sql: dropSql, description: "Drop foreign key '\(old.name)'", isDestructive: false),
            SchemaStatement(sql: addSql, description: "Add foreign key '\(new.name)'", isDestructive: false)
        ]
    }

    private func generateDeleteForeignKey(_ fk: EditableForeignKeyDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateDropForeignKeySQL(table: tableName, constraintName: fk.name) else {
            return nil
        }
        return SchemaStatement(sql: sql, description: "Drop foreign key '\(fk.name)'", isDestructive: false)
    }

    // MARK: - Check Constraint Operations

    private func generateAddCheckConstraint(_ constraint: EditableCheckConstraintDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateAddCheckConstraintSQL(
            table: tableName, constraint: constraint.toPlugin()
        ) else {
            return nil
        }
        return SchemaStatement(
            sql: sql, description: "Add check constraint '\(constraint.name)'", isDestructive: false
        )
    }

    /// A pure rename is one cheap statement on every engine that offers it, so it never becomes a
    /// drop and re-add: re-adding rescans the whole table and fails outright if any existing row
    /// violates the constraint, which is the wrong outcome for changing a name.
    private func generateModifyCheckConstraint(
        old: EditableCheckConstraintDefinition,
        new: EditableCheckConstraintDefinition
    ) -> [SchemaStatement] {
        if old.expression == new.expression, old.name != new.name,
           let renameSql = pluginDriver.generateRenameCheckConstraintSQL(
               table: tableName, from: old.name, to: new.name
           ) {
            return [SchemaStatement(
                sql: renameSql,
                description: "Rename check constraint '\(old.name)' to '\(new.name)'",
                isDestructive: false
            )]
        }

        guard let dropSql = pluginDriver.generateDropCheckConstraintSQL(table: tableName, constraintName: old.name),
              let addSql = pluginDriver.generateAddCheckConstraintSQL(table: tableName, constraint: new.toPlugin())
        else {
            return []
        }
        return [
            SchemaStatement(
                sql: dropSql, description: "Drop check constraint '\(old.name)'", isDestructive: true
            ),
            SchemaStatement(
                sql: addSql, description: "Add check constraint '\(new.name)'", isDestructive: false
            )
        ]
    }

    private func generateDeleteCheckConstraint(_ constraint: EditableCheckConstraintDefinition) -> SchemaStatement? {
        guard let sql = pluginDriver.generateDropCheckConstraintSQL(
            table: tableName, constraintName: constraint.name
        ) else {
            return nil
        }
        return SchemaStatement(
            sql: sql, description: "Drop check constraint '\(constraint.name)'", isDestructive: true
        )
    }

    // MARK: - Primary Key Operations

    private func generateModifyPrimaryKey(old: [String], new: [String]) -> [SchemaStatement] {
        guard let sqls = pluginDriver.generateModifyPrimaryKeySQL(
            table: tableName, oldColumns: old, newColumns: new, constraintName: primaryKeyConstraintName
        ) else {
            return []
        }
        return sqls.map { sql in
            SchemaStatement(
                sql: sql,
                description: "Modify primary key from [\(old.joined(separator: ", "))] to [\(new.joined(separator: ", "))]",
                isDestructive: true
            )
        }
    }
}
