//
//  ShortcutsRowWriter.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

// Add Row and Add Rows clear the gates a statement from a shortcut clears, then write through the grid's own insert
// path, so a driver that writes its own rows writes these too, in one transaction of the app's own.
internal enum ShortcutsRowWriter {
    internal struct Request: Sendable {
        internal let rows: [PayloadRow]
        internal let table: String
        internal let connectionId: UUID
        internal let namespace: String?
    }

    internal static func insert(
        _ request: Request,
        bridge: DatabaseAccessBridge = DatabaseAccessBridge(),
        history: QueryHistoryRecording = QueryHistoryManager.shared,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> Int {
        let snapshot = try await MainActor.run {
            try ScriptQueryRunner.visibleSnapshot(connectionId: request.connectionId, channel: .shortcuts)
        }
        do {
            return try await insert(request, snapshot: snapshot, bridge: bridge, history: history, gate: gate)
        } catch {
            throw ShortcutsActionError.wrapping(error, secrets: snapshot.redactionSecrets)
        }
    }

    private static func insert(
        _ request: Request,
        snapshot: ExternalConnectionPolicySnapshot,
        bridge: DatabaseAccessBridge,
        history: QueryHistoryRecording,
        gate: any ExecutionGate
    ) async throws -> Int {
        let databaseType = snapshot.databaseType
        // Before anything connects or asks for a password.
        try ExternalStatementGate.refuseWrite(externalAccess: snapshot.externalAccess)

        try await ScriptConnectGate.authorizeConnect(connectionId: request.connectionId)
        try await bridge.ensureConnected(request.connectionId)
        let target = await MainActor.run {
            ShortcutsCatalog.placement(of: request.namespace, databaseType: databaseType)
        }
        let scope = try await bridge.resolveScope(
            connectionId: request.connectionId,
            database: target.database,
            schema: target.schema
        )

        // Built on the driver that read the columns: a driver that types values from what it read about the table,
        // as MongoDB's does, keeps that reading on the connection it read it on.
        let (plan, rowCount) = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            let columns = try await driver.fetchColumns(table: request.table, schema: scope.schema)
            let pluginDriver = driver.queryBuildingPluginDriver
            return try await MainActor.run {
                try writePlan(
                    for: request.rows,
                    table: request.table,
                    scope: scope,
                    columns: columns,
                    databaseType: databaseType,
                    pluginDriver: pluginDriver
                )
            }
        }
        guard !plan.steps.isEmpty else { throw IntentDataError.noInsertableValues(request.table) }

        // The person approving the write reads every row with its values, as a grid save shows them.
        try await ExternalStatementGate.authorizeExecution(
            sql: plan.displaySQL,
            connectionId: request.connectionId,
            databaseType: databaseType,
            caller: .shortcuts,
            capabilities: [.mayWrite, .mayRunMultiStatement],
            operationDescription: confirmationTitle(rows: rowCount, table: request.table),
            kind: .writeQuery,
            gate: gate
        )

        let route = await MainActor.run { DatabaseManager.shared.schemaChangeRoute(for: scope) }
        let ownsConnection = route.isPooled
        let started = Date()
        let recorded = historyText(of: plan)
        func record(rowCount: Int, error: String?) async {
            await history.record(
                QueryHistoryRecordRequest(
                    query: recorded,
                    connectionId: request.connectionId,
                    databaseName: scope.database,
                    databaseType: databaseType,
                    schemaName: scope.schema,
                    source: .shortcuts,
                    executionTime: Date().timeIntervalSince(started),
                    rowCount: rowCount,
                    wasSuccessful: error == nil,
                    errorMessage: error
                )
            )
        }

        do {
            _ = try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: route,
                cancellation: .protectedWrite
            ) { driver in
                try await refuseHeldTransaction(on: driver, ownsConnection: ownsConnection)
                return try await DataWriteExecutor.run(plan, on: driver)
            }
        } catch let partial as DataWritePartialCommitError {
            let reason = ScriptingError.from(partial.underlying, secrets: snapshot.redactionSecrets)
                .errorDescription ?? String(localized: "The operation failed.")
            await record(rowCount: partial.committed.count, error: reason)
            await announceRowsChanged(in: request.table, scope: scope)
            throw ShortcutsActionError(message: "\(partial.partialCommitMessage) \(reason)")
        } catch {
            await record(rowCount: 0, error: ScriptingError.from(error, secrets: snapshot.redactionSecrets).errorDescription)
            throw error
        }

