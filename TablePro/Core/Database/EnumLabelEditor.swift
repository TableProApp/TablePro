//
//  EnumLabelEditor.swift
//  TablePro
//

import Combine
import Foundation
import os

enum EnumLabelEditingError: LocalizedError {
    case notConnected
    case unsupported
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Not connected to database")
        case .unsupported: String(localized: "This database cannot change an enum's labels")
        case let .denied(reason): reason
        }
    }
}

/// The two edits PostgreSQL allows on an enum, each run as its own statement the moment the
/// user commits it. `ALTER TYPE … ADD VALUE` refuses to run inside a transaction block before
/// PostgreSQL 12, and a label added inside one cannot be used until it commits on later servers,
/// so there is nothing to stage: one edit, one statement, one authorization.
@MainActor
struct EnumLabelEditor {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "EnumLabelEditor")

    let connection: DatabaseConnection
    let objectRef: DatabaseObjectRef

    private var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: objectRef.database, schema: objectRef.schema)
    }

    private var driver: DatabaseDriver? {
        DatabaseManager.shared.driver(for: connection.id)
    }

    /// Whether the engine can add a label at all. Safe Mode is asked again when the statement
    /// runs, so this only decides whether the controls are drawn.
    var canEdit: Bool {
        guard !connection.safeModeLevel.blocksAllWrites, let type = objectRef.userType else { return false }
        return driver?.generateAddEnumLabelSQL(type: type, label: "label", placement: nil) != nil
    }

    func canRename(_ type: UserDefinedTypeInfo) -> Bool {
        driver?.generateRenameEnumLabelSQL(type: type, from: "old", to: "new") != nil
    }

    func add(label: String, placement: EnumLabelPlacement?, to type: UserDefinedTypeInfo) async throws {
        guard let driver else { throw EnumLabelEditingError.notConnected }
        guard let sql = driver.generateAddEnumLabelSQL(type: type, label: label, placement: placement) else {
            throw EnumLabelEditingError.unsupported
        }
        try await run(sql, description: String(localized: "Add Enum Label"))
    }

    func rename(_ oldLabel: String, to newLabel: String, in type: UserDefinedTypeInfo) async throws {
        guard let driver else { throw EnumLabelEditingError.notConnected }
        guard let sql = driver.generateRenameEnumLabelSQL(type: type, from: oldLabel, to: newLabel) else {
            throw EnumLabelEditingError.unsupported
        }
        try await run(sql, description: String(localized: "Rename Enum Label"))
    }

    private func run(_ sql: String, description: String) async throws {
        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: sql,
                kind: .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: description
            )
        )
        guard case .authorized = decision else {
            throw EnumLabelEditingError.denied(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }

        /// Not the session driver: that one holds whatever transaction the user opened in a query
        /// tab, and a label added inside it is unusable until the commit and gone on a rollback,
        /// while the listing reloads over other connections and cannot see it at all. The
        /// metadata route is a dedicated autocommit connection wherever the engine can pool one.
        let startedAt = Date()
        let scope = scope
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.metadataRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            _ = try await driver.execute(query: sql)
        }
        await recordHistory(sql, executionTime: Date().timeIntervalSince(startedAt))
        await refreshListings()
        AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: connection.id))
    }

    private func recordHistory(_ sql: String, executionTime: TimeInterval) async {
        await DatabaseManager.shared.historyRecorder.record(
            QueryHistoryRecordRequest(
                query: sql,
                connectionId: connection.id,
                databaseName: objectRef.database,
                databaseType: connection.type,
                source: .structureDDL,
                executionTime: executionTime,
                rowCount: -1,
                wasSuccessful: true
            )
        )
    }

    /// The sidebar row's tooltip and the quick switcher both carry the labels the listing read,
    /// so both listings are reloaded rather than left describing the type as it was. The open
    /// grids get the same refresh a trigger edit sends, because a column of this enum offers its
    /// labels as a picker and would go on offering the old set.
    private func refreshListings() async {
        let connectionId = connection.id
        await DatabaseTreeMetadataService.shared.refreshUserDefinedTypeObjects(
            connectionId: connectionId,
            database: objectRef.database,
            schema: objectRef.schema
        )
        do {
            try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: connectionId) { driver in
                await SchemaService.shared.reloadUserDefinedTypes(connectionId: connectionId, driver: driver)
            }
        } catch {
            Self.logger.warning("type listing refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
