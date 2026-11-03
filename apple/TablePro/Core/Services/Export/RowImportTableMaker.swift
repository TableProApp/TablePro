//
//  RowImportTableMaker.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

@MainActor
internal struct RowImportTableMaker {
    private enum Step {
        case create(TableScope, statements: [String], sql: String)
        case clear(TableScope, sql: String)
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

    internal func prepare(
        _ definitions: [PluginCreateTableDefinition],
        scope: DatabaseScope,
        planner: NewTableImportPlanner,
        description: String? = nil,
        importRun: ImportRun? = nil,
        onCreated: (TableScope, String) -> Void
    ) async throws -> OperationReceipt {
        do {
            return try await prepareControlled(definitions, scope: scope, planner: planner, description: description,
                                               importRun: importRun, onCreated: onCreated)
        } catch {
            if error is PluginImportCancellationError || error is CancellationError {
                importRun?.stop(.rollBack)
            } else if let importRun, (try? await importRun.admit(.session)) == .proceed {
                importRun.record { $0.recordError(error) }
                importRun.release()
            }
            await importRun?.complete()
            if importRun?.stopChoice != nil { throw PluginImportCancellationError() }
            throw error
        }
    }

    private func prepareControlled(
        _ definitions: [PluginCreateTableDefinition],
        scope: DatabaseScope,
        planner: NewTableImportPlanner,
        description: String? = nil,
        importRun: ImportRun? = nil,
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
                    try await runOnLeasedDriver(statement, scope: scope, table: table, clearing: false, run: importRun)
                    createdAny = true
                }
                onCreated(table, sql)
            case .clear(let table, let sql):
                try await runOnLeasedDriver(sql, scope: scope, table: table, clearing: true, run: importRun)
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
            return .clear(table, sql: generator.deleteAllRowsStatement())
        case .nameTakenWithDifferentColumns:
            throw PluginImportError.importFailed(
                String(
                    format: String(localized: "The table %@ was already created with different columns. Choose another name."),
                    tableName
                )
            )
        }
    }

    private func authorize(_ steps: [Step], description: String?) async throws -> OperationReceipt {
        var statements: [String] = []
        var clears = false
        for step in steps {
            switch step {
            case .create(_, let created, _):
                statements += created
            case .clear(_, let sql):
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

    private func runOnLeasedDriver(
        _ sql: String, scope: DatabaseScope, table: TableScope, clearing: Bool, run: ImportRun?
    ) async throws {
        if let run { _ = try await run.admit(.data) }
        defer { run?.release() }
        let route = DatabaseManager.shared.executionRoute(for: scope)
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope, route: route, cancellation: .protectedWrite
        ) { driver in
            if let run {
                try await Self.executePreparation(sql, table: table, clearing: clearing, driver: driver, run: run)
            } else {
                _ = try await driver.execute(query: sql)
            }
        }
    }

    nonisolated private static func executePreparation(
        _ sql: String, table: TableScope, clearing: Bool, driver: DatabaseDriver, run: ImportRun
    ) async throws {
        let id = UUID()
        let rollback: ImportTableRollback
        if !clearing {
            rollback = .unknown
        } else if !driver.supportsTransactions {
            rollback = .nontransactional
        } else if DataSyncTransactionality.needsStorageEngines(driver.connection.type) {
            if let engine = try? await driver.fetchTableMetadata(tableName: table.table, schema: table.schema).engine,
               !engine.isEmpty {
                rollback = DataSyncTransactionality.cannotRollBack(storageEngine: engine, databaseType: driver.connection.type)
                    ? .nontransactional : .transactional
            } else {
                rollback = .unknown
            }
        } else {
            rollback = .transactional
        }
        run.record {
            $0.preparations[id] = ImportPreparationEffect(table: table, clearing: clearing)
        }
        do {
            _ = try await driver.execute(query: sql)
            let state = driver.supportsTransactions
                ? ImportSessionState(await driver.heldSessionTransactionState()) : .idle
            run.record {
                $0.currentState = state
                $0.preparations[id]?.completed = true
                if clearing, rollback == .nontransactional || (rollback == .transactional && state == .idle) {
                    $0.preparations[id]?.fate = .kept
                } else if clearing, rollback == .transactional, state.holdsTransaction {
                    $0.preparations[id]?.fate = state == .aborted ? .abortedTransaction : .openTransaction
                }
            }
        } catch {
            let state = driver.supportsTransactions
                ? ImportSessionState(await driver.heldSessionTransactionState()) : .idle
            run.record { $0.currentState = state; $0.recordError(error) }
            throw error
        }
    }
}
