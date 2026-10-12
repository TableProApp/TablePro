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
    /// Execute schema statements (ALTER TABLE, CREATE INDEX, etc.) on the schema change route rather
    /// than the session driver a query tab may have left mid-transaction, in a transaction of their
    /// own only where the engine rolls DDL back. The connection, database and schema all come from
    /// the editing tab's own scope, never from ambient session state that another window or tab can
    /// move.
    ///
    /// Authorization sits outside the scoped block: it awaits a confirmation sheet and Touch ID,
    /// and holding the connection's driver gate across a human prompt would freeze every other
    /// tab on that connection.
    ///
    /// The gate's sheet is the only confirmation a save gets. A refusal throws
    /// `ExecutionGateError.denied` and a Cancel throws `.cancelledByUser`, so the caller can keep
    /// the edits staged and stay quiet about a choice the user just made.
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
        scope: DatabaseScope,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let route = schemaChangeRoute(for: scope)
        let statements = script.statements

        let request = Self.schemaChangeAuthorizationRequest(statements, databaseType: databaseType, scope: scope)
        let schemaKind = request.kind
        if let denial = await gate.authorize(request).denialError {
            throw denial
        }

        let executionTimes: [TimeInterval]
        do {
            executionTimes = try await withScopedDriver(
                scope: scope,
                route: route,
                cancellation: .protectedWrite
            ) { driver in
                try await Self.refuseBeforeWriting(script, scope: scope, on: driver)
                let useTransaction = Self.wrapsDDLInTransaction(driver)
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
            reportSavedChange(of: script, in: scope)
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

        reportSavedChange(of: script, in: scope)
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: scope.connectionId, database: scope.database, kinds: .tables))
        )
    }

    /// The rule ContainerDDL and Compare sync already follow. Where DDL commits on its own, a wrap
    /// undoes nothing, and on Teradata it turns every statement after the first DDL into error 3932.
    nonisolated static func wrapsDDLInTransaction(_ driver: DatabaseDriver) -> Bool {
        driver.supportsTransactions && driver.supportsTransactionalDDL
    }

    /// A save that only set the comment changed no column, so it is announced as a comment change.
    private func reportSavedChange(of script: SchemaChangeScript, in scope: DatabaseScope) {
        guard script.setsCommentOnly else {
            reportTableDefinitionChange(table: script.tableName, in: scope)
            return
        }
        AppCommands.shared.objectChanged.send(
            DatabaseObjectChange(connectionId: scope.connectionId, scope: scope, name: script.tableName, kind: .comment)
        )
    }

    /// What the gate is asked before a save runs, built apart from the run so a test can put it to
    /// the real gate at every Safe Mode level.
    nonisolated static func schemaChangeAuthorizationRequest(
        _ statements: [SchemaStatement],
        databaseType: DatabaseType,
        scope: DatabaseScope
    ) -> OperationRequest {
        let combinedSQL = statements.map(\.sql).joined(separator: "\n")
        return OperationRequest(
            connectionId: scope.connectionId,
            databaseType: databaseType,
            sql: combinedSQL,
            kind: schemaOperationKind(for: statements, combinedSQL: combinedSQL, databaseType: databaseType),
            caller: .userInterface,
            capabilities: .interactiveUser,
            operationDescription: String(localized: "Apply Schema Changes")
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

    /// Destructive when the text reads that way or when any statement was generated as one. The
    /// text alone cannot see that `ALTER COLUMN .. TYPE`, `MODIFY COLUMN .. NOT NULL` or an added
    /// `CHECK` can lose or refuse existing rows, or that a removed MongoDB field, an `updateMany`
    /// with `$unset`, drops data. A destructive kind is confirmed at every Safe Mode level, Silent
    /// included.
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
        scope: DatabaseScope,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        guard !statements.isEmpty else { return }
        let route = schemaChangeRoute(for: scope)
        let script = statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")

        let authorization = await gate.authorize(
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
                let useTransaction = Self.wrapsDDLInTransaction(driver) && statements.count > 1
                if useTransaction {
                    try await driver.beginTransaction(mode: .readWrite)
                }
                var measured: [TimeInterval] = []
                do {
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
                    } else if !measured.isEmpty {
                        throw CreateTableIncompleteError(message: error.localizedDescription)
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

/// Create Table ran its CREATE outside a transaction and a later statement, such as an index or the
/// comment, failed: the table exists, so running the draft again would only fail on its name.
struct CreateTableIncompleteError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// A schema save that stopped once its statements had started to run, so the table may have
/// changed even though the save did not finish.
private struct SchemaChangeFailedAfterWriting: Error {
    let message: String
}

private extension SchemaChangeScript {
    var setsCommentOnly: Bool {
        !statements.isEmpty && statements.allSatisfy(\.setsComment)
    }
}
