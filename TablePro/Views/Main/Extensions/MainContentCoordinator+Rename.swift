//
//  MainContentCoordinator+Rename.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

private let renameLogger = Logger(subsystem: "com.TablePro", category: "Rename")

/// Renaming an object, and moving everything that named it by the old name.
///
/// It runs at once rather than joining the Truncate and Drop queue. The row's own label is what
/// the user edits, so a queued rename would leave the tree showing a name the server does not
/// have, and every later command on that row would name an object that does not exist. Dropping a
/// database already works this way.
extension MainContentCoordinator {
    func renameTable(_ ref: DatabaseTreeTableRef, to newName: String) {
        let objectType = TableObjectKeyword.forDDL(ref.table.type)
        let oldName = ref.table.name
        let schema = ref.qualifyingSchema

        Task { [weak self] in
            guard let self else { return }
            /// The scope comes from the row, not from whichever database the session is on.
            /// `activateThen` switches the browse cursor first but reports no success, so a switch
            /// that failed would otherwise leave this running an unqualified statement against the
            /// database still in front, renaming a same-named object there.
            guard let scope = DatabaseManager.shared.resolvedScope(
                database: ref.database, schema: schema, for: connectionId
            ) else {
                presentRenameFailure(DatabaseError.notConnected)
                return
            }
            guard await authorizeRename(
                describing: String(
                    format: String(localized: "Rename %1$@ to %2$@"), qualifiedLabel(ref), newName
                )
            ) else { return }

            do {
                let route = DatabaseManager.shared.executionRoute(for: scope)
                try await DatabaseManager.shared.withScopedDriver(
                    scope: scope, route: route, cancellation: .protectedWrite
                ) { driver in
                    try await driver.renameTable(
                        name: oldName, schema: schema, to: newName, objectType: objectType
                    )
                }
            } catch {
                presentRenameFailure(error, object: ref.id)
                return
            }
            adoptTableRename(ref, to: newName)
            await refreshTables()
        }
    }

    func renameContainer(_ ref: DatabaseContainerRef, to newName: String) {
        Task { [weak self] in
            guard let self else { return }
            guard await authorizeRename(
                describing: String(format: String(localized: "Rename %1$@ to %2$@"), ref.name, newName)
            ) else { return }

            do {
                try await performContainerRename(ref, to: newName)
            } catch {
                presentRenameFailure(error, object: ref.id)
                return
            }
            adoptContainerRename(ref, to: newName)
            await DatabaseTreeMetadataService.shared.refreshDatabases(
                connectionId: connectionId,
                databaseType: connection.type
            )
            if ref.kind == .schema, let database = ref.database {
                await DatabaseTreeMetadataService.shared.refreshSchemas(
                    connectionId: connectionId,
                    database: database
                )
            }
        }
    }

    private func performContainerRename(_ ref: DatabaseContainerRef, to newName: String) async throws {
        switch ref.kind {
        case .database:
            /// Renaming a database runs from a connection that is not on it, which the menu already
            /// guarantees by keeping the item off the browsed row. The metadata pool is the other
            /// way a backend stays attached to it, and PostgreSQL refuses the statement while one
            /// is, so its leases on that database are closed first.
            if let database = ref.database {
                MetadataConnectionPool.shared.closeAll(connectionId: connectionId, database: database)
            }
            guard let scope = browseScope else { throw DatabaseError.notConnected }
            let route = DatabaseManager.shared.executionRoute(for: scope)
            let name = ref.name
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope, route: route, cancellation: .protectedWrite
            ) { driver in
                try await driver.renameDatabase(name: name, to: newName)
            }
        case .schema:
            guard let scope = DatabaseManager.shared.resolvedScope(
                database: ref.database, schema: nil, for: connectionId
            ) else {
                throw DatabaseError.notConnected
            }
            let name = ref.name
            try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.renameSchema(name: name, to: newName)
            }
        }
    }

    /// A rename is a schema mutation, so it goes through the same gate as every other one. The
    /// menu only hides the item under read-only safe mode; the Alert and Touch ID levels are the
    /// gate's to enforce, and the audit record is written from here too.
    ///
    /// No SQL travels with the request because the driver runs the rename rather than generating a
    /// statement, and for MongoDB and SQL Server there is no statement to show. The two names are
    /// what the user is being asked to approve, and the description carries both.
    private func authorizeRename(describing description: String) async -> Bool {
        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: connectionId,
                databaseType: connection.type,
                sql: nil,
                kind: .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: description
            )
        )
        guard case .authorized = decision else {
            if let reason = decision.deniedReason {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Rename Failed"),
                    message: reason,
                    window: contentWindow
                )
            }
            return false
        }
        return true
    }

    private func presentRenameFailure(_ error: Error, object: String = "") {
        renameLogger.error(
            "Rename failed for \(object, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        AlertHelper.showErrorSheet(
            title: String(localized: "Rename Failed"),
            message: error.localizedDescription,
            window: contentWindow
        )
    }

    private func qualifiedLabel(_ ref: DatabaseTreeTableRef) -> String {
        guard let schema = ref.qualifyingSchema else { return ref.table.name }
        return "\(schema).\(ref.table.name)"
    }
}

/// The `DROP` and `ALTER` keyword for an object kind, in one place because the rename and the drop
/// have to spell the same object the same way.
enum TableObjectKeyword {
    static func forDDL(_ type: TableInfo.TableType) -> String {
        switch type {
        case .view:
            return "VIEW"
        case .materializedView:
            return "MATERIALIZED VIEW"
        case .foreignTable:
            return "FOREIGN TABLE"
        case .table, .systemTable, .partitionedTable, .externalTable:
            return "TABLE"
        }
    }
}