        await record(rowCount: rowCount, error: nil)
        await announceRowsChanged(in: request.table, scope: scope)
        return rowCount
    }

    // The change set the grid saves for rows a person added, so a driver with its own row writes (an upsert engine
    // adding IF NOT EXISTS, a document store) writes these rows its own way.
    @MainActor
    internal static func writePlan(
        for rows: [PayloadRow],
        table: String,
        scope: DatabaseScope,
        columns: [ColumnInfo],
        databaseType: DatabaseType,
        pluginDriver: (any PluginDatabaseDriver)?
    ) throws -> (plan: DataWritePlan, rowCount: Int) {
        let serverOwned = Set(columns.filter { $0.isGenerated || $0.identityKind == .always }.map(\.name))
        let planned = try PayloadRowPlanner.values(
            table: table,
            columns: columns.map {
                PayloadColumn(name: $0.name, isPrimaryKey: $0.isPrimaryKey, isServerOwned: serverOwned.contains($0.name))
            },
            rows: rows
        )
        guard !planned.isEmpty else { throw IntentDataError.noInsertableValues(table) }

        let names = columns.map(\.name)
        let primaryKeys = columns.filter(\.isPrimaryKey).map(\.name)
        var changes: [RowChange] = []
        var insertedRowData: [RowID: [PluginCellValue]] = [:]
        for (index, values) in planned.enumerated() {
            let rowID = RowID.inserted(UUID())
            let byColumn = Dictionary(values.map { ($0.column, $0.value) }, uniquingKeysWith: { first, _ in first })
            insertedRowData[rowID] = names.map { name in
                guard let value = byColumn[name] else { return .text(PluginCellValue.defaultMarkerText) }
                return value.map(PluginCellValue.text) ?? .null
            }
            changes.append(RowChange(rowID: rowID, type: .insert, sequence: index))
        }

        let factory = RowChangeStatementFactory(
            tableName: table,
            schemaName: scope.schema,
            columns: names,
            primaryKeyColumns: primaryKeys,
            generatedColumns: serverOwned,
            columnTypeNames: Dictionary(columns.map { ($0.name, $0.dataType) }, uniquingKeysWith: { first, _ in first }),
            databaseType: databaseType,
            pluginDriver: pluginDriver
        )
        let statements: RowWriteStatements
        do {
            statements = try factory.rowWriteStatements(
                for: changes,
                insertedRowData: insertedRowData,
                insertedRowIDs: Set(insertedRowData.keys)
            )
        } catch DataWriteError.statementGenerationUnavailable(_) {
            throw IntentDataError.unsupportedDatabaseType(databaseType.rawValue)
        } catch is SQLDialectError {
            throw IntentDataError.unsupportedDatabaseType(databaseType.rawValue)
        }
        let steps = DataWriteStep.rowWrites(statements, tableName: table, primaryKeyColumns: primaryKeys)
        return (DataWritePlan(scope: scope, databaseType: databaseType, steps: steps), planned.count)
    }

    // A transaction already open is never the shortcut's to join: on the shared session it is the user's, and on a
    // pooled connection a startup command left it. Rows written into it could still be rolled back after the
    // shortcut reported them added.
    private static func refuseHeldTransaction(on driver: DatabaseDriver, ownsConnection: Bool) async throws {
        let owner = WriteTransactionOwner.resolve(
            supportsTransactions: driver.supportsTransactions,
            sessionState: await driver.heldSessionTransactionState()
        )
        guard owner == .session else { return }
        guard ownsConnection else {
            throw ShortcutsActionError(
                message: String(
                    localized: "A transaction is open on this connection. Commit or roll it back in TablePro, then run the shortcut again."
                )
            )
        }
        throw ShortcutsActionError(
            message: String(
                localized: "This connection's startup commands leave a transaction open, so rows added from Shortcuts could not be committed."
            )
        )
    }

    @MainActor
    private static func announceRowsChanged(in table: String, scope: DatabaseScope) {
        AppCommands.shared.objectChanged.send(
            DatabaseObjectChange(connectionId: scope.connectionId, scope: scope, name: table, kind: .rows)
        )
    }

    private static func confirmationTitle(rows: Int, table: String) -> String {
        guard rows != 1 else {
            return String(format: String(localized: "Shortcuts wants to add a row to \"%@\""), table)
        }
        return String(format: String(localized: "Shortcuts wants to add %1$lld rows to \"%2$@\""), rows, table)
    }

    // One entry per action: each statement shape once, since every row of a payload shares one or a few.
    private static func historyText(of plan: DataWritePlan) -> String {
        var seen = Set<String>()
        return plan.steps.map(\.statement.sql).filter { seen.insert($0).inserted }.joined(separator: ";\n")
    }
}
