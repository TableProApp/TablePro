//
//  DatabaseManager+Schema.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Combine
import Foundation
import os
import TableProPluginKit

// MARK: - Schema Changes

extension DatabaseManager {
    /// Execute schema statements (ALTER TABLE, CREATE INDEX, etc.) in a transaction of their own,
    /// on the schema change route rather than the session driver a query tab may have left
    /// mid-transaction. The connection, database and schema all come from the editing tab's
    /// own scope, never from ambient session state that another window or tab can move.
    ///
    /// Authorization sits outside the scoped block: it awaits a confirmation sheet and Touch ID,
    /// and holding the connection's driver gate across a human prompt would freeze every other
    /// tab on that connection.
    ///
    /// The driver is asked `schemaChangeRefusalBeforeWriting` on the same connection, after the
    /// user has confirmed and before the first statement, which is the only point a check that
    /// reads the data belongs: SQL Preview composes the same script and must not pay for it. It is
    /// asked `schemaChangeShortfallAfterWriting` after the last one, because a statement that
    /// succeeds over many rows can still miss one another client wrote while it ran.
    ///
    /// A save that fails once its first statement has started reports the table changed, as a
    /// successful one does. MongoDB keeps every document an `updateMany` changed before it stopped,
    /// and MySQL, MariaDB and Oracle commit each DDL statement as it runs, so the rows on screen
    /// can describe a table that has moved on.
    func executeSchemaChanges(
        _ script: SchemaChangeScript,
        databaseType: DatabaseType,
        scope: DatabaseScope
    ) async throws {
        let route = schemaChangeRoute(for: scope)
        let statements = script.statements

        let combinedSQL = statements.map(\.sql).joined(separator: "\n")
        let schemaKind = Self.schemaOperationKind(for: statements, combinedSQL: combinedSQL, databaseType: databaseType)
        let authorization = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: scope.connectionId,
                databaseType: databaseType,
                sql: combinedSQL,
                kind: schemaKind,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Apply Schema Changes")
            )
        )
        guard case .authorized = authorization else {
            throw DatabaseError.queryFailed(
                authorization.deniedReason ?? String(localized: "Schema change was not authorized")
            )
        }

        let executionTimes: [TimeInterval]
        do {
            executionTimes = try await withScopedDriver(
                scope: scope,
                route: route,
                cancellation: .protectedWrite
            ) { driver in
                try await Self.refuseBeforeWriting(script, scope: scope, on: driver)
                let useTransaction = driver.supportsTransactions
                if useTransaction {
                    try await driver.beginTransaction(mode: schemaKind.declaresWrite ? .readWrite : .serverDefault)
                }
                var measured: [TimeInterval] = []
                do {
                    for stmt in statements {
                        let startedAt = Date()
                        _ = try await driver.execute(query: stmt.sql)
                        measured.append(Date().timeIntervalSince(startedAt))
                    }
                    if useTransaction {
                        try await driver.commitTransaction()
                    }
                } catch {
                    if useTransaction {
                        do {
                            try await driver.rollbackTransaction()
                        } catch {
                            Self.logger.error("Rollback failed after schema change error: \(error.localizedDescription)")
                        }
                    }
                    throw SchemaChangeFailedAfterWriting(message: "Schema change failed: \(error.localizedDescription)")
                }
                try await Self.confirmFinished(script, scope: scope, on: driver)
                return measured
            }
        } catch let refusal as SchemaOperationRefusedError {
            throw refusal
        } catch let failure as SchemaChangeFailedAfterWriting {
            Self.reportCatalogChangeAfterFailure(in: scope)
            reportTableDefinitionChange(table: script.tableName, in: scope)
            throw DatabaseError.queryFailed(failure.message)
        } catch {
            Self.reportCatalogChangeAfterFailure(in: scope)
            throw error
        }

        let databaseTypeForHistory = databaseType
        for (index, stmt) in statements.enumerated() {
            await historyRecorder.record(
                QueryHistoryRecordRequest(
                    query: stmt.sql.hasSuffix(";") ? stmt.sql : stmt.sql + ";",
                    connectionId: scope.connectionId,
                    databaseName: scope.database,
                    databaseType: databaseTypeForHistory,
                    schemaName: scope.schema,
                    source: .structureDDL,
                    executionTime: executionTimes.indices.contains(index) ? executionTimes[index] : 0,
                    rowCount: -1,
                    wasSuccessful: true
                )
            )
        }

        reportTableDefinitionChange(table: script.tableName, in: scope)
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: scope.connectionId, database: scope.database, kinds: .tables))
        )
    }

    /// Tells everything that remembers the table's definition that it changed: the session's driver,
    /// which may keep what it learned about the columns, and every window, whose tabs on the table
    /// reload or are marked to reload their rows and structure. Addressed by the table, so a tab on
    /// another table in the same database is left alone.
    func reportTableDefinitionChange(table: String, in scope: DatabaseScope) {
        activeSessions[scope.connectionId]?.driver?.tableDefinitionDidChange(table: table, schema: scope.schema)
        AppCommands.shared.objectChanged.send(
            DatabaseObjectChange(connectionId: scope.connectionId, scope: scope, name: table, kind: .structure)
        )
    }

    /// Destructive when the statements' text says so or when the change a statement came from does.
    /// A removed MongoDB field is an `updateMany` with `$unset`, which the text classifier tiers as a
    /// plain write, so only the statement's own flag puts it behind the Safe Mode level that confirms
    /// a dropped column.
    nonisolated static func schemaOperationKind(
        for statements: [SchemaStatement],
        combinedSQL: String,
        databaseType: DatabaseType
    ) -> OperationKind {
        let destructiveText = QueryClassifier.classifyTier(combinedSQL, databaseType: databaseType) == .destructive
        return destructiveText || statements.contains(where: \.isDestructive) ? .destructiveQuery : .schemaMutation
    }

    nonisolated private static func refuseBeforeWriting(
        _ script: SchemaChangeScript,
        scope: DatabaseScope,
        on driver: DatabaseDriver
    ) async throws {
        let refusal = try await driver.schemaChangeRefusalBeforeWriting(
            table: script.tableName,
            schema: scope.schema,
            operations: script.operations,
            review: script.review
        )
        if let refusal {
            throw SchemaOperationRefusedError(reason: refusal)
        }
    }

    nonisolated private static func confirmFinished(
        _ script: SchemaChangeScript,
        scope: DatabaseScope,
        on driver: DatabaseDriver
    ) async throws {
        let shortfall: String?
        do {
            shortfall = try await driver.schemaChangeShortfallAfterWriting(
                table: script.tableName,
                schema: scope.schema,
                operations: script.operations,
                review: script.review
            )
        } catch {
            throw SchemaChangeFailedAfterWriting(message: error.localizedDescription)
        }
        if let shortfall {
            throw SchemaChangeFailedAfterWriting(message: shortfall)
        }
    }

    /// Run a Create Table draft's statements, on the same isolated route and in the same shape as
    /// `executeSchemaChanges`.
    ///
    /// The route is what matters. The view used to reach for `driver(for:)`, which is the session
    /// driver, so a `BEGIN` opened here joined whatever transaction a query tab had left open and
    /// the matching `COMMIT` took that tab's uncommitted work with it. `schemaChangeRoute` exists
    /// for exactly that, and the app's own DDL has no business on the user's connection.
    func executeCreateTable(
        statements: [String],
        databaseType: DatabaseType,
        scope: DatabaseScope
    ) async throws {
        guard !statements.isEmpty else { return }
        let route = schemaChangeRoute(for: scope)
        let script = statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")

        let authorization = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: scope.connectionId,
                databaseType: databaseType,
                sql: script,
                kind: .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Create Table")
            )
        )
        guard case .authorized = authorization else {
            throw DatabaseError.queryFailed(
                authorization.deniedReason ?? String(localized: "Operation not permitted")
            )
        }

        let executionTimes: [TimeInterval]
        do {
            executionTimes = try await withScopedDriver(
                scope: scope,
                route: route,
                cancellation: .protectedWrite
            ) { driver in
                let useTransaction = driver.supportsTransactions && statements.count > 1
                if useTransaction {
                    try await driver.beginTransaction(mode: .readWrite)
                }
                do {
                    var measured: [TimeInterval] = []
                    for statement in statements {
                        let startedAt = Date()
                        _ = try await driver.execute(query: statement)
                        measured.append(Date().timeIntervalSince(startedAt))
                    }
                    if useTransaction {
                        try await driver.commitTransaction()
                    }
                    return measured
                } catch {
                    if useTransaction {
                        do {
                            try await driver.rollbackTransaction()
                        } catch {
                            Self.logger.error("Rollback failed after create table error: \(error.localizedDescription)")
                        }
                    }
                    throw error
                }
            }
        } catch {
            Self.reportCatalogChangeAfterFailure(in: scope)
            throw error
        }

        for (index, statement) in statements.enumerated() {
            await historyRecorder.record(
                QueryHistoryRecordRequest(
                    query: statement.hasSuffix(";") ? statement : statement + ";",
                    connectionId: scope.connectionId,
                    databaseName: scope.database,
                    databaseType: databaseType,
                    schemaName: scope.schema,
                    source: .structureDDL,
                    executionTime: executionTimes.indices.contains(index) ? executionTimes[index] : 0,
                    rowCount: -1,
                    wasSuccessful: true
                )
            )
        }
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: scope.connectionId, database: scope.database, kinds: .tables))
        )
    }

    /// A failed batch is not proof that nothing changed: MySQL, MariaDB and Oracle commit each DDL
    /// statement as it runs, so the statements before the failure stay applied after the rollback.
    private static func reportCatalogChangeAfterFailure(in scope: DatabaseScope) {
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: scope.connectionId, database: scope.database, kinds: .tables))
        )
    }
}

/// A schema save that stopped once its statements had started to run, so the table may have
/// changed even though the save did not finish.
private struct SchemaChangeFailedAfterWriting: Error {
    let message: String
}
