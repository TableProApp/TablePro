//
//  TreeOutlineCoordinator.swift
//  TablePro
//

import AppKit

internal struct TreeOutlineContent<Node: FilterableTreeNode> {
    let rootNode: Node
    let searchText: String
    let projection: TreeProjection<Node>
    let documentInfo: TreeDocumentInfo
    let disclosure: TreeDisclosureState
}

@MainActor
internal final class TreeOutlineCoordinator<Node: FilterableTreeNode>: NSObject,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, TreeOutlineCommands {
    internal typealias Item = TreeOutlineItem<Node>

    private static var bulkExpansionThreshold: Int { 64 }

    internal var onSetExpanded: (TreeNodePath, Bool) -> Void = { _, _ in }
    internal var onExpandAll: () -> Void = {}
    internal var onCollapseAll: () -> Void = {}

    internal private(set) weak var outlineView: TreeOutlineView?
    internal private(set) var reloadCount = 0

    private let cache: TreeProjectionCache<Node>
    private var rootNode: Node?
    private var roots: [Item] = []
    private var documentID: Node.ID?
    private var appliedSearchText: String?
    private var appliedExpansion: Set<TreeNodePath>?
    private var fonts: TreeOutlineFonts?
    private var isApplyingExpansion = false
    private var menuRows: [Item] = []

    internal init(cache: TreeProjectionCache<Node>) {
        self.cache = cache
        super.init()
    }

    internal func attach(_ outlineView: TreeOutlineView) {
        self.outlineView = outlineView
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.commands = self
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
    }

    // MARK: - Content

    /// Runs on every SwiftUI update: rows reload only for a new document or query.
    internal func apply(_ content: TreeOutlineContent<Node>, fonts: TreeOutlineFonts) {
        guard let outlineView else { return }
        let isNewDocument = documentID != content.rootNode.id
        let hasNewRows = isNewDocument || appliedSearchText != content.searchText
        rootNode = content.rootNode
        documentID = content.rootNode.id
        appliedSearchText = content.searchText

        if self.fonts != fonts {
            self.fonts = fonts
            outlineView.rowHeight = fonts.rowHeight
            if !hasNewRows { reconfigureVisibleCells() }
        }

        let expansion = Self.expandedPaths(in: content)
        guard hasNewRows else {
            if expansion != appliedExpansion { syncExpansion(to: expansion) }
            return
        }

        let keptSelection = isNewDocument ? [] : selectedPaths()
        outlineView.reclaimKeyboardFromFieldEditor()
        roots = content.projection.nodes.map(Item.init)
        isApplyingExpansion = true
        outlineView.reloadData()
        isApplyingExpansion = false
        reloadCount += 1
        syncExpansion(to: expansion)
        select(keptSelection)
    }

    /// Only containers the outline can show: one inside a closed container has no row yet.
    internal static func expandedPaths(in content: TreeOutlineContent<Node>) -> Set<TreeNodePath> {
        var paths: Set<TreeNodePath> = []
        collectExpanded(content.projection.nodes, content: content, into: &paths)
        return paths
    }

    private static func collectExpanded(
        _ nodes: [Node],
        content: TreeOutlineContent<Node>,
        into paths: inout Set<TreeNodePath>
    ) {
        for node in nodes where node.isContainer {
            let isExpanded = content.disclosure.isExpanded(
                node.path,
                autoRevealedPaths: content.projection.autoRevealedPaths,
                defaultExpandedPaths: content.documentInfo.defaultExpandedPaths,
                isFiltered: content.projection.isFiltered
            )
            guard isExpanded else { continue }
            paths.insert(node.path)
            collectExpanded(node.children, content: content, into: &paths)
        }
    }

