//
//  CreateTableStatementComposer.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct CreateTableStatements {
    let statements: [String]
    let issues: [SchemaDraftIssue]
    /// The name the statement actually creates, trimmed. The draft's own field may carry
    /// surrounding whitespace, and opening the tab under that text loads a table nobody made.
    let tableName: String?

    var preview: String {
        statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
    }
}

/// One statement per element, because a driver is only obliged to run one statement per
/// `execute(query:)`: SQLite prepares with a nil tail, so anything after the first semicolon never runs.
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
        issues += columnRefusals.map { SchemaDraftIssue(tab: .columns, row: nil, message: $0) }
        var refusedIndexRows: Set<Int> = []
        for (row, index) in plan.indexes.enumerated() {
            guard let reason = driver.schemaOperationRefusal(.addIndex(index)) else { continue }
            refusedIndexRows.insert(row)
            issues.append(SchemaDraftIssue(tab: .indexes, row: row, message: reason))
        }
        guard columnRefusals.isEmpty else {
            return CreateTableStatements(statements: [], issues: issues, tableName: definition.tableName)
        }

        guard let createTable = driver.generateCreateTableStatements(definition: definition), !createTable.isEmpty else {
            issues.append(SchemaDraftIssue(
                tab: .columns, row: nil,
                message: String(localized: "This database cannot create a table from the visual editor.")
            ))
            return CreateTableStatements(statements: [], issues: issues, tableName: definition.tableName)
        }

        var statements = createTable
        for (row, index) in plan.indexes.enumerated() where !refusedIndexRows.contains(row) {
            guard let sql = driver.generateAddIndexSQL(table: definition.tableName, index: index) else {
                issues.append(SchemaDraftIssue(
                    tab: .indexes, row: row,
                    message: String(localized: "Create Table cannot add an index on this database.")
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
                    tab: .columns, row: nil,
                    message: String(localized: "This database cannot store a table comment.")
                ))
            }
        }

        return CreateTableStatements(statements: statements, issues: issues, tableName: definition.tableName)
    }
}
