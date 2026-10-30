//
//  CreateTableStatementComposer.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct CreateTableStatements {
    let statements: [String]
    let issues: [SchemaDraftIssue]
    // Trimmed: opening a tab under the draft's untrimmed text loads a table nobody made.
    let tableName: String?

    var preview: String {
        statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
    }
}

// One statement per element: a driver need only run one per execute, and SQLite drops anything after the first.
@MainActor
enum CreateTableStatementComposer {
    static func compose(
        plan: CreateTablePlan,
        driver: any PluginDatabaseDriver,
        schema: String?
    ) -> CreateTableStatements {
        guard let definition = plan.definition else {
            return CreateTableStatements(statements: [], issues: plan.issues, tableName: nil)
        }

        var issues = plan.issues
        let columnRefusals = definition.columns.compactMap { driver.schemaOperationRefusal(.addColumn($0)) }
        issues += columnRefusals.map { SchemaDraftIssue(section: .columns, row: nil, message: $0) }
        var refusedIndexes: Set<Int> = []
        for (position, index) in plan.indexes.enumerated() {
            guard let reason = driver.schemaOperationRefusal(.addIndex(index)) else { continue }
            refusedIndexes.insert(position)
            issues.append(SchemaDraftIssue(section: .indexes, row: plan.indexRow(at: position), message: reason))
        }
        guard columnRefusals.isEmpty else {
            return CreateTableStatements(statements: [], issues: issues, tableName: definition.tableName)
        }

        guard let createTable = driver.generateCreateTableStatements(definition: definition), !createTable.isEmpty else {
            issues.append(SchemaDraftIssue(
                section: .columns, row: nil,
                message: String(localized: "This database cannot create a table from the visual editor.")
            ))
            return CreateTableStatements(statements: [], issues: issues, tableName: definition.tableName)
        }

        var statements = createTable
        for (position, index) in plan.indexes.enumerated() where !refusedIndexes.contains(position) {
            guard let sql = driver.generateAddIndexSQL(table: definition.tableName, index: index) else {
                issues.append(SchemaDraftIssue(
                    section: .indexes, row: plan.indexRow(at: position),
                    message: String(localized: "Create Table cannot add an index on this database.")
                ))
                continue
            }
            statements.append(sql)
        }

        for (position, constraint) in plan.checkConstraints.enumerated() {
            guard let sql = driver.generateAddCheckConstraintSQL(table: definition.tableName, constraint: constraint) else {
                issues.append(SchemaDraftIssue(
                    section: .checkConstraints, row: plan.checkConstraintRow(at: position),
                    message: String(localized: "Create Table cannot add a check constraint on this database.")
                ))
                continue
            }
            statements.append(sql)
        }

        if let comment = plan.tableComment {
            if let sql = driver.objectCommentStatement(
                name: definition.tableName,
                objectType: TableInfo.TableType.table.rawValue,
                schema: schema,
                comment: comment
            ) {
                statements.append(sql)
            } else {
                issues.append(SchemaDraftIssue(
                    section: .columns, row: nil,
                    message: String(localized: "This database cannot store a table comment.")
                ))
            }
        }

        return CreateTableStatements(statements: statements, issues: issues, tableName: definition.tableName)
    }
}
