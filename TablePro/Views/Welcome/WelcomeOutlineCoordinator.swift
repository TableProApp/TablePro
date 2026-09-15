//
//  WelcomeOutlineCoordinator.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProConnectionLibrary

internal struct WelcomeRenameSession: Equatable {
    internal let row: LibraryRowID
    internal var pendingName: String
}

@MainActor
internal final class WelcomeOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate, NSTextFieldDelegate, WelcomeOutlineKeyHandling, WelcomeOutlineControlling {
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("WelcomeOutlineCell")
    private static let sectionRowHeight: CGFloat = 26
    private static let groupRowHeight: CGFloat = 28
    private static let connectionRowHeight: CGFloat = 44

    internal let viewModel: WelcomeViewModel
    internal weak var outlineView: WelcomeNSOutlineView?
    internal var renameSession: WelcomeRenameSession?
    internal var isDragging = false

    internal private(set) var itemCache: [LibraryRowID: WelcomeOutlineItem] = [:]
    private var rootItems: [WelcomeOutlineItem] = []
    private var renderedRevision = -1
    private var hasPendingReload = false
    private var isReloading = false
    private var isApplyingExpansion = false
    private var isSyncingSelection = false

    internal init(viewModel: WelcomeViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    internal func attach(outlineView: WelcomeNSOutlineView) {
        self.outlineView = outlineView
        viewModel.outlineController = self
        reload()
    }

    internal func update(revision: Int) {
        guard revision != renderedRevision else { return }
        guard !isDragging, renameSession == nil else {
            hasPendingReload = true
            return
        }
        reload()
    }

    internal func applyPendingReloadIfNeeded() {
        guard hasPendingReload, !isDragging, renameSession == nil else { return }
        reload()
    }

    private func reload() {
        guard let outlineView else { return }
        renderedRevision = viewModel.outlineRevision
        hasPendingReload = false
        isReloading = true
        rebuildItems()
        outlineView.reloadData()
        applyExpansion()
        restoreSelection()
        isReloading = false
    }

    private func rebuildItems() {
        var used: Set<LibraryRowID> = []
        func item(for row: LibraryRowID) -> WelcomeOutlineItem {
            used.insert(row)
            if let cached = itemCache[row] { return cached }
            let created = WelcomeOutlineItem(row: row)
            itemCache[row] = created
            return created
        }
        func build(_ node: LibraryNode, in section: LibrarySectionKind) -> WelcomeOutlineItem {
            let built = item(for: node.rowID(in: section))
            built.children = node.children.map { build($0, in: section) }
            return built
        }

        let outline = viewModel.outline
        if viewModel.showsSectionHeaders {
            rootItems = outline.sections.map { section in
                let header = item(for: .section(section.kind))
                header.children = section.nodes.map { build($0, in: section.kind) }
                return header
            }
        } else {
            rootItems = outline.sections.flatMap { section in
                section.nodes.map { build($0, in: section.kind) }
            }
        }
        itemCache = itemCache.filter { used.contains($0.key) }
    }

    // MARK: - Expansion

    private func applyExpansion() {
        guard let outlineView else { return }
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        for item in rootItems {
            applyExpansion(item, in: outlineView)
        }
    }

    private func applyExpansion(_ item: WelcomeOutlineItem, in outlineView: NSOutlineView) {
        switch item.row {
        case .section:
            outlineView.expandItem(item)
        case .group(let id):
            guard !item.children.isEmpty else { return }
            guard viewModel.isGroupExpanded(id) else {
                outlineView.collapseItem(item)
                return
            }
            outlineView.expandItem(item)
        case .connection:
            return
        }
        for child in item.children {
            applyExpansion(child, in: outlineView)
        }
    }

    internal func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? WelcomeOutlineItem,
              case .group(let id) = item.row,
              !isApplyingExpansion else { return }
        if !isReloading {
            viewModel.setGroupExpanded(id, true)
        }
        guard let outlineView else { return }
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        for child in item.children {
            applyExpansion(child, in: outlineView)
        }
    }

