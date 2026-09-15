//
//  WelcomeOutlineCoordinator+Interaction.swift
//  TablePro
//

import AppKit
import TableProConnectionLibrary

// MARK: - Rename

extension WelcomeOutlineCoordinator {
    internal func beginRename(_ row: LibraryRowID) {
        guard let outlineView, let item = itemCache[row], let name = viewModel.displayName(for: row) else { return }
        if renameSession != nil {
            endRename(commit: true)
        }
        revealParents(of: item, in: outlineView)
        let index = outlineView.row(forItem: item)
        guard index >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        outlineView.scrollRowToVisible(index)
        outlineView.layoutSubtreeIfNeeded()
        guard let cell = outlineView.view(atColumn: 0, row: index, makeIfNecessary: true)
            as? WelcomeOutlineCellView else { return }

        renameSession = WelcomeRenameSession(row: row, pendingName: name)
        if case .group = row {
            cell.renameSymbolName = "folder"
        } else {
            cell.renameSymbolName = "cylinder"
        }
        cell.beginRename(text: name, delegate: self)
        guard let field = cell.editor else { return }
        outlineView.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    internal func endRename(commit: Bool) {
        guard let session = renameSession else { return }
        renameSession = nil
        var value = session.pendingName
        if let outlineView, let item = itemCache[session.row] {
            let index = outlineView.row(forItem: item)
            if index >= 0,
               let cell = outlineView.view(atColumn: 0, row: index, makeIfNecessary: false) as? WelcomeOutlineCellView {
                value = cell.endRename()
            }
            outlineView.window?.makeFirstResponder(outlineView)
        }
        if commit {
            viewModel.commitRename(session.row, to: value)
        }
        applyPendingReloadIfNeeded()
    }

    private func revealParents(of item: WelcomeOutlineItem, in outlineView: NSOutlineView) {
        let groupId: UUID?
        switch item.row {
        case .group(let id):
            groupId = viewModel.groupGraph.parentId(of: id)
        case .connection(let id, let section):
            groupId = section == .connections ? viewModel.connectionsById[id]?.groupId : nil
        case .section:
            groupId = nil
        }
        guard let groupId else { return }
        for ancestor in viewModel.groupGraph.pathIds(to: groupId) {
            guard let ancestorItem = itemCache[.group(ancestor)] else { continue }
            outlineView.expandItem(ancestorItem)
        }
    }

    internal func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        renameSession?.pendingName = field.stringValue
    }

    internal func controlTextDidEndEditing(_ obj: Notification) {
        guard renameSession != nil else { return }
        endRename(commit: true)
    }

    internal func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endRename(commit: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            (control as? NSTextField)?.abortEditing()
            endRename(commit: false)
            return true
        }
        return false
    }
}

// MARK: - Drag and Drop

extension WelcomeOutlineCoordinator {
    internal func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard renameSession == nil,
              let item = item as? WelcomeOutlineItem,
              let token = WelcomeDragToken.encode(item.row) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(token, forType: .welcomeLibraryRow)
        return pasteboardItem
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        isDragging = true
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        applyPendingReloadIfNeeded()
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let resolution = resolveDrop(info, item: item, childIndex: index),
              retarget(outlineView, to: resolution.target) else { return [] }
        if case .addFavorites = resolution.operation {
            return .copy
        }
        return .move
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let resolution = resolveDrop(info, item: item, childIndex: index) else { return false }
        viewModel.applyDrop(resolution.operation, undoManager: outlineView.undoManager)
        return true
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        shouldCollapseAutoExpandedItemsForDeposited deposited: Bool
    ) -> Bool {
        !deposited
    }

    private func resolveDrop(_ info: NSDraggingInfo, item: Any?, childIndex: Int) -> LibraryDropResolution? {
        let dragged = (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: .welcomeLibraryRow) }
            .compactMap(WelcomeDragToken.decode)
        guard !dragged.isEmpty,
              let target = dropTarget(for: item as? WelcomeOutlineItem, childIndex: childIndex) else { return nil }
        return LibraryDropResolver.resolve(
            items: dragged,
            target: target,
            sortMode: viewModel.sortMode,
            graph: viewModel.groupGraph,
            connections: viewModel.connectionsById,
            outline: viewModel.outline
        )
    }

    private func dropTarget(for item: WelcomeOutlineItem?, childIndex: Int) -> LibraryDropTarget? {
        let index = childIndex >= 0 ? childIndex : nil
        guard let item else {
            return viewModel.showsSectionHeaders ? nil : .section(.connections, childIndex: index)
        }
        switch item.row {
        case .section(let kind):
            return .section(kind, childIndex: index)
        case .group(let id):
            return .group(id, childIndex: index)
        case .connection:
            guard let outlineView else { return nil }
            let position = outlineView.childIndex(forItem: item)
            guard position >= 0 else { return nil }
            return dropTarget(for: outlineView.parent(forItem: item) as? WelcomeOutlineItem, childIndex: position)
        }
    }

    private func retarget(_ outlineView: NSOutlineView, to target: LibraryDropTarget) -> Bool {
        switch target {
        case .section(let kind, let childIndex):
            let item: WelcomeOutlineItem?
            if viewModel.showsSectionHeaders {
                guard let header = itemCache[.section(kind)] else { return false }
                item = header
            } else {
                item = nil
            }
            outlineView.setDropItem(item, dropChildIndex: childIndex ?? NSOutlineViewDropOnItemIndex)
            return true
        case .group(let id, let childIndex):
            guard let groupItem = itemCache[.group(id)] else { return false }
            outlineView.setDropItem(groupItem, dropChildIndex: childIndex ?? NSOutlineViewDropOnItemIndex)
            return true
        }
    }
}