    /// Measured at 830 containers: one by one, 118 ms in a batch of updates and 160 ms outside one;
    /// everything at once in a batch, 13 ms. So a large change opens all, then closes the rest.
    private func syncExpansion(to paths: Set<TreeNodePath>) {
        guard let outlineView else { return }
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        outlineView.reclaimKeyboardFromFieldEditor()
        let opening = paths.subtracting(appliedExpansion ?? []).count
        outlineView.beginUpdates()
        if opening > Self.bulkExpansionThreshold {
            outlineView.expandItem(nil, expandChildren: true)
            closeUnwanted(roots, keeping: paths, in: outlineView)
        } else {
            sync(roots, to: paths, in: outlineView)
        }
        outlineView.endUpdates()
        appliedExpansion = paths
    }

    private func sync(_ items: [Item], to paths: Set<TreeNodePath>, in outlineView: TreeOutlineView) {
        for item in items where item.node.isContainer {
            let isWanted = paths.contains(item.path)
            if isWanted != outlineView.isItemExpanded(item) {
                if isWanted {
                    outlineView.expandItem(item)
                } else {
                    close(item, in: outlineView)
                }
            }
            if isWanted { sync(item.children, to: paths, in: outlineView) }
        }
    }

    private func closeUnwanted(_ items: [Item], keeping paths: Set<TreeNodePath>, in outlineView: TreeOutlineView) {
        for item in items where item.node.isContainer {
            if paths.contains(item.path) {
                closeUnwanted(item.children, keeping: paths, in: outlineView)
            } else {
                close(item, in: outlineView)
            }
        }
    }

    /// With the children, or the outline reopens them itself when this row opens again.
    private func close(_ item: Item, in outlineView: TreeOutlineView) {
        outlineView.collapseItem(item, collapseChildren: true)
    }

