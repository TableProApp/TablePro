//
//  ExportObjectTreeView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

/// The export tree as an `NSOutlineView`.
///
/// It has three levels once a database holds more than one kind of object, and a SwiftUI `List` of
/// nested `DisclosureGroup`s driven by programmatic `isExpanded` bindings crashes on macOS when the
/// bindings are re-driven during an animated outline diff. That is the same Apple bug the
/// connection sidebar's database tree hit, and the same answer: `NSOutlineView`, which also gives
/// genuinely lazy children for a database holding thousands of objects.
internal struct ExportObjectTreeView: NSViewRepresentable {
    @Binding internal var databaseItems: [ExportDatabaseItem]
    internal let formatId: String

    /// Reads one object's column names for the row-scope popover. Supplied by the dialog, which is
    /// what owns the export driver lease.
    internal let loadColumns: (ExportObjectItem) async -> [String]

    internal func makeCoordinator() -> ExportObjectTreeCoordinator {
        ExportObjectTreeCoordinator(owner: self)
    }

    internal func makeNSView(context: Context) -> NSScrollView {
        let outlineView = ExportOutlineView()
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 24
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.toggleSelectedRows = { [weak coordinator = context.coordinator] in
            coordinator?.toggleSelectedRows()
        }
        outlineView.setAccessibilityLabel(String(localized: "Objects to export"))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ExportObjectColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        context.coordinator.attach(outlineView: outlineView)
        return scrollView
    }

    internal func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.apply(databases: databaseItems, formatId: formatId)
    }
}

