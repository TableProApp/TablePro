//
//  TableStructureView+EditGate.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension TableStructureView {
    var editGate: StructureEditGate {
        StructureEditGate(
            databaseType: connection.type, objectKind: objectKind, schema: schemaName, isSessionBound: isSessionBound
        )
    }

    var foreignKeyEditAvailability: ForeignKeyEditAvailability {
        ForeignKeyEditPolicy.resolve(
            support: PluginManager.shared.foreignKeyEditSupport(for: connection.type),
            engineName: connection.type.displayName,
            kindRefusal: editGate.kindRefusal(.addForeignKey),
            canEditSchema: editGate.canEditSchema
        )
    }

    func publishFooterCapability() {
        let gate = editGate
        let footer = StructureFooterPolicy.resolve(
            tab: selectedTab,
            canEditSchema: gate.canEditSchema,
            hasSelection: !session.gridModel.selection.isEmpty,
            isSaving: structureChangeManager.isHeldForSave,
            resolve: { gate.resolve($0) }
        )
        // Published on every write, and this runs on every selection change.
        guard session.footer != footer else { return }
        session.footer = footer
    }
}
