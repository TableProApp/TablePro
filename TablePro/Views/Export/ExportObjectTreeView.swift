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
        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.rowSizeStyle = .default
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

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
    private var databases: [ExportDatabaseItem] = []
    private var shapeFingerprint = ""
    private var formatId = ""

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
        shapeFingerprint = fingerprint
        roots = ExportOutlineTreeBuilder.build(from: databases)
        outlineView?.reloadData()
        restoreExpansion()
    }

    /// A checkbox toggle leaves the tree's shape alone, so the rows are redrawn in place. Rebuilding
    /// would collapse and re-expand every group under the user's pointer.
    private func reloadRowContent() {
        guard let outlineView else { return }
        let rows = IndexSet(integersIn: 0 ..< outlineView.numberOfRows)
        guard !rows.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
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

    internal func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        false
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

    private func rowContent(for node: ExportOutlineNode) -> AnyView {
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
        mutateDatabases { databases in
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
        mutateDatabases { databases in
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
        mutateDatabases { databases in
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
        mutateDatabases { databases in
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
        mutateDatabases { databases in
            guard let databaseIndex = databases.firstIndex(where: { $0.id == databaseID }),
                  let objectIndex = databases[databaseIndex].objects.firstIndex(where: { $0.id == objectID })
            else { return }
            databases[databaseIndex].objects[objectIndex].rowScope = scope
        }
    }

    private func mutateDatabases(_ change: (inout [ExportDatabaseItem]) -> Void) {
        var updated = databases
        change(&updated)
        databases = updated
        owner.databaseItems = updated
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