@MainActor
internal final class ExportObjectTreeCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    internal var owner: ExportObjectTreeView

    private weak var outlineView: NSOutlineView?
    private var roots: [ExportOutlineNode] = []
    private var nodesByIdentity: [String: ExportOutlineNode] = [:]
    private var databases: [ExportDatabaseItem] = []
    private var shapeFingerprint = ""
    private var formatId = ""

    /// The rows the coordinator's own last mutation touched. Nil means the change came from
    /// outside it, a profile or a preselection, and nothing local knows which rows it moved.
    private var pendingReloadIdentities: Set<String>?

    /// Every node the user has collapsed, by its stable identity, so a rebuild restores what they
    /// chose rather than reopening the whole tree.
    private var collapsedIdentities: Set<String> = []

    internal init(owner: ExportObjectTreeView) {
        self.owner = owner
    }

    internal func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
    }

    internal func apply(databases: [ExportDatabaseItem], formatId: String) {
        let fingerprint = ExportOutlineTreeBuilder.shapeFingerprint(of: databases)
        let formatChanged = formatId != self.formatId
        self.databases = databases
        self.formatId = formatId

        guard fingerprint != shapeFingerprint else {
            guard formatChanged else {
                reloadRowContent()
                return
            }
            outlineView?.reloadData()
            restoreExpansion()
            return
        }
        let isFirstBuild = shapeFingerprint.isEmpty
        shapeFingerprint = fingerprint
        roots = ExportOutlineTreeBuilder.build(from: databases)
        indexNodes()
        pendingReloadIdentities = nil
        if isFirstBuild { seedCollapsedFromModel() }
        outlineView?.reloadData()
        restoreExpansion()
    }

    /// A checkbox toggle leaves the tree's shape alone, so the rows are redrawn in place. Rebuilding
    /// would collapse and re-expand every group under the user's pointer.
    ///
    /// Only the rows the toggle actually changed are redrawn. Reloading the whole tree rebuilt one
    /// `AnyView` and wrote one `NSHostingView.rootView` per object in the database, so a click in a
    /// schema of several thousand tables paid for all of them.
    private func reloadRowContent() {
        guard let outlineView else { return }
        guard let identities = pendingReloadIdentities else {
            let rows = IndexSet(integersIn: 0 ..< outlineView.numberOfRows)
            guard !rows.isEmpty else { return }
            outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            return
        }
        pendingReloadIdentities = nil
        var rows = IndexSet()
        for identity in identities {
            guard let node = nodesByIdentity[identity] else { continue }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { continue }
            rows.insert(row)
        }
        guard !rows.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    /// What the loader already decided. It opens the database the dialog was scoped to and any
    /// container the preselection names, and leaves the rest closed; without this every database
    /// on the server opened at once. Only the first build reads it, so a later reload never
    /// reopens something the user has since collapsed.
    private func seedCollapsedFromModel() {
        for database in databases where !database.isExpanded {
            collapsedIdentities.insert("db:\(database.id.uuidString)")
        }
    }

    private func indexNodes() {
        nodesByIdentity = [:]
        var stack = roots
        while let node = stack.popLast() {
            nodesByIdentity[node.identity] = node
            stack.append(contentsOf: node.children)
        }
    }

    /// The rows a change to these objects can redraw: each object's own row, and every container
    /// above it, whose tri-state checkbox is a function of what it holds.
    private func markForReload(objectIDs: Set<UUID>) {
        var identities = pendingReloadIdentities ?? []
        for database in databases {
            let touched = database.objects.filter { objectIDs.contains($0.id) }
            guard !touched.isEmpty else { continue }
            identities.insert("db:\(database.id.uuidString)")
            for object in touched {
                identities.insert("obj:\(database.id.uuidString):\(object.id.uuidString)")
                identities.insert("group:\(database.id.uuidString):\(object.kind.rawValue)")
            }
        }
        pendingReloadIdentities = identities
    }

    private func restoreExpansion() {
        guard let outlineView else { return }
        for root in roots {
            expandRecursively(root, in: outlineView)
        }
    }

    private func expandRecursively(_ node: ExportOutlineNode, in outlineView: NSOutlineView) {
        guard !node.isLeaf else { return }
        if collapsedIdentities.contains(node.identity) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
        for child in node.children {
            expandRecursively(child, in: outlineView)
        }
    }

    // MARK: - Data Source

    internal func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ExportOutlineNode else { return roots.count }
        return node.children.count
    }

    internal func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ExportOutlineNode else { return roots[index] }
        return node.children[index]
    }

    internal func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ExportOutlineNode else { return false }
        return !node.isLeaf
    }

    /// Rows are selectable so the arrow keys reach them. Selection is how an `NSOutlineView` is
    /// navigated: refusing it leaves Space with nothing to toggle, Left and Right with nothing to
    /// collapse, and VoiceOver with no way into the tree at all.
    internal func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        true
    }

    /// Space toggles every selected row, which is what the checkbox in each of them does on a
    /// click. A container row toggles everything beneath it, exactly as clicking its checkbox does.
    internal func toggleSelectedRows() {
        guard let outlineView else { return }
        let nodes = outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? ExportOutlineNode
        }
        guard !nodes.isEmpty else { return }
        for node in nodes {
            switch node.kind {
            case .database, .group:
                toggleContainer(node)
            case .object(let databaseID, let objectID):
                let isSelected = databases.first(where: { $0.id == databaseID })?
                    .objects.first(where: { $0.id == objectID })?.isSelected ?? false
                setSelection(!isSelected, databaseID: databaseID, objectID: objectID)
            }
        }
    }

    internal func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ExportOutlineNode else { return }
        collapsedIdentities.remove(node.identity)
    }

    internal func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ExportOutlineNode else { return }
        collapsedIdentities.insert(node.identity)
    }

    // MARK: - Delegate

    internal func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? ExportOutlineNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ExportObjectRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? ExportObjectCellView
            ?? ExportObjectCellView(identifier: identifier)
        cell.configure(with: rowContent(for: node))
        return cell
    }

    /// Every row carries the identity of the object it draws.
    ///
    /// `NSOutlineView` hands one recycled cell to a different object as rows scroll, and the cell
    /// swaps its hosting view's root rather than rebuilding it. SwiftUI ties `@State` to view
    /// identity, so without an id of its own a row's loaded column list and half-edited row scope
    /// reconcile onto whatever object inherits the cell: opening the scope popover on the second
    /// table would offer the first one's columns and write them into the second one's SELECT.
    private func rowContent(for node: ExportOutlineNode) -> AnyView {
        AnyView(rowBody(for: node).id(node.identity))
    }

    private func rowBody(for node: ExportOutlineNode) -> AnyView {
        switch node.kind {
        case .database(let databaseID):
            return AnyView(
                ExportTreeContainerRow(
                    title: databases.first(where: { $0.id == databaseID })?.name ?? "",
                    iconName: "cylinder",
                    iconColor: .blue,
                    state: containerState(for: node),
                    toggle: { [weak self] in self?.toggleContainer(node) }
                )
            )
        case .group(_, let objectKind):
            return AnyView(
                ExportTreeContainerRow(
                    title: ExportObjectKindPresentation.groupTitle(for: objectKind),
                    iconName: ExportObjectKindPresentation.iconName(for: objectKind),
                    iconColor: ExportObjectKindPresentation.iconColor(for: objectKind),
                    state: containerState(for: node),
                    toggle: { [weak self] in self?.toggleContainer(node) }
                )
            )
        case .object(let databaseID, let objectID):
            guard let databaseIndex = databases.firstIndex(where: { $0.id == databaseID }),
                  let objectIndex = databases[databaseIndex].objects.firstIndex(where: { $0.id == objectID })
            else {
                return AnyView(EmptyView())
            }
            let object = databases[databaseIndex].objects[objectIndex]
            return AnyView(
                ExportTreeObjectRow(
                    object: object,
                    optionColumns: optionColumns,
                    supportsOption: supportsOption,
                    setSelected: { [weak self] isSelected in
                        self?.setSelection(isSelected, databaseID: databaseID, objectID: objectID)
                    },
                    setOption: { [weak self] index, value in
                        self?.setOption(index, to: value, databaseID: databaseID, objectID: objectID)
                    },
                    setRowScope: { [weak self] scope in
                        self?.setRowScope(scope, databaseID: databaseID, objectID: objectID)
                    },
                    loadColumns: { [owner] in await owner.loadColumns(object) }
                )
            )
        }
    }

    // MARK: - Selection

    private var plugin: (any ExportFormatPlugin)? {
        PluginManager.shared.exportPlugin(forFormat: formatId)
    }

    private var optionColumns: [PluginExportOptionColumn] {
        guard let plugin else { return [] }
        return type(of: plugin).perTableOptionColumns
    }

    private var defaultOptionValues: [Bool] {
        plugin?.defaultTableOptionValues() ?? []
    }

    private var supportsOption: (String, PluginExportObjectKind) -> Bool {
        guard let plugin else { return { _, _ in true } }
        let pluginType = type(of: plugin)
        return { columnId, kind in pluginType.supportsOption(columnId: columnId, for: kind) }
    }

    private func objects(under node: ExportOutlineNode) -> [ExportObjectItem] {
        switch node.kind {
        case .database(let databaseID):
            return databases.first(where: { $0.id == databaseID })?.objects ?? []
        case .group(let databaseID, let objectKind):
            return databases.first(where: { $0.id == databaseID })?.objects(ofKind: objectKind) ?? []
        case .object(let databaseID, let objectID):
            guard let object = databases.first(where: { $0.id == databaseID })?
                .objects.first(where: { $0.id == objectID }) else { return [] }
            return [object]
        }
    }

    private func containerState(for node: ExportOutlineNode) -> TristateCheckbox.State {
        let items = objects(under: node)
        guard !items.isEmpty else { return .unchecked }
        let selected = items.count(where: \.isSelected)
        if selected == 0 { return .unchecked }
        return selected == items.count ? .checked : .mixed
    }

    private func toggleContainer(_ node: ExportOutlineNode) {
        let items = objects(under: node)
        let turningOn = items.contains { !$0.isSelected }
        let ids = Set(items.map(\.id))
        mutateDatabases(touching: ids) { databases in
            for databaseIndex in databases.indices {
                for objectIndex in databases[databaseIndex].objects.indices
                where ids.contains(databases[databaseIndex].objects[objectIndex].id) {
                    databases[databaseIndex].objects[objectIndex].isSelected = turningOn
                }
            }
        }
        guard turningOn else { return }
        normalizeOptions(for: ids)
    }

    private func setSelection(_ isSelected: Bool, databaseID: UUID, objectID: UUID) {
        mutateDatabases(touching: [objectID]) { databases in
            guard let databaseIndex = databases.firstIndex(where: { $0.id == databaseID }),
                  let objectIndex = databases[databaseIndex].objects.firstIndex(where: { $0.id == objectID })
            else { return }
            databases[databaseIndex].objects[objectIndex].isSelected = isSelected
        }
        guard isSelected else { return }
        normalizeOptions(for: [objectID])
    }

    /// A row selected with every one of its options off would be counted as selected and export
    /// nothing, so selecting it restores the format's defaults for the kinds that support them.
    private func normalizeOptions(for ids: Set<UUID>) {
        let columns = optionColumns
        guard !columns.isEmpty else { return }
        let defaults = defaultOptionValues
        let supports = supportsOption
        mutateDatabases(touching: ids) { databases in
            for databaseIndex in databases.indices {
                for objectIndex in databases[databaseIndex].objects.indices
                where ids.contains(databases[databaseIndex].objects[objectIndex].id) {
                    let object = databases[databaseIndex].objects[objectIndex]
                    guard !object.optionValues.contains(true) || object.optionValues.count != columns.count else {
                        continue
                    }
                    databases[databaseIndex].objects[objectIndex] = object
                        .normalized(forOptionColumnCount: columns.count, defaultOptionValues: defaults)
                        .maskingUnsupportedOptions(columns: columns, supports: supports)
                }
            }
        }
    }

    private func setOption(_ index: Int, to value: Bool, databaseID: UUID, objectID: UUID) {
        mutateDatabases(touching: [objectID]) { databases in
            guard let databaseIndex = databases.firstIndex(where: { $0.id == databaseID }),
                  let objectIndex = databases[databaseIndex].objects.firstIndex(where: { $0.id == objectID }),
                  databases[databaseIndex].objects[objectIndex].optionValues.indices.contains(index)
            else { return }
            databases[databaseIndex].objects[objectIndex].optionValues[index] = value
            databases[databaseIndex].objects[objectIndex].isSelected =
                databases[databaseIndex].objects[objectIndex].optionValues.contains(true)
        }
    }

    private func setRowScope(_ scope: PluginExportRowScope, databaseID: UUID, objectID: UUID) {
        mutateDatabases(touching: [objectID]) { databases in
            guard let databaseIndex = databases.firstIndex(where: { $0.id == databaseID }),
                  let objectIndex = databases[databaseIndex].objects.firstIndex(where: { $0.id == objectID })
            else { return }
            databases[databaseIndex].objects[objectIndex].rowScope = scope
        }
    }

    private func mutateDatabases(
        touching ids: Set<UUID>,
        _ change: (inout [ExportDatabaseItem]) -> Void
    ) {
        var updated = databases
        change(&updated)
        databases = updated
        markForReload(objectIDs: ids)
        owner.databaseItems = updated
    }
}

/// Adds the one key an `NSOutlineView` of checkboxes needs and does not get for free. Arrow keys,
/// Left and Right to collapse and expand, Home and End and type-select are all AppKit's own once
/// the rows are selectable.
internal final class ExportOutlineView: NSOutlineView {
    internal var toggleSelectedRows: (() -> Void)?

    override internal func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " ", !selectedRowIndexes.isEmpty else {
            super.keyDown(with: event)
            return
        }
        toggleSelectedRows?()
    }
}

/// The cell keeps one hosting view for the life of the row and only swaps its root, because
/// rebuilding the host on every reload loses the SwiftUI state the checkboxes animate from.
internal final class ExportObjectCellView: NSTableCellView {
    private let hosting: NSHostingView<AnyView>

    internal init(identifier: NSUserInterfaceItemIdentifier) {
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        self.identifier = identifier
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func configure(with content: AnyView) {
        hosting.rootView = content
    }
}
