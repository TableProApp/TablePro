//
//  TableStructureView+EditGate.swift
//  TablePro
//
//  Which structure edits this tab offers, for the object it is open on.
//

import Foundation
import TableProPluginKit

extension TableStructureView {
    /// Every "may this edit be offered" question the tab asks, answered from one place. The footer
    /// pair, the grid's per-column lock, the reorder drag and the grid delegate's own keyboard and
    /// context-menu paths all read this, so none of them can offer an edit another withholds.
    var editGate: StructureEditGate {
        StructureEditGate(databaseType: connection.type, objectKind: objectKind)
    }

    /// Whether this engine can add and remove foreign keys, which is not the same question as
    /// whether it has them. `supportsForeignKeys` answers the second, and reading it as the first
    /// is what offered an enabled "+" on SQLite over a driver with no statement behind it.
    var foreignKeyEditAvailability: ForeignKeyEditAvailability {
        ForeignKeyEditPolicy.resolve(
            support: PluginManager.shared.foreignKeyEditSupport(for: connection.type),
            engineName: connection.type.displayName,
            kindRefusal: editGate.kindRefusal(.addForeignKey),
            canEditSchema: connection.type.supportsSchemaEditing
        )
    }

    /// Published to the tab's own session, which the bottom bar reads. Nothing is cleared on
    /// disappear: the session outlives the view by design, and the bar only reads this while the
    /// tab is showing its structure.
    func publishFooterCapability() {
        let gate = editGate
        session.footer = StructureFooterPolicy.resolve(
            tab: selectedTab,
            canEditSchema: connection.type.supportsSchemaEditing,
            hasSelection: !selectedRows.isEmpty,
            isSaving: structureChangeManager.isHeldForSave,
            resolve: { gate.resolve($0) }
        )
    }

    /// Name-keyed because that is the only handle the grid has: `isColumnWritable` is asked about a
    /// column's heading.
    func lockedStructureColumns(for provider: StructureRowProvider) -> Set<String> {
        let headings = provider.columns
        let locked = editGate.lockedFieldIndices(
            on: selectedTab,
            orderedFields: provider.orderedColumnFields,
            fieldCount: headings.count
        )
        return Set(locked.map { headings[$0] })
    }

    /// Why the Columns grid refuses every keystroke, when it does. A grid that will not take an edit
    /// and says nothing reads as broken, so the pointer carries this as the grid's tooltip.
    var structureEditRefusal: String? {
        if structureChangeManager.isHeldForSave { return StructureFooterPolicy.savingReason }
        guard !editGate.allowsAnyEdit else { return nil }
        return editGate.resolve(.renameColumn).unavailableReason
    }
}
