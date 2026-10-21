//
//  ObjectCommentEditing.swift
//  TablePro
//
//  Sets or clears the comment on a table, view, materialized view or foreign table through the
//  execution gate.
//

import Combine
import Foundation
import TableProPluginKit
import TableProSQLGrammar

enum DatabaseObjectCommandError: LocalizedError, Equatable {
    case notConnected
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Not connected to database")
        case .unsupported: String(localized: "This database cannot run this command on this object")
        }
    }
}

@MainActor
enum ObjectCommentEditing {
    /// The current comment, read fresh rather than taken from the sidebar's listing, which may
    /// predate a change made in another window or another app.
    static func currentComment(of target: DatabaseObjectTarget) async throws -> String? {
        let name = target.name
        return try await DatabaseManager.shared.withMetadataDriver(scope: target.scope) { driver in
            try await driver.fetchObjectComment(tableName: name)
        }
    }

    static func statement(for comment: String?, on target: DatabaseObjectTarget, driver: DatabaseDriver) -> String? {
        driver.objectCommentStatement(
            name: target.name,
            objectType: target.type.rawValue,
            schema: target.schema,
            comment: comment
        )
    }

    /// Runs on the schema change route, like every other statement the app writes on the user's
    /// behalf: on the session driver it would join a transaction a query tab left open and be
    /// undone by that tab's rollback.
    static func setComment(
        _ comment: String?,
        on target: DatabaseObjectTarget,
        connection: DatabaseConnection,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw DatabaseObjectCommandError.notConnected
        }
        guard let sql = statement(for: comment, on: target, driver: driver) else {
            throw DatabaseObjectCommandError.unsupported
        }
        try await DatabaseObjectCommandRunner.run(
            sql,
            in: target.scope,
            connection: connection,
            kind: .schemaMutation,
            operationDescription: String(localized: "Edit Comment"),
            gate: gate
        )
        AppCommands.shared.objectChanged.send(target.change(.comment))
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: connection.id, database: target.scope.database, kinds: .tables))
        )
    }
}

/// The part every object command shares: authorize, run on a lease no Stop can reach, record it.
@MainActor
enum DatabaseObjectCommandRunner {
    static func run(
        _ sql: String,
        in scope: DatabaseScope,
        connection: DatabaseConnection,
        kind: OperationKind,
        operationDescription: String,
        isConfirmationPreCleared: Bool = false,
        gate: any ExecutionGate
    ) async throws {
        var capabilities = CallerCapabilities.interactiveUser
        if isConfirmationPreCleared { capabilities.insert(.confirmationPreCleared) }
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: sql,
                kind: kind,
                caller: .userInterface,
                capabilities: capabilities,
                operationDescription: operationDescription
            )
        )
        if let denial = decision.denialError { throw denial }

        let startedAt = Date()
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.schemaChangeRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            _ = try await driver.execute(query: sql)
        }

        await DatabaseManager.shared.historyRecorder.record(
            QueryHistoryRecordRequest(
                query: sql,
                connectionId: connection.id,
                databaseName: scope.database,
                databaseType: connection.type,
                schemaName: scope.schema,
                source: .structureDDL,
                executionTime: Date().timeIntervalSince(startedAt),
                rowCount: -1,
                wasSuccessful: true
            )
        )
    }
}