    private func reconfigureVisibleCells() {
        guard let outlineView, let fonts else { return }
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let item = outlineView.item(atRow: row) as? Item,
                  let cell = rowView.view(atColumn: 0) as? TreeOutlineCellView else { return }
            cell.configure(
                content: item.node.rowContent,
                fonts: fonts,
                accessibilityDescription: item.node.accessibilityDescription
            )
        }
    }

    // MARK: - Selection

    internal func selectedItems() -> [Item] {
        guard let outlineView else { return [] }
        return outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? Item }
    }

    private func selectedPaths() -> Set<TreeNodePath> {
        Set(selectedItems().map(\.path))
    }

    /// `reloadData` keeps selected row numbers, which point at other rows after a filter changes.
    private func select(_ paths: Set<TreeNodePath>) {
        guard let outlineView else { return }
        var rows = IndexSet()
        if !paths.isEmpty {
            for row in 0 ..< outlineView.numberOfRows {
                guard let item = outlineView.item(atRow: row) as? Item, paths.contains(item.path) else { continue }
                rows.insert(row)
            }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: - Commands

    /// Asked on every menu validation, so it stops at the first row that has a value.
    internal var canCopySelection: Bool {
        guard let outlineView else { return false }
        return outlineView.selectedRowIndexes.contains { row in
            (outlineView.item(atRow: row) as? Item)?.node.isTruncationMarker == false
        }
    }

    internal func copySelection() {
        perform(.copyValue, on: selectedItems())
    }

    internal func openSelectedLink() -> Bool {
        let items = selectedItems()
        guard TreeOutlineMenuLayout.link(of: items.map(\.node)) != nil else { return false }
        perform(.openLink, on: items)
        return true
    }

    internal func perform(_ command: TreeOutlineMenuCommand, on items: [Item]) {
        let rows = items.map(\.node)
        switch command {
        case .copyText:
            NSApplication.shared.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case .openLink:
            guard let url = TreeOutlineMenuLayout.link(of: rows) else { return }
            DataLinkPolicy.open(url)
        case .copyLink:
            write(TreeOutlineMenuLayout.link(of: rows)?.absoluteString)
        case .copyValue:
            guard let rootNode else { return }
            write(TreeSelectionText.values(of: rows) { self.cache.sourceNode(at: $0, in: rootNode) })
        case .copyKeyPath:
            write(TreeSelectionText.keyPaths(of: rows))
        case .copyKey:
            write(TreeSelectionText.keys(of: rows))
        case .expandAll:
            onExpandAll()
        case .collapseAll:
            onCollapseAll()
        }
    }

    private func write(_ text: String?) {
        guard let text else { return }
        ClipboardService.shared.writeText(text)
    }

    // MARK: - Menu

    /// The selection when the click landed inside it, the clicked row alone otherwise.
    internal func rows(forMenuAt row: Int) -> [Item] {
        guard let outlineView, row >= 0, let clicked = outlineView.item(atRow: row) as? Item else { return [] }
        return outlineView.selectedRowIndexes.contains(row) ? selectedItems() : [clicked]
    }

    internal func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outlineView else { return }
        fill(menu, for: rows(forMenuAt: outlineView.clickedRow), hasTextSelection: false)
    }

    internal func fieldEditorMenu(forRow row: Int, hasTextSelection: Bool) -> NSMenu? {
        guard let outlineView, row >= 0, let item = outlineView.item(atRow: row) as? Item else { return nil }
        let menu = NSMenu()
        fill(menu, for: [item], hasTextSelection: hasTextSelection)
        return menu.items.isEmpty ? nil : menu
    }

    private func fill(_ menu: NSMenu, for items: [Item], hasTextSelection: Bool) {
        menuRows = items
        let entries = TreeOutlineMenuLayout.entries(for: items.map(\.node), hasTextSelection: hasTextSelection)
        for entry in entries {
            guard case .command(let command) = entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: command.title, action: #selector(performMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = command.rawValue
            menu.addItem(item)
        }
    }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard let command = TreeOutlineMenuCommand(rawValue: sender.tag) else { return }
        perform(command, on: menuRows)
    }

    // MARK: - Data source

    internal func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    internal func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    internal func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.node.isContainer ?? false
    }

    private func children(of item: Any?) -> [Item] {
        (item as? Item)?.children ?? roots
    }

    // MARK: - Delegate

    internal func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item, let fonts else { return nil }
        let reused = outlineView.makeView(withIdentifier: TreeOutlineCellView.reuseIdentifier, owner: nil)
        let cell = reused as? TreeOutlineCellView ?? TreeOutlineCellView(frame: .zero)
        cell.configure(
            content: item.node.rowContent,
            fonts: fonts,
            accessibilityDescription: item.node.accessibilityDescription
        )
        return cell
    }

    internal func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let reused = outlineView.makeView(withIdentifier: TreeOutlineRowView.reuseIdentifier, owner: nil)
        if let rowView = reused as? TreeOutlineRowView { return rowView }
        let rowView = TreeOutlineRowView()
        rowView.identifier = TreeOutlineRowView.reuseIdentifier
        return rowView
    }

    internal func outlineView(
        _ outlineView: NSOutlineView,
        typeSelectStringFor tableColumn: NSTableColumn?,
        item: Any
    ) -> String? {
        guard let node = (item as? Item)?.node else { return nil }
        return node.key ?? node.displayValue
    }

    internal func outlineViewItemDidExpand(_ notification: Notification) {
        recordDisclosure(notification, isExpanded: true)
    }

    internal func outlineViewItemDidCollapse(_ notification: Notification) {
        recordDisclosure(notification, isExpanded: false)
    }

    /// The outline posts these for the expansion applied here too, which is not the user's choice.
    private func recordDisclosure(_ notification: Notification, isExpanded: Bool) {
        guard !isApplyingExpansion, let item = notification.userInfo?["NSObject"] as? Item else { return }
        if isExpanded {
            appliedExpansion?.insert(item.path)
        } else {
            appliedExpansion?.remove(item.path)
        }
        onSetExpanded(item.path, isExpanded)
    }
}
