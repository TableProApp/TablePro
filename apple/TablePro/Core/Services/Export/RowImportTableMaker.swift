//
//  RowImportTableMaker.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// Creates the tables a row import fills, or clears one it created on an earlier attempt, behind one gate grant
/// that the rows reuse. One prompt covers every table of a run, so importing twenty files asks once.
@MainActor
internal struct RowImportTableMaker {
    private enum Step {
        case create(TableScope, statements: [String], sql: String)
        case clear(String)
    }

    internal let connection: DatabaseConnection
    private let gate: any ExecutionGate

    internal init(connection: DatabaseConnection, gate: any ExecutionGate = ExecutionGateProvider.shared) {
        self.connection = connection
        self.gate = gate
    }

    internal static var statementError: NSError {
        NSError(
            domain: "RowImport", code: -1,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not build the CREATE TABLE statement")]
        )
    }

    /// `onCreated` hears of each table as soon as it exists, so a failure on a later one still leaves the planner
    /// knowing the earlier ones are this sheet's to reuse.
    internal func prepare(
        _ definitions: [PluginCreateTableDefinition],
        scope: DatabaseScope,
        planner: NewTableImportPlanner,
        description: String? = nil,
        onCreated: (TableScope, String) -> Void
    ) async throws -> OperationReceipt {
        guard ImportDataSinkAdapter.canWriteRows(into: connection.type) else {
            throw PluginImportError.importFailed(String(
                format: String(localized: "%@ cannot take rows from this file, so no table was created."),
                connection.type.rawValue
            ))
        }
        var steps: [Step] = []
        for definition in definitions {
            steps.append(try await step(for: definition, scope: scope, planner: planner))
        }

        let receipt = try await authorize(steps, description: description)
        var createdAny = false
        /// Also when a later table fails, since the ones before it are in the database.
        defer {
            if createdAny {
                CatalogChangeService.post(
                    .changed(CatalogChange(connectionId: connection.id, database: scope.database, kinds: .tables))
                )
            }
        }
        for step in steps {
            switch step {
            case .create(let table, let statements, let sql):
                for statement in statements {
                    try await runOnLeasedDriver(statement, scope: scope)
                    createdAny = true
                }
                onCreated(table, sql)
            case .clear(let sql):
                try await runOnLeasedDriver(sql, scope: scope)
            }
        }
        return receipt
    }

    private func step(
        for definition: PluginCreateTableDefinition,
        scope: DatabaseScope,
        planner: NewTableImportPlanner
    ) async throws -> Step {
        let tableName = definition.tableName
        let table = TableScope(table: tableName, in: scope)
        let statements = try await DatabaseManager.shared.createTableStatements(
            definition: definition,
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope)
        )
        guard !statements.isEmpty else { throw Self.statementError }
        let sql = statements.joined(separator: "\n")
        switch planner.plan(forTable: table, createTableSQL: sql) {
        case .create:
            return .create(table, statements: statements, sql: sql)
        case .reuseAfterClearing:
            let driver = DatabaseManager.shared.driver(for: connection.id)
            let generator = try SQLStatementGenerator(
                tableName: tableName,
                columns: [],
                primaryKeyColumns: [],
                databaseType: connection.type,
                quoteIdentifier: driver?.quoteIdentifier,
                rowDeleteStatement: driver?.rowDeleteStatement
            )
            return .clear(generator.deleteAllRowsStatement())
        case .nameTakenWithDifferentColumns:
            throw PluginImportError.importFailed(
                String(
                    format: String(localized: "The table %@ was already created with different columns. Choose another name."),
                    tableName
                )
            )
        }
    }

    /// Every statement the sheet issues on its own account goes through the gate. The retry path's `DELETE FROM`
    /// used to skip it while the `CREATE TABLE` beside it did not, so a connection set to confirm destructive
    /// statements emptied a table without asking.
    private func authorize(_ steps: [Step], description: String?) async throws -> OperationReceipt {
        var statements: [String] = []
        var clears = false
        for step in steps {
            switch step {
            case .create(_, let created, _):
                statements += created
            case .clear(let sql):
                statements.append(sql)
                clears = true
            }
        }
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: SQLScriptText(
                    databaseType: connection.type,
                    grammar: SQLLexicalResolver.executionGrammar(for: connection.type, connectionId: connection.id)
                ).script(statements),
                kind: clears ? .destructiveQuery : .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: description
                    ?? (clears ? String(localized: "Clear Table") : String(localized: "Create Table"))
            )
        )
        guard case .authorized(let receipt) = decision else {
            throw decision.denialError ?? ExecutionGateError.denied(String(localized: "Operation not permitted"))
        }
        return receipt
    }

    /// One statement at a time on the import's own kind of lease, always after `authorize` has returned. Taking it
    /// earlier would hold the connection's gate open across a confirmation the user has not answered yet, and the
    /// gate is not reentrant, so the import that follows would then wait on a sheet waiting on the user.
    private func runOnLeasedDriver(_ sql: String, scope: DatabaseScope) async throws {
        let route = DatabaseManager.shared.executionRoute(for: scope)
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .protectedWrite
        ) { driver in
            try await driver.execute(query: sql)
        }
    }
}
