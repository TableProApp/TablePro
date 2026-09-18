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
            resolve: { gate.resolve($0) }
        )
    }

    /// The Columns grid's headings for the fields this object's kind will not let the user change.
    ///
    /// Name-keyed because that is the only handle the grid has: `isColumnWritable` is asked about a
    /// column's heading, and the Columns grid's headings are exactly
    /// `orderedColumnFields.map(\.displayName)`. Empty on every tab but Columns, whose rows are the
    /// only ones that describe a column.
    var lockedStructureColumns: Set<String> {
        guard selectedTab == .columns else { return [] }
        let editable = editGate.editableColumnFields
        let locked = StructureColumnField.allCases.filter { !editable.contains($0) }
        /// `displayName` is a `String(localized:)` lookup per field, and this is read on every body
        /// evaluation. A table locks nothing, which is the overwhelmingly common case, so it never
        /// pays for twelve of them.
        guard !locked.isEmpty else { return [] }
        return Set(locked.map(\.displayName))
    }

    /// Why the Columns grid refuses every keystroke, when it does. A grid that will not take an edit
    /// and says nothing reads as broken, so the pointer carries this as the grid's tooltip.
    var structureEditRefusal: String? {
        guard !editGate.allowsAnyEdit else { return nil }
        return editGate.resolve(.renameColumn).unavailableReason
    }
}
