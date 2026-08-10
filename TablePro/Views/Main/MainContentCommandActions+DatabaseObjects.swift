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
        coordinator?.openTableTab(object, showStructure: true, activateGridFocus: true)
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

    func runMaintenanceOperation(_ operation: String) {
        guard let object = selectedObject else { return }
        coordinator?.showMaintenanceSheet(operation: operation, tableName: object.name)
    }

    var canCreateDatabase: Bool {
        isConnected && supportsContainerSwitching && !isReadOnly
    }

    func createDatabase() {
        coordinator?.activeSheet = .createDatabase
    }
}
