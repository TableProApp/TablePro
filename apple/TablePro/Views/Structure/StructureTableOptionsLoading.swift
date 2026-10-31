//
//  StructureTableOptionsLoading.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

internal extension StructureEditingSession {
    // The driver's statement probe decides, never the engine's type. A temporary table is left out: its
    // options are not in the shared catalog the read goes to, and the tab is read-only there anyway.
    var offersTableOptionsTab: Bool {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return false }
        let gate = StructureEditGate(
            databaseType: connection.type, objectKind: objectKind, schema: schemaName, isSessionBound: isSessionBound
        )
        return gate.canEditSchema && DatabaseObjectToolEligibility.offersTableOptions(driver: driver, objectKind: objectKind)
    }

    var needsTableOptionsCatalog: Bool {
        if offersTableOptionsTab { return true }
        return StructureRowProvider
            .orderedFields(for: connection.type, additionalFields: [.primaryKey], serverSupport: serverSupport)
            .contains(where: ColumnCharacterSetMenus.isCharacterSetField)
    }

    func readTableOptions(provider: any ScopedMetadataProviding = DatabaseManager.shared) async {
        guard offersTableOptionsTab else { return }
        beginTableOptionsLoad()
        let loader = TableStructureLoader(scope: scope, tableName: tableName, provider: provider)
        let outcome: MetadataFetchOutcome<TableOptions?>
        do {
            outcome = .fetched(try await loader.tableOptions())
        } catch {
            outcome = Self.failedRead(error, of: "table options")
        }
        settleTableOptions(outcome)
    }

    // Server-wide, so it is read once for the tab and again only after a failure. The session owns the read, so a
    // view task cancelled by a tab switch neither cancels it nor leaves the returning view waiting on nothing.
    func readTableOptionsCatalog(provider: any ScopedMetadataProviding = DatabaseManager.shared) async {
        if case .loaded = tableOptionsCatalog { return }
        if let tableOptionsCatalogRead {
            await tableOptionsCatalogRead.value
            return
        }
        beginTableOptionsCatalogLoad()
        let loader = TableStructureLoader(scope: scope, tableName: tableName, provider: provider)
        let read = Task { [weak self] in
            let outcome: MetadataFetchOutcome<TableOptionsCatalog?>
            do {
                outcome = .fetched(try await loader.tableOptionsCatalog())
            } catch {
                outcome = Self.failedRead(error, of: "character set catalog")
            }
            self?.settleTableOptionsCatalog(outcome)
            self?.tableOptionsCatalogRead = nil
        }
        tableOptionsCatalogRead = read
        await read.value
    }

    private static func failedRead<Value: Sendable>(_ error: any Error, of what: String) -> MetadataFetchOutcome<Value> {
        switch StructureFetchFailure(error, taskIsCancelled: Task.isCancelled) {
        case .cancelled:
            return .cancelled
        case .failed(let message):
            logger.error("Failed to load the \(what, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return .failed(message)
        }
    }
}
