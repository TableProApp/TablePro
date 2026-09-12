//
//  MainContentCommandActions+DatabaseObjects.swift
//  TablePro
//

import Foundation
import TableProPluginKit

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
        guard let ref = selectedObjectRef, ref.table.type == .view else { return }
        coordinator?.editViewDefinition(ref)
    }

    var canShowObjectDDL: Bool {
        DatabaseObjectToolEligibility.canShowDDL(selectedObject?.type)
    }

    func showObjectDDL() {
        guard let ref = selectedObjectRef,
              let objectRef = DatabaseObjectRef(
                  relation: ref.table,
                  database: ref.database ?? "",
                  schema: ref.qualifyingSchema
              )
        else { return }
        coordinator?.showObjectSource(objectRef)
    }

    func copyObjectDDL() {
        guard let ref = selectedObjectRef, canShowObjectDDL else { return }
        coordinator?.copyDDL(of: ref)
    }

    var canRefreshMaterializedView: Bool {
        DatabaseObjectToolEligibility.canRefresh(
            selectedObject?.type,
            support: objectToolSupport,
            isReadOnly: isReadOnly
        )
    }

    func refreshMaterializedView() {
        guard let ref = selectedObjectRef, canRefreshMaterializedView else { return }
        coordinator?.refreshMaterializedView(ref)
    }

    var canEditObjectComment: Bool {
        DatabaseObjectToolEligibility.canEditComment(
            selectedObject?.type,
            support: objectToolSupport,
            isReadOnly: isReadOnly
        )
    }

    func editObjectComment() {
        guard let ref = selectedObjectRef, canEditObjectComment else { return }
        coordinator?.editComment(of: ref)
    }

    private var objectToolSupport: DatabaseObjectToolEligibility.Support {
        guard let connectionId = coordinator?.connectionId else { return .none }
        return .of(DatabaseManager.shared.driver(for: connectionId))
    }

    /// Narrowed to the selected object's kind, the same rule the sidebar's submenu follows. Asking
    /// only whether something was selected is how the menu bar offered `REINDEX` on a view.
    var maintenanceOperations: [PluginMaintenanceOperation] {
        guard let object = selectedObject else { return [] }
        return TableOperationEligibility.maintenanceOperations(
            coordinator?.maintenanceOperations() ?? [],
            for: object.type
        )
    }

    /// The menu acts on the object browser's selection, and `TableInfo` carries a schema but no
    /// database, so this names only the schema and the command falls back to the database being
    /// browsed. The sidebar's own contextual menu carries the clicked row's database and does not.
    func runMaintenanceOperation(_ operation: PluginMaintenanceOperation) {
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

    /// The menu-bar mirrors of the sidebar's own commands. With no clicked row to carry, both act
    /// on the database being browsed and preselect everything in it.
    var canCopyObjects: Bool {
        guard let coordinator else { return false }
        return isConnected && ObjectCopyEligibility.supportsCopying(
            editorLanguage: PluginManager.shared.editorLanguage(for: coordinator.connection.type)
        )
    }

    var canDuplicateDatabase: Bool {
        guard let coordinator else { return false }
        return isConnected && ObjectCopyEligibility.mayOfferDuplicateDatabase(
            editorLanguage: PluginManager.shared.editorLanguage(for: coordinator.connection.type),
            supportsDatabaseSwitching: PluginManager.shared.supportsDatabaseSwitching(
                for: coordinator.connection.type
            ),
            isReadOnly: isReadOnly
        )
    }

    func copyObjectsToAnotherDatabase() {
        coordinator?.openCopyObjects(mode: .copyTo, database: nil, schema: nil, objects: [])
    }

    func duplicateCurrentDatabase() {
        coordinator?.openCopyObjects(mode: .duplicateDatabase, database: nil, schema: nil, objects: [])
    }
}

@MainActor
internal extension MainContentCoordinator {
    /// Opens Copy To or Duplicate Database on the row that was right-clicked.
    ///
    /// The database and the schema travel with the request rather than being read from the browsing
    /// state, for the reason every other sidebar command carries its ref: the tree can show a
    /// database the session is not currently on, and copying from the wrong one is silent.
    func openCopyObjects(
        mode: ObjectCopyMode,
        database: String?,
        schema: String?,
        objects: [ObjectCopySelection]
    ) {
        let source = DatabaseEndpoint.from(
            connection: connection,
            database: database ?? browseDatabaseName,
            schema: schema
        )
        activeSheet = .copyObjects(ObjectCopyLaunchRequest(
            mode: mode, source: source, preselected: objects
        ))
    }
}
