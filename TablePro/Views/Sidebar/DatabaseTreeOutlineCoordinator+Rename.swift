//
//  DatabaseTreeOutlineCoordinator+Rename.swift
//  TablePro
//

import AppKit

/// Renaming a row of the object tree in the cell's own field.
///
/// The `NSTextFieldDelegate` conformance itself lives on the main declaration, because the
/// callbacks are `@objc` and reach the coordinator rather than this extension.
extension DatabaseTreeOutlineCoordinator {
    /// `isRecentRow` is the clicked row, not the object. A table is drawn twice when it is also in
    /// Recent, and editing the section row instead would put the field on a row the user did not
    /// click, or on no row at all while that section is collapsed.
    internal func beginRename(_ target: DatabaseTreeRenameSession.Target, isRecentRow: Bool = false) {
        guard let outlineView else { return }
        endRename(commit: false)

        let nodeId: String
        let name: String
        switch target {
        case .table(let ref):
            nodeId = isRecentRow ? DatabaseTreeNode.recentTableId(ref) : DatabaseTreeNode.tableId(ref)
            name = ref.table.name
        case .container(let ref):
            nodeId = ref.kind == .schema
                ? DatabaseTreeNode.schemaId(database: ref.database ?? "", schema: ref.schema ?? "")
                : DatabaseTreeNode.databaseId(ref.database ?? "")
            name = ref.name
        }

        let row = outlineView.row(forItem: nodeCache[nodeId])
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        outlineView.layoutSubtreeIfNeeded()
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? DatabaseTreeCellView else { return }

        renameSession = DatabaseTreeRenameSession(
            target: target, nodeId: nodeId, originalName: name, pendingName: name
        )
        cell.beginRename(text: name, delegate: self)
        focus(cell)
    }

    /// Re-installs a live edit after a reload, which drops every cell view. The typed value is
    /// carried across so a refresh from another window does not swallow what the user has entered.
    internal func restoreRenameAfterReload() {
        guard let session = renameSession else { return }
        guard let cell = renameCell(forNodeId: session.nodeId) else {
            endRename(commit: false)
            return
        }
        guard !cell.isRenaming else { return }
        cell.beginRename(text: session.pendingName ?? session.originalName, delegate: self)
        focus(cell)
    }

    internal func endRename(commit: Bool) {
        guard let session = renameSession else { return }
        renameSession = nil

        /// The field is the authority while it exists. `pendingName` is the fallback for the case
        /// where the row has already gone, which is the only way there is no field left to ask.
        var typed = session.pendingName ?? session.originalName
        if let cell = renameCell(forNodeId: session.nodeId) {
            typed = cell.endRename()
            outlineView?.window?.makeFirstResponder(outlineView)
        }

        guard commit,
              case .commit(let newName) = RenameNameDecision.decide(
                  typed: typed, original: session.originalName
              )
        else { return }

        switch session.target {
        case .table(let ref):
            mainCoordinator?.renameTable(ref, to: newName)
        case .container(let ref):
            mainCoordinator?.renameContainer(ref, to: newName)
        }
    }

    private func focus(_ cell: DatabaseTreeCellView) {
        guard let field = cell.editor else { return }
        outlineView?.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func renameCell(forNodeId nodeId: String) -> DatabaseTreeCellView? {
        guard let outlineView, let node = nodeCache[nodeId] else { return nil }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return nil }
        return outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DatabaseTreeCellView
    }
}
