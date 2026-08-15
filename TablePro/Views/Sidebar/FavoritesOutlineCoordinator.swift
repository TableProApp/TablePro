//
//  FavoritesOutlineCoordinator.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class FavoritesOutlineCoordinator<Row: View>: NSObject, NSOutlineViewDataSource,
    NSOutlineViewDelegate, FavoritesOutlineKeyHandling {
    private static var cellIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("FavoritesOutlineCell")
    }

    private var owner: FavoritesOutlineView<Row>
    private weak var outlineView: NSOutlineView?
    private let rename = FavoriteFolderRenameOverlay()

    /// Keyed by id and mutated in place, never rebuilt, so `NSOutlineView` keeps the row identity a
    /// reload would otherwise throw away along with the user's expansion and selection.
    private var nodeCache: [String: FavoritesOutlineNode] = [:]
    private var childrenCache: [String: [FavoritesOutlineNode]] = [:]
    private var isSyncingSelection = false
    private var isReloading = false
    private var isApplyingExpansion = false
    private var lastInputFingerprint = ""

    internal init(owner: FavoritesOutlineView<Row>) {
        self.owner = owner
        super.init()
    }

    internal func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        rename.onCommit = { [weak self] folder, name in self?.owner.actions.commitRename(folder, name) }
        rename.onCancel = { [weak self] in self?.owner.actions.cancelRename() }
        lastInputFingerprint = Self.fingerprint(of: owner.input)
        reload()
    }

    internal func update(owner: FavoritesOutlineView<Row>) {
        self.owner = owner
        let fingerprint = Self.fingerprint(of: owner.input)
        if fingerprint != lastInputFingerprint {
            lastInputFingerprint = fingerprint
            reload()
        } else {
            refreshVisibleRows()
        }
        applySelection()
        applyRenameState()
    }

    /// Rebuilding on every SwiftUI pass would throw away the hosted views on each keystroke, so the
    /// outline reloads only when the set of rows or their nesting changed. Depth is part of the
    /// fingerprint because moving a favorite into a folder can leave the pre-order id list identical.
    private static func fingerprint(of input: FavoritesOutlineInput) -> String {
        var parts: [String] = [input.activeDatabase ?? ""]
        parts += input.tables.map(\.id)
        parts += input.queryNodes.flatMap { Self.identifiers(of: $0, depth: 0) }
        parts += input.teamQueries.map(\.id)
        return parts.joined(separator: "\u{1}")
    }

    private static func identifiers(of node: FavoriteNode, depth: Int) -> [String] {
        ["\(depth)|\(node.id)"] + (node.children ?? []).flatMap { Self.identifiers(of: $0, depth: depth + 1) }
    }

    private func reload() {
        guard let outlineView else { return }
        isReloading = true
        childrenCache.removeAll()
        outlineView.reloadData()
        applyExpansion()
        applySelection()
        rename.reposition(in: outlineView)
        isReloading = false
    }

    /// The rows are the same rows, but their contents may not be: renaming a folder or editing a
    /// saved query keeps every id, so the cached nodes are re-derived from the current input before
    /// anything is drawn. Reading the payload back out of the outline would redraw the stale copy.
    private func refreshVisibleRows() {
        guard let outlineView else { return }
        refreshNodePayloads()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FavoritesOutlineNode,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? FavoritesOutlineCellView<Row> else { continue }
            cell.update(rootView: owner.row(node))
        }
    }

    private func refreshNodePayloads() {
        childrenCache.removeAll()
        refreshNodePayloads(of: children(of: nil))
    }

    private func refreshNodePayloads(of nodes: [FavoritesOutlineNode]) {
        for node in nodes where node.isExpandable {
            refreshNodePayloads(of: children(of: node))
        }
    }

    private func node(id: String, kind: FavoritesOutlineNode.Kind) -> FavoritesOutlineNode {
        if let existing = nodeCache[id] {
            existing.kind = kind
            return existing
        }
        let created = FavoritesOutlineNode(id: id, kind: kind)
        nodeCache[id] = created
        return created
    }

    private func children(of parent: FavoritesOutlineNode?) -> [FavoritesOutlineNode] {
        let key = parent?.id ?? ""
        if let cached = childrenCache[key] { return cached }
        let built = build(children: parent)
        childrenCache[key] = built
        return built
    }

    private func build(children parent: FavoritesOutlineNode?) -> [FavoritesOutlineNode] {
        guard let parent else { return rootNodes() }
        guard case .query(let favoriteNode) = parent.kind, let kids = favoriteNode.children else { return [] }
        return kids.map { node(id: $0.id, kind: .query($0)) }
    }

    private func rootNodes() -> [FavoritesOutlineNode] {
        var nodes: [FavoritesOutlineNode] = []
        if !owner.input.tables.isEmpty {
            nodes.append(node(id: FavoritesOutlineNode.tablesHeaderId, kind: .header(String(localized: "Tables"))))
            nodes += owner.input.tables.map { table in
                let id = FavoritesOutlineNode.tableId(
                    database: owner.input.activeDatabase, schema: table.schema, name: table.name
                )
                return node(id: id, kind: .table(table))
            }
        }
        if !owner.input.queryNodes.isEmpty {
            nodes.append(node(id: FavoritesOutlineNode.queriesHeaderId, kind: .header(String(localized: "Queries"))))
            nodes += owner.input.queryNodes.map { node(id: $0.id, kind: .query($0)) }
        }
        if !owner.input.teamQueries.isEmpty {
            nodes.append(node(id: FavoritesOutlineNode.teamHeaderId, kind: .header(String(localized: "Team Library"))))
            nodes += owner.input.teamQueries.map { query in
                node(
                    id: FavoritesOutlineNode.teamQueryId(query.id),
                    kind: .teamQuery(id: query.id, name: query.name, publishedBy: query.publishedBy)
                )
            }
        }
        return nodes
    }

    // MARK: - Expansion

    private func applyExpansion() {
        guard let outlineView else { return }
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        applyExpansion(to: children(of: nil), in: outlineView)
    }

    private func applyExpansion(to nodes: [FavoritesOutlineNode], in outlineView: NSOutlineView) {
        for node in nodes where node.isExpandable {
            guard case .query(let favoriteNode) = node.kind else { continue }
            if FavoritesExpansion.isExpanded(favoriteNode, connectionId: owner.input.connectionId) {
                outlineView.expandItem(node)
                applyExpansion(to: children(of: node), in: outlineView)
            } else {
                outlineView.collapseItem(node)
            }
        }
    }

    internal func outlineViewItemDidExpand(_ notification: Notification) {
        recordExpansion(from: notification, expanded: true)
    }

    internal func outlineViewItemDidCollapse(_ notification: Notification) {
        recordExpansion(from: notification, expanded: false)
    }

    private func recordExpansion(from notification: Notification, expanded: Bool) {
        guard !isApplyingExpansion,
              let node = notification.userInfo?["NSObject"] as? FavoritesOutlineNode,
              case .query(let favoriteNode) = node.kind else { return }
        FavoritesExpansion.setExpanded(favoriteNode, expanded: expanded, connectionId: owner.input.connectionId)
    }

    // MARK: - Selection

    private func applySelection() {
        guard let outlineView else { return }
        guard let selection = owner.selection else {
            guard !outlineView.selectedRowIndexes.isEmpty else { return }
            isSyncingSelection = true
            outlineView.deselectAll(nil)
            isSyncingSelection = false
            return
        }
        let targetId = FavoritesOutlineSelection.nodeId(for: selection)
        guard let node = nodeCache[targetId] else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0, !outlineView.selectedRowIndexes.contains(row) else { return }
        isSyncingSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isSyncingSelection = false
        outlineView.scrollRowToVisible(row)
    }

    internal func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, !isReloading, let outlineView else { return }
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? FavoritesOutlineNode else {
            owner.selection = nil
            return
        }
        /// Selecting is not running. Arrowing through saved queries must never insert or execute
        /// them, so the primary action stays behind a double-click or Return.
        owner.selection = FavoritesOutlineSelection.selection(
            for: node.kind, database: owner.input.activeDatabase
        )
    }

    // MARK: - Actions

    @objc internal func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? FavoritesOutlineNode else { return }
        if node.isExpandable {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
            return
        }
        commitPrimaryAction(for: node)
    }

    internal func performPrimaryAction() {
        guard let node = selectedNode() else { return }
        commitPrimaryAction(for: node)
    }

    private func commitPrimaryAction(for node: FavoritesOutlineNode) {
        guard FavoritesOutlineSelection.isSelectable(node.kind) else { return }
        owner.actions.primaryAction(node.kind)
    }

    internal func performDelete() {
        guard let node = selectedNode() else { return }
        owner.actions.deleteSelection(node.kind)
    }

    private func selectedNode() -> FavoritesOutlineNode? {
        guard let outlineView, outlineView.selectedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.selectedRow) as? FavoritesOutlineNode
    }

    // MARK: - Rename

    private func applyRenameState() {
        guard let outlineView else { return }
        guard let folderId = owner.input.renamingFolderId else {
            rename.dismiss(commit: false)
            return
        }
        guard !rename.isActive,
              let node = nodeCache["folder-\(folderId)"],
              case .query(let favoriteNode) = node.kind,
              let folder = favoriteNode.asFolder else { return }
        rename.begin(node: node, folder: folder, in: outlineView)
    }

    // MARK: - Data source

    internal func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? FavoritesOutlineNode).count
    }

    internal func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? FavoritesOutlineNode)[index]
    }

    internal func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FavoritesOutlineNode)?.isExpandable ?? false
    }

    internal func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FavoritesOutlineNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? FavoritesOutlineCellView<Row> ?? makeCell()
        cell.update(rootView: owner.row(node))
        return cell
    }

    internal func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? FavoritesOutlineNode else { return false }
        return FavoritesOutlineSelection.isSelectable(node.kind)
    }

    /// Tables, Queries and Team Library are buckets rather than objects, so AppKit draws them as
    /// source list group rows. See `DatabaseTreeNode.isSectionHeader` for why that matters beyond
    /// the styling.
    internal func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard case .header = (item as? FavoritesOutlineNode)?.kind else { return false }
        return true
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        typeSelectStringFor tableColumn: NSTableColumn?,
        item: Any
    ) -> String? {
        guard let node = item as? FavoritesOutlineNode else { return nil }
        return FavoritesOutlineSelection.matchString(for: node.kind)
    }

    /// Drag out only, which is all the SwiftUI rows offered. Nothing accepts a drop, so no dragged
    /// types are registered and no reorder is implied.
    internal func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FavoritesOutlineNode, case .query(let favoriteNode) = node.kind else { return nil }
        switch favoriteNode.content {
        case .favorite(let favorite):
            return Self.pasteboardItem(favorite.query)
        case .linkedFavorite(let linked):
            /// `FileTextLoader` walks the same encoding chain the row's own badge is derived from,
            /// so a file the sidebar already flagged as non-UTF-8 still drags.
            guard let loaded = FileTextLoader.load(linked.fileURL) else { return nil }
            return Self.pasteboardItem(loaded.content)
        case .folder, .linkedFolder, .linkedSubfolder:
            return nil
        }
    }

    private static func pasteboardItem(_ string: String) -> NSPasteboardWriting {
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        return item
    }

    private func makeCell() -> FavoritesOutlineCellView<Row> {
        let cell = FavoritesOutlineCellView<Row>()
        cell.identifier = Self.cellIdentifier
        return cell
    }
}
