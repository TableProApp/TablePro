//
//  FavoritesOutlineCoordinator+Rename.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Renaming a folder in place, in the cell's own field.
///
/// The `NSTextFieldDelegate` conformance itself lives on the main declaration: a generic class
/// cannot adopt an `@objc` protocol from an extension.
extension FavoritesOutlineCoordinator {
    internal func applyRenameState() {
        guard let outlineView else { return }
        switch FavoritesRenameResolver.decide(
            session: renameSession,
            requestedFolderId: owner.input.renamingFolderId,
            nodeIds: Set(visibleNodeIds())
        ) {
        case .keep:
            return
        case .cancel:
            endRename(commit: false)
        case .begin(let nodeId):
            guard let folderId = owner.input.renamingFolderId else { return }
            beginRename(folderId: folderId, nodeId: nodeId, in: outlineView)
        }
    }

    /// Re-installs a live edit after a reload, which drops every cell view. The typed value is
    /// carried across so a refresh from another window does not swallow what the user has entered.
    internal func restoreRenameAfterReload() {
        guard let session = renameSession, let outlineView else { return }
        guard let cell = cell(forNodeId: session.nodeId, in: outlineView) else {
            endRename(commit: false)
            return
        }
        guard !cell.isRenaming else { return }
        cell.beginRename(text: session.pendingName ?? "", delegate: self)
        focus(cell, in: outlineView)
    }

    private func beginRename(folderId: UUID, nodeId: String, in outlineView: NSOutlineView) {
        guard let node = node(forId: nodeId),
              case .query(let favoriteNode) = node.kind,
              let folder = favoriteNode.asFolder else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        outlineView.layoutSubtreeIfNeeded()
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? FavoritesOutlineCellView<Row> else { return }
        renameSession = FavoritesRenameSession(
            folderId: folderId, nodeId: nodeId, pendingName: folder.name
        )
        cell.beginRename(text: folder.name, delegate: self)
        focus(cell, in: outlineView)
    }

    private func focus(_ cell: FavoritesOutlineCellView<Row>, in outlineView: NSOutlineView) {
        guard let field = cell.editor else { return }
        outlineView.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    internal func endRename(commit: Bool) {
        guard let session = renameSession else { return }
        renameSession = nil
        /// The field is the authority while it exists. `pendingName` is the fallback for the case
        /// where the row has already gone, which is the only way there is no field left to ask.
        var value = session.pendingName ?? ""
        if let outlineView, let cell = cell(forNodeId: session.nodeId, in: outlineView) {
            value = cell.endRename()
            outlineView.window?.makeFirstResponder(outlineView)
        }
        guard commit,
              let node = node(forId: session.nodeId),
              case .query(let favoriteNode) = node.kind,
              let folder = favoriteNode.asFolder else {
            owner.actions.cancelRename()
            return
        }
        owner.actions.commitRename(folder, value)
    }

    private func cell(
        forNodeId nodeId: String,
        in outlineView: NSOutlineView
    ) -> FavoritesOutlineCellView<Row>? {
        guard let node = node(forId: nodeId) else { return nil }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return nil }
        return outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? FavoritesOutlineCellView<Row>
    }
}
