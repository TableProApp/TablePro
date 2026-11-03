//
//  MainContentCommandActions+DatabaseObjects.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Menu commands use the selected object; contextual menus carry their clicked row.
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
        guard let ref = selectedObjectRef, ref.table.type == .view, let coordinator else { return false }
        return !ref.isInAttachedDatabase(of: coordinator.connection.type)
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
        guard coordinator?.admitsSheetCommand() == true else { return }
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
        guard coordinator?.admitsSheetCommand() == true, let ref = selectedObjectRef, canEditObjectComment
        else { return }
        coordinator?.editComment(of: ref)
    }

    var canSetSequenceNextValue: Bool {
        DatabaseObjectToolEligibility.canSetSequenceValue(
            selectedObject?.type,
            support: objectToolSupport,
            isReadOnly: isReadOnly
        )
    }

    func setSequenceNextValue() {
        guard coordinator?.admitsSheetCommand() == true, let ref = selectedObjectRef, canSetSequenceNextValue
        else { return }
        coordinator?.setSequenceNextValue(of: ref)
    }

    var canEditSequence: Bool {
        DatabaseObjectToolEligibility.canEditSequence(
            selectedObject?.type,
            support: objectToolSupport,
            isReadOnly: isReadOnly
        )
    }

    func editSequence() {
        guard coordinator?.admitsSheetCommand() == true, let ref = selectedObjectRef, canEditSequence else { return }
        coordinator?.editSequence(ref)
    }

    private var objectToolSupport: DatabaseObjectToolEligibility.Support {
        guard let connectionId = coordinator?.connectionId else { return .none }
        return .of(DatabaseManager.shared.driver(for: connectionId))
    }

    // Match the sidebar submenu by checking the selected object kind.
    var maintenanceOperations: [PluginMaintenanceOperation] {
        guard let object = selectedObject else { return [] }
        return TableOperationEligibility.maintenanceOperations(
            coordinator?.maintenanceOperations() ?? [],
            for: object.type
        )
    }

    // Names only the schema: `TableInfo` carries no database, so the command falls back to the one being browsed.
    func runMaintenanceOperation(_ operation: PluginMaintenanceOperation) {
        guard coordinator?.admitsSheetCommand() == true, let object = selectedObject else { return }
        coordinator?.showMaintenanceSheet(
            operation: operation, tableName: object.name, schema: object.schema
        )
    }

    var canCreateDatabase: Bool {
        isConnected && supportsContainerSwitching && !isReadOnly
    }

    var canCreateTable: Bool {
        guard isConnected, !isReadOnly, let coordinator else { return false }
        return CreateTableEligibility.canCreateTable(
            with: DatabaseManager.shared.driver(for: coordinator.connection.id)
        )
    }

    var canCreateView: Bool {
        guard isConnected, !isReadOnly, let coordinator else { return false }
        return CreateViewEligibility.canCreateView(
            with: DatabaseManager.shared.driver(for: coordinator.connection.id)
        )
    }

    var canCreateSequence: Bool {
        guard isConnected, !isReadOnly, let coordinator else { return false }
        return DatabaseManager.shared.driver(for: coordinator.connection.id)?.createSequenceTemplate() != nil
    }

    var canCreateSchema: Bool {
        guard isConnected, let coordinator else { return false }
        return SchemaEditEligibility.canCreate(context: coordinator.schemaEditContext)
    }

    func createDatabase() {
        guard coordinator?.admitsSheetCommand() == true else { return }
        coordinator?.createDatabase()
    }

    // Without a clicked row, these commands use the browsed scope.
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
        guard coordinator?.admitsSheetCommand() == true else { return }
        coordinator?.openCopyObjects(mode: .copyTo, database: nil, schema: nil, preselection: .wholeScope)
    }

    func duplicateCurrentDatabase() {
        guard coordinator?.admitsSheetCommand() == true else { return }
        coordinator?.openCopyObjects(mode: .duplicateDatabase, database: nil, schema: nil, preselection: .wholeScope)
    }

    var canSearchDatabase: Bool {
        isConnected && coordinator?.canSearchDatabase == true
    }

    func searchDatabase() {
        guard coordinator?.admitsSheetCommand() == true else { return }
        coordinator?.openDatabaseSearch(database: nil, schema: nil)
    }
}

@MainActor
internal extension MainContentCoordinator {
    // Opens Copy To or Duplicate Database on the row that was right-clicked.
    func openCopyObjects(
        mode: ObjectCopyMode,
        database: String?,
        schema: String?,
        preselection: ObjectCopyPreselection
    ) {
        let source = DatabaseEndpoint.from(
            connection: connection,
            database: database ?? browseDatabaseName,
            schema: schema
        )
        activeSheet = .copyObjects(ObjectCopyLaunchRequest(
            mode: mode, source: source, preselection: preselection
        ))
    }
}
