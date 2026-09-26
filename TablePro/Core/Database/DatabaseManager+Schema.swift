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
    /// The gate's sheet is the only confirmation a save gets. A refusal throws
    /// `ExecutionGateError.denied` and a Cancel throws `.cancelledByUser`, so the caller can keep
    /// the edits staged and stay quiet about a choice the user just made.
    func executeSchemaChanges(
        _ statements: [SchemaStatement],
        databaseType: DatabaseType,
        scope: DatabaseScope,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let route = schemaChangeRoute(for: scope)

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
                let useTransaction = driver.supportsTransactions
                if useTransaction {
                    try await driver.beginTransaction(mode: schemaKind.declaresWrite ? .readWrite : .serverDefault)
                }
                do {
                    var measured: [TimeInterval] = []
                    for stmt in statements {
                        let startedAt = Date()
                        _ = try await driver.execute(query: stmt.sql)
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
                            Self.logger.error("Rollback failed after schema change error: \(error.localizedDescription)")
                        }
                    }
                    throw DatabaseError.queryFailed("Schema change failed: \(error.localizedDescription)")
                }
            }
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

        AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: scope.connectionId, scope: scope))
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: scope.connectionId, database: scope.database, kinds: .tables))
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

    /// Destructive when the text reads that way or when any statement was generated as one. The
    /// text alone cannot see that `ALTER COLUMN .. TYPE`, `MODIFY COLUMN .. NOT NULL` or an added
    /// `CHECK` can lose or refuse existing rows, and a destructive kind is confirmed at every
    /// Safe Mode level, Silent included.
    nonisolated static func schemaOperationKind(
        for statements: [SchemaStatement],
        combinedSQL: String,
        databaseType: DatabaseType
    ) -> OperationKind {
        let destructiveText = QueryClassifier.classifyTier(combinedSQL, databaseType: databaseType) == .destructive
        return destructiveText || statements.contains(where: \.isDestructive) ? .destructiveQuery : .schemaMutation
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
