//
//  DatabaseTreeOutlineCoordinator+Drag.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension NSPasteboard.PasteboardType {
    static let tableProSidebarObject = NSPasteboard.PasteboardType("com.tablepro.sidebar-object")
}

/// A dragged table or view, named by the connection it belongs to and its row. The connection is
/// part of it because two windows can show the same table id for two different connections.
internal struct SidebarObjectDragToken: Equatable {
    internal let connectionId: UUID
    internal let nodeId: String

    private static let separator: Character = "\u{1}"

    internal var encoded: String {
        connectionId.uuidString + String(Self.separator) + nodeId
    }

    internal init(connectionId: UUID, nodeId: String) {
        self.connectionId = connectionId
        self.nodeId = nodeId
    }

    internal init?(encoded: String) {
        guard let split = encoded.firstIndex(of: Self.separator),
              let connectionId = UUID(uuidString: String(encoded[..<split])) else { return nil }
        self.connectionId = connectionId
        self.nodeId = String(encoded[encoded.index(after: split)...])
    }
}

/// Dragging tables and views into a folder, or out of one onto their kind section.
///
/// A drop always lands on the folder or the section, never between two rows, because both list
/// their objects by name and a position the user picked could not be kept. That is the retargeting
/// the `NSOutlineView` header describes for a sorted list.
extension DatabaseTreeOutlineCoordinator {
    internal func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard renameSession == nil,
              let node = item as? DatabaseTreeNode,
              case .table = node.kind else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(
            SidebarObjectDragToken(connectionId: connectionId, nodeId: node.id).encoded,
            forType: .tableProSidebarObject
        )
        return pasteboardItem
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        isDragging = true
        let refs = draggedItems.compactMap { ($0 as? DatabaseTreeNode)?.tableRef }
        draggedFolderItems = folderDragItems(for: refs)
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        draggedFolderItems = nil
        applyDeferredReloadIfNeeded()
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let drop = resolveFolderDrop(info, proposedItem: item) else { return [] }
        outlineView.setDropItem(drop.targetNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let drop = resolveFolderDrop(info, proposedItem: item) else { return false }
        switch drop.operation {
        case .file(let names, let scope, let folderId):
            guard let folder = tableFolderStorage.folder(id: folderId, connectionId: scope.connectionId) else {
                return false
            }
            fileObjects(named: names, into: folder)
        case .unfile(let names, let scope):
            unfileObjects(named: names, in: scope)
        }
        return true
    }

    /// A folder a hover opened stays open when the drop landed in it, and closes again when the drag
    /// only passed over it.
    internal func outlineView(
        _ outlineView: NSOutlineView,
        shouldCollapseAutoExpandedItemsForDeposited deposited: Bool
    ) -> Bool {
        !deposited
    }

    private func resolveFolderDrop(
        _ info: NSDraggingInfo,
        proposedItem: Any?
    ) -> (targetNode: DatabaseTreeNode, operation: TableFolderDropOperation)? {
        guard let items = draggedFolderItems ?? folderDragItems(for: draggedObjects(info)),
              let targetNode = dropTargetNode(for: proposedItem as? DatabaseTreeNode),
              let target = dropTarget(of: targetNode),
              let operation = TableFolderDropResolver.resolve(items: items, target: target) else { return nil }
        return (targetNode, operation)
    }

    /// Nil when any dragged object cannot be placed, which refuses the drop whole. One layout is
    /// read per database or schema, however many rows the drag carries.
    private func folderDragItems(for refs: [DatabaseTreeTableRef]) -> [TableFolderDragItem]? {
        guard !refs.isEmpty else { return nil }
        var layouts: [DatabaseScope: TableFolderLayout] = [:]
        var items: [TableFolderDragItem] = []
        for ref in refs {
            guard let scope = folderScope(of: ref) else { return nil }
            let layout = layouts[scope] ?? tableFolderStorage.layout(in: scope)
            layouts[scope] = layout
            items.append(TableFolderDragItem(name: ref.table.name, scope: scope, folderId: layout.placements[ref.table.name]))
        }
        return items
    }

    private func draggedObjects(_ info: NSDraggingInfo) -> [DatabaseTreeTableRef] {
        (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: .tableProSidebarObject) }
            .compactMap(SidebarObjectDragToken.init(encoded:))
            .filter { $0.connectionId == connectionId }
            .compactMap { nodeCache[$0.nodeId]?.tableRef }
    }

    /// A row inside a folder or a section stands for the folder or section that holds it, the
    /// "No items" row of an empty folder included.
    private func dropTargetNode(for node: DatabaseTreeNode?) -> DatabaseTreeNode? {
        guard let node else { return nil }
        switch node.kind {
        case .tableFolder, .objectKindSection, .containerObjectKindSection:
            return node
        case .table, .partition, .status:
            return dropTargetNode(for: outlineView?.parent(forItem: node) as? DatabaseTreeNode)
        default:
            return nil
        }
    }

    private func dropTarget(of node: DatabaseTreeNode) -> TableFolderDropTarget? {
        switch node.kind {
        case .tableFolder(let ref):
            return .folder(ref.folder)
        case .objectKindSection(let kind) where kind.category == .table:
            return folderScope(for: .browsed).map(TableFolderDropTarget.unfiled)
        case .containerObjectKindSection(let group) where group.kind.category == .table:
            let container = TableFolderContainer.container(database: group.database.nilIfEmpty, schema: group.schema)
            return folderScope(for: container).map(TableFolderDropTarget.unfiled)
        default:
            return nil
        }
    }
}
