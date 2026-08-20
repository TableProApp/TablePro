//
//  MainContentCommandActions+DatabaseObjects.swift
//  TablePro
//

import Foundation

/// Commands that act on the object selected in the sidebar. The sidebar's own
/// context menu reaches the same coordinator methods, so the menu bar is a second
/// path to them rather than a second implementation.
extension MainContentCommandActions {
    var canShowTableStructure: Bool {
        selectedObject != nil
    }

    func showTableStructure() {
        guard let object = selectedObject else { return }
        coordinator?.openTableTab(
            object, showStructure: true, forceNonPreview: true, activateGridFocus: true
        )
    }

    var canEditViewDefinition: Bool {
        selectedObject?.type == .view
    }

    func editViewDefinition() {
        guard let object = selectedObject, object.type == .view else { return }
        coordinator?.editViewDefinition(object.name)
    }

    var maintenanceOperations: [String] {
        guard selectedObject != nil else { return [] }
        return coordinator?.supportedMaintenanceOperations() ?? []
    }

    /// The menu acts on the object browser's selection, and `TableInfo` carries a schema but no
    /// database, so this names only the schema and the command falls back to the database being
    /// browsed. The sidebar's own contextual menu carries the clicked row's database and does not.
    func runMaintenanceOperation(_ operation: String) {
        guard let object = selectedObject else { return }
        coordinator?.showMaintenanceSheet(
            operation: operation, tableName: object.name, schema: object.schema
        )
    }

    var canCreateDatabase: Bool {
        isConnected && supportsContainerSwitching && !isReadOnly
    }

    func createDatabase() {
        coordinator?.activeSheet = .createDatabase
    }
}
