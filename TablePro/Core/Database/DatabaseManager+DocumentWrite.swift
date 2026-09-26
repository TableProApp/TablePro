//
//  DatabaseManager+DocumentWrite.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

extension DatabaseManager {
    /// Writes one whole document the user edited, the way a grid save writes rows: authorized first,
    /// on the connection the user's data lives on, under a lease no Stop can interrupt, then recorded
    /// and announced so every tab showing the collection reloads.
    ///
    /// `statement` is what the gate shows and what history keeps. The driver sends the same
    /// documents itself rather than running that text, which is why both come from one plan.
    func executeDocumentWrite(
        _ write: PluginDocumentWrite,
        statement: String,
        databaseType: DatabaseType,
        scope: DatabaseScope,
        operationDescription: String,
        gate: any ExecutionGate
    ) async throws {
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: scope.connectionId,
                databaseType: databaseType,
                sql: statement,
                kind: .writeQuery,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: operationDescription
            )
        )
        guard case .authorized = decision else {
            throw DocumentEditingError.denied(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }

        let startedAt = Date()
        do {
            try await withScopedDriver(
                scope: scope,
                route: executionRoute(for: scope),
                cancellation: .protectedWrite
            ) { driver in
                try await driver.executeDocumentWrite(write)
            }
        } catch {
            await recordDocumentWrite(statement, scope: scope, databaseType: databaseType, startedAt: startedAt, error: error)
            throw error
        }

        await recordDocumentWrite(statement, scope: scope, databaseType: databaseType, startedAt: startedAt, error: nil)
        AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: scope.connectionId, scope: scope))
    }

    /// The stored document a row's locator names, read on the connection the tab's data lives on.
    ///
    /// Cancellable, so closing the sheet stops a read the server is still answering.
    func fetchDocument(locator: String, table: String, scope: DatabaseScope) async throws -> String? {
        try await withCancellableRead(scope: scope, route: executionRoute(for: scope)) { driver in
            try await driver.fetchDocument(table: table, schema: scope.schema, locator: locator)
        }
    }

    private func recordDocumentWrite(
        _ statement: String,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        startedAt: Date,
        error: Error?
    ) async {
        await historyRecorder.record(
            QueryHistoryRecordRequest(
                query: statement,
                connectionId: scope.connectionId,
                databaseName: scope.database,
                databaseType: databaseType,
                schemaName: scope.schema,
                source: .rowEdit,
                executionTime: Date().timeIntervalSince(startedAt),
                rowCount: error == nil ? 1 : -1,
                wasSuccessful: error == nil,
                errorMessage: error?.localizedDescription
            )
        )
    }
}
