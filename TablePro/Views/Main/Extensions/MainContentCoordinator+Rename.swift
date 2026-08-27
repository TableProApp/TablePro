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
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                    throw DatabaseError.notConnected
                }
                try await driver.renameTable(
                    name: ref.table.name,
                    schema: ref.qualifyingSchema,
                    to: newName,
                    objectType: objectType
                )
            } catch {
                renameLogger.error(
                    "Rename failed for \(ref.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                AlertHelper.showErrorSheet(
                    title: String(localized: "Rename Failed"),
                    message: error.localizedDescription,
                    window: contentWindow
                )
                return
            }
            adoptTableRename(ref, to: newName)
            await refreshTables()
        }
    }

    func renameContainer(_ ref: DatabaseContainerRef, to newName: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await performContainerRename(ref, to: newName)
            } catch {
                renameLogger.error(
                    "Rename failed for \(ref.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                AlertHelper.showErrorSheet(
                    title: String(localized: "Rename Failed"),
                    message: error.localizedDescription,
                    window: contentWindow
                )
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
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                throw DatabaseError.notConnected
            }
            try await driver.renameDatabase(name: ref.name, to: newName)
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
