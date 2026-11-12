//
//  DatabaseManager+ContainerDDL.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// A multi-statement container plan that stopped partway.
///
/// An engine with no transactional DDL keeps every statement before the one that failed, so the
/// caller needs to know how far it got: a rename that landed has to be adopted even though the
/// operation as a whole failed, or the window is left pointing at a schema name the server no
/// longer has.
struct ContainerDDLPartialFailure: Error {
    let committedCount: Int
    let totalCount: Int
    let rolledBack: Bool
    let underlying: any Error

    var localizedDescription: String { underlying.localizedDescription }
}

/// Creating, editing, renaming and dropping a database or a schema, through one path.
///
/// Before this existed each action reached the driver its own way, so only rename asked the
/// execution gate: create and drop ran the statement with nothing but a hidden menu item standing
/// in for Safe Mode, which meant its confirmation and Touch ID tiers never fired and no audit
/// record was written for the two operations that destroy the most. Everything here authorizes
/// first, runs on the schema-change route rather than the user's session driver, records the
/// statements in history, and reports the catalog change so every window refreshes.
extension DatabaseManager {
    /// What a container operation will do, in the terms the gate and the sheet can both show.
    ///
    /// Not every engine has a statement for every action: a rename is a call on MongoDB and a
    /// stored procedure on SQL Server, and `createDatabase` is an API request on BigQuery. Those
    /// carry a description instead, which is what `OperationRequest` already accepts as `sql: nil`.
    enum ContainerDDLPlan {
        case statements([SchemaStatement])
        case opaque(String)

        var statements: [SchemaStatement] {
            switch self {
            case .statements(let statements): statements
            case .opaque: []
            }
        }

        var isEmpty: Bool {
            switch self {
            case .statements(let statements): statements.isEmpty
            case .opaque: false
            }
        }

        var previewSQL: [String] {
            statements.map(\.sql)
        }
    }

    // No statement to classify, so the caller states `kind`: a drop is destructive, anything else a schema mutation.
    func runContainerOperation(
        description: String,
        kind: OperationKind,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        event: CatalogEvent?,
        isConfirmationPreCleared: Bool = false,
        gate: any ExecutionGate = ExecutionGateProvider.shared,
        perform: @Sendable @escaping (any DatabaseDriver) async throws -> Void
    ) async throws {
        try await authorizeContainerOperation(
            sql: nil,
            kind: kind,
            connectionId: scope.connectionId,
            databaseType: databaseType,
            description: description,
            isConfirmationPreCleared: isConfirmationPreCleared,
            gate: gate
        )
        try await withScopedDriver(
            scope: scope,
            route: schemaChangeRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            try await perform(driver)
        }
        if let event { CatalogChangeService.post(event) }
    }

    // The kind comes from the statements, so an edit that revokes a privilege is authorized like a drop.
    func runContainerStatements(
        _ plan: ContainerDDLPlan,
        description: String,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        event: CatalogEvent?,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let statements = plan.statements
        guard !statements.isEmpty else { return }

        let kind: OperationKind = statements.contains(where: \.isDestructive)
            ? .destructiveQuery
            : .schemaMutation
        try await authorizeContainerOperation(
            sql: statements.map(\.sql).joined(separator: "\n"),
            kind: kind,
            connectionId: scope.connectionId,
            databaseType: databaseType,
            description: description,
            isConfirmationPreCleared: false,
            gate: gate
        )

        let route = schemaChangeRoute(for: scope)
        /// A transaction only where the connection is this operation's alone. PostgreSQL has no
        /// nested transaction, so a `BEGIN` on the session driver joins whatever a query tab left
        /// open and the `COMMIT` takes that tab's uncommitted writes with it; a rollback throws
        /// them away. An engine that cannot be pooled, PGlite among them, always lands on the
        /// session driver, so the plan runs unwrapped there and a partial apply is reported rather
        /// than risking work the user did not offer.
        let isIsolated = route.isPooled
        do {
            try await withScopedDriver(scope: scope, route: route, cancellation: .protectedWrite) { driver in
                try await Self.execute(statements, on: driver, useTransaction: isIsolated)
            }
        } catch {
            /// Reported on failure too, because an engine that cannot roll DDL back keeps every
            /// statement before the one that failed and the catalog really has moved.
            if let event { CatalogChangeService.post(event) }
            throw error
        }

        await recordContainerHistory(statements, scope: scope, databaseType: databaseType)
        if let event { CatalogChangeService.post(event) }
    }

    // Pre-cleared skips only a confirmation the caller already showed; Touch ID, Read-Only and the audit still apply.
    private func authorizeContainerOperation(
        sql: String?,
        kind: OperationKind,
        connectionId: UUID,
        databaseType: DatabaseType,
        description: String,
        isConfirmationPreCleared: Bool,
        gate: any ExecutionGate
    ) async throws {
        var capabilities = CallerCapabilities.interactiveUser
        if isConfirmationPreCleared { capabilities.insert(.confirmationPreCleared) }
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connectionId,
                databaseType: databaseType,
                sql: sql,
                kind: kind,
                caller: .userInterface,
                capabilities: capabilities,
                operationDescription: description
            )
        )
        if let denial = decision.denialError { throw denial }
    }

    private static func execute(
        _ statements: [SchemaStatement],
        on driver: any DatabaseDriver,
        useTransaction isolated: Bool
    ) async throws {
        let useTransaction = isolated && driver.supportsTransactions && driver.supportsTransactionalDDL
        if useTransaction {
            try await driver.beginTransaction(mode: .readWrite)
        }
        var committed = 0
        do {
            for statement in statements {
                _ = try await driver.execute(query: statement.sql)
                if !useTransaction { committed += 1 }
            }
            if useTransaction {
                try await driver.commitTransaction()
            }
        } catch {
            var rolledBack = false
            if useTransaction {
                do {
                    try await driver.rollbackTransaction()
                    rolledBack = true
                } catch {
                    DatabaseManager.logger.error(
                        "Rollback failed after container DDL error: \(error.publicLogShape, privacy: .public)"
                    )
                }
            }
            throw ContainerDDLPartialFailure(
                committedCount: rolledBack ? 0 : committed,
                totalCount: statements.count,
                rolledBack: rolledBack,
                underlying: error
            )
        }
    }

    private func recordContainerHistory(
        _ statements: [SchemaStatement],
        scope: DatabaseScope,
        databaseType: DatabaseType
    ) async {
        for statement in statements where !statement.carriesCredentials {
            await historyRecorder.record(
                QueryHistoryRecordRequest(
                    query: statement.sql.hasSuffix(";") ? statement.sql : statement.sql + ";",
                    connectionId: scope.connectionId,
                    databaseName: scope.database,
                    databaseType: databaseType,
                    schemaName: scope.schema,
                    source: .structureDDL,
                    executionTime: 0,
                    rowCount: -1,
                    wasSuccessful: true
                )
            )
        }
    }
}