    internal func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingExpansion, !isReloading,
              let item = notification.userInfo?["NSObject"] as? WelcomeOutlineItem,
              case .group(let id) = item.row else { return }
        viewModel.setGroupExpanded(id, false)
    }

    internal func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        !((item as? WelcomeOutlineItem)?.isSection ?? false)
    }

    internal func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !((item as? WelcomeOutlineItem)?.isSection ?? false)
    }

    // MARK: - Selection

    internal func selectedRows() -> [LibraryRowID] {
        guard let outlineView else { return [] }
        return outlineView.selectedRowIndexes.compactMap { index in
            (outlineView.item(atRow: index) as? WelcomeOutlineItem)?.row
        }
    }

    private func restoreSelection() {
        guard let outlineView else { return }
        let indexes = IndexSet(viewModel.selection.compactMap { itemCache[$0] }
            .map { outlineView.row(forItem: $0) }
            .filter { $0 >= 0 })
        isSyncingSelection = true
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        isSyncingSelection = false
        let rows = selectedRows()
        if rows != viewModel.selection {
            viewModel.selection = rows
        }
    }

    internal func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, !isReloading else { return }
        viewModel.selection = selectedRows()
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        IndexSet(proposedSelectionIndexes.filter { index in
            guard let item = outlineView.item(atRow: index) as? WelcomeOutlineItem else { return false }
            return !item.isSection
        })
    }

    internal func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? WelcomeOutlineItem else { return false }
        return !item.isSection
    }

    internal func rows(including row: Int) -> [LibraryRowID] {
        guard let outlineView else { return [] }
        if outlineView.selectedRowIndexes.contains(row) {
            return selectedRows()
        }
        return (outlineView.item(atRow: row) as? WelcomeOutlineItem).map { [$0.row] } ?? []
    }

    // MARK: - Actions

    @objc internal func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let item = outlineView.item(atRow: outlineView.clickedRow) as? WelcomeOutlineItem else { return }
        switch item.row {
        case .section:
            return
        case .group:
            toggleExpansion(of: item, in: outlineView)
        case .connection:
            viewModel.connect(rows: rows(including: outlineView.clickedRow))
        }
    }

    private func toggleExpansion(of item: WelcomeOutlineItem, in outlineView: NSOutlineView) {
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    internal var canDeleteSelection: Bool {
        viewModel.deleteIntent(for: selectedRows()) != nil
    }

    internal func performPrimaryAction() {
        let rows = selectedRows()
        if rows.count == 1, let row = rows.first, case .group = row,
           let item = itemCache[row], let outlineView {
            toggleExpansion(of: item, in: outlineView)
            return
        }
        viewModel.connect(rows: rows)
    }

    internal func performDelete() {
        viewModel.performDelete(rows: selectedRows())
    }

    internal func clearSelection() {
        outlineView?.deselectAll(nil)
    }

    internal var outlineUndoManager: UndoManager? {
        outlineView?.undoManager
    }

    internal func focusList(selectFirstRow: Bool) {
        guard let outlineView, let window = outlineView.window else { return }
        window.makeFirstResponder(outlineView)
        guard selectFirstRow, outlineView.selectedRowIndexes.isEmpty else { return }
        let firstSelectable = (0..<outlineView.numberOfRows).first { index in
            guard let item = outlineView.item(atRow: index) as? WelcomeOutlineItem else { return false }
            return !item.isSection
        }
        guard let firstSelectable else { return }
        outlineView.selectRowIndexes(IndexSet(integer: firstSelectable), byExtendingSelection: false)
        outlineView.scrollRowToVisible(firstSelectable)
    }

    // MARK: - Menu

    internal func menuNeedsUpdate(_ menu: NSMenu) {
        guard let outlineView else { return }
        let clicked = outlineView.clickedRow
        let rows = clicked >= 0 ? rows(including: clicked) : []
        SidebarMenuBuilder.fill(
            menu,
            with: WelcomeMenuSpec.sections(for: viewModel.menuContext(for: rows)),
            target: self,
            action: #selector(performMenuCommand(_:))
        )
    }

    @objc internal func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SidebarMenuCommandBox<WelcomeMenuCommand> else { return }
        viewModel.perform(box.command)
    }

    // MARK: - Data Source

    internal func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    internal func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    internal func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? WelcomeOutlineItem else { return false }
        return !item.children.isEmpty
    }

    private func children(of item: Any?) -> [WelcomeOutlineItem] {
        guard let item = item as? WelcomeOutlineItem else { return rootItems }
        return item.children
    }

    // MARK: - Delegate

    internal func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? WelcomeOutlineItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? WelcomeOutlineCellView ?? makeCell()
        if cell.isRenaming, item.row != renameSession?.row {
            cell.endRename()
        }
        cell.update(rootView: WelcomeOutlineRow(model: viewModel.rowModel(for: item.row)))
        return cell
    }

    internal func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? WelcomeOutlineItem)?.isSection ?? false
    }

    internal func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? WelcomeOutlineItem else { return Self.groupRowHeight }
        switch item.row {
        case .section:
            return Self.sectionRowHeight
        case .group:
            return Self.groupRowHeight
        case .connection:
            return Self.connectionRowHeight
        }
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        typeSelectStringFor tableColumn: NSTableColumn?,
        item: Any
    ) -> String? {
        guard let item = item as? WelcomeOutlineItem, !item.isSection else { return nil }
        return viewModel.displayName(for: item.row)
    }

    @objc(tableView:rowActionsForRow:edge:)
    internal func tableView(
        _ tableView: NSTableView,
        rowActionsForRow row: Int,
        edge: NSTableView.RowActionEdge
    ) -> [NSTableViewRowAction] {
        guard let item = (tableView as? NSOutlineView)?.item(atRow: row) as? WelcomeOutlineItem,
              case .connection(let id, let section) = item.row,
              section.acceptsSavedConnections,
              let connection = viewModel.connectionsById[id] else { return [] }
        switch edge {
        case .trailing:
            let delete = NSTableViewRowAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _ in
                self?.viewModel.requestDeleteConnections([id])
            }
            let edit = NSTableViewRowAction(style: .regular, title: String(localized: "Edit")) { _, _ in
                WindowOpener.shared.openConnectionForm(editing: id)
            }
            return [delete, edit]
        case .leading:
            let title = connection.isFavorite
                ? String(localized: "Remove from Favorites")
                : String(localized: "Add to Favorites")
            let favorite = NSTableViewRowAction(style: .regular, title: title) { [weak self] _, _ in
                guard let self else { return }
                self.viewModel.setFavorite([id], !connection.isFavorite, undoManager: self.outlineUndoManager)
            }
            return [favorite]
        @unknown default:
            return []
        }
    }

    private func makeCell() -> WelcomeOutlineCellView {
        let cell = WelcomeOutlineCellView()
        cell.identifier = Self.cellIdentifier
        return cell
    }
}
