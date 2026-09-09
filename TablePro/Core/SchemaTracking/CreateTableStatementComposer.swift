//
//  CreateTableStatementComposer.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The statements a Create Table draft runs, in order, and anything the driver could not spell.
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

/// Asks the driver for the statements a plan needs, one per object.
///
/// The `CREATE TABLE` and each `CREATE INDEX` are separate statements because a driver is only
/// obliged to run one statement per `execute(query:)`, and SQLite's prepares with a nil tail and
/// steps once, so anything after the first semicolon is compiled by nobody. The existing-table path
/// (`SchemaStatementGenerator`) already works this way; this is the same shape for the create path.
@MainActor
enum CreateTableStatementComposer {
    static func compose(
        plan: CreateTablePlan,
        driver: any PluginDatabaseDriver
    ) -> CreateTableStatements {
        guard let definition = plan.definition else {
            return CreateTableStatements(statements: [], issues: plan.issues, tableName: nil)
        }

        var issues = plan.issues
        guard let createTable = driver.generateCreateTableSQL(definition: definition) else {
            issues.append(SchemaDraftIssue(
                tab: .columns, row: nil,
                message: String(localized: "This database cannot create a table from the visual editor.")
            ))
            return CreateTableStatements(statements: [], issues: issues, tableName: definition.tableName)
        }

        var statements = [createTable]
        for (row, index) in plan.indexes.enumerated() {
            guard let sql = driver.generateAddIndexSQL(table: definition.tableName, index: index) else {
                issues.append(SchemaDraftIssue(
                    tab: .indexes, row: row,
                    message: String(localized: "This database does not create indexes with a statement.")
                ))
                continue
            }
            statements.append(sql)
        }

        return CreateTableStatements(statements: statements, issues: issues, tableName: definition.tableName)
    }
}
