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
///
/// Option columns are real table columns, so each heading sits over its checkboxes whatever the
/// scroller style.
internal struct ExportObjectTreeView: NSViewRepresentable {
    @Binding internal var databaseItems: [ExportDatabaseItem]
    internal let formatId: String
    internal let options: ExportOptionLayout
    internal let databaseType: DatabaseType

    /// Reads one object's column names for the row-scope popover. Supplied by the dialog, which is
    /// what owns the export driver lease.
    internal let loadColumns: (ExportObjectItem) async -> [String]

    /// Asks the dialog to read a container's unread kinds: it was expanded, or ticked whole.
    internal let onNeedsObjects: (UUID) -> Void

    internal func makeCoordinator() -> ExportObjectTreeCoordinator {
        ExportObjectTreeCoordinator(owner: self)
    }

    internal func makeNSView(context: Context) -> NSScrollView {
        let outlineView = CheckboxOutlineView()
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.intercellSpacing = NSSize(width: 4, height: 0)
        outlineView.allowsColumnReordering = false
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

        let column = NSTableColumn(identifier: ExportObjectTreeCoordinator.nameColumn)
        column.title = String(localized: "Name")
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

fileprivate extension NSUserInterfaceItemIdentifier {
    static let exportOptionCell = NSUserInterfaceItemIdentifier("ExportOptionCell")
}

@MainActor
internal final class ExportObjectTreeCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    internal static let nameColumn = NSUserInterfaceItemIdentifier("ExportObjectColumn")

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

    private var seededDatabaseIDs: Set<UUID> = []

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
        if formatChanged {
            syncOptionColumns()
        }

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
        indexNodes()
        pendingReloadIdentities = nil
        seedCollapsedFromModel()
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
            outlineView.reloadData(forRowIndexes: rows, columnIndexes: allColumns(of: outlineView))
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
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: allColumns(of: outlineView))
    }

    private func allColumns(of outlineView: NSOutlineView) -> IndexSet {
        IndexSet(integersIn: 0 ..< outlineView.numberOfColumns)
    }

    // As wide as the plugin asks or the translated heading needs.
    private func syncOptionColumns() {
        guard let outlineView else { return }
        for column in outlineView.tableColumns where column.identifier != Self.nameColumn {
            outlineView.removeTableColumn(column)
        }
        let options = owner.options.columns
        outlineView.headerView = options.isEmpty ? nil : NSTableHeaderView()
        for (index, option) in options.enumerated() {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("ExportOptionColumn.\(index).\(option.id)")
            )
            column.title = option.label
            column.headerCell.alignment = NSTextAlignment.center
            let width = max(option.width, ceil(column.headerCell.cellSize.width) + 8)
            column.width = width
            column.minWidth = width
            column.maxWidth = width
            column.resizingMask = []
            outlineView.addTableColumn(column)
        }
    }

    private func optionIndex(of tableColumn: NSTableColumn?) -> Int? {
        guard let tableColumn else { return nil }
        let parts = tableColumn.identifier.rawValue.split(separator: ".")
        guard parts.count >= 2, parts[0] == "ExportOptionColumn", let index = Int(parts[1]) else { return nil }
        return owner.options.columns.indices.contains(index) ? index : nil
    }

    /// What the builder opened, read once per container when the tree first meets it, so a reload
    /// never reopens what the user collapsed. Reading it on the first build alone opened every
    /// schema of the tree that replaces the sidebar preview, and an open schema reads its unread kinds.
    private func seedCollapsedFromModel() {
        for database in databases where seededDatabaseIDs.insert(database.id).inserted && !database.isExpanded {
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
            requestObjectsIfPending(node)
        }
        for child in node.children {
            expandRecursively(child, in: outlineView)
        }
    }

    /// An open container shows its contents, so one with unread kinds has to read them. Asking twice
    /// is harmless: the dialog reads a container once.
    private func requestObjectsIfPending(_ node: ExportOutlineNode) {
        guard case .database(let databaseID) = node.kind,
              databases.first(where: { $0.id == databaseID })?.hasUnloadedObjects == true
        else { return }
        owner.onNeedsObjects(databaseID)
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
        guard let node = item as? ExportOutlineNode, case .pending = node.kind else { return true }
        return false
    }

    // One direction for every row: on unless every target is already checked.
    internal func toggleSelectedRows() {
        guard let outlineView else { return }
        let selected = outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? ExportOutlineNode
        }
        // The rows a click could change, minus any row under another of them: toggling both flipped it back.
        let actionable = selected.filter { node in
            if case .pending = node.kind { return false }
            return selectionIsEnabled(for: node)
        }
        let identities = Set(actionable.map(\.identity))
        let targets = actionable.filter { node in
            var parent = outlineView.parent(forItem: node) as? ExportOutlineNode
            while let ancestor = parent {
                if identities.contains(ancestor.identity) { return false }
                parent = outlineView.parent(forItem: ancestor) as? ExportOutlineNode
            }
            return true
        }
        guard !targets.isEmpty else { return }
        let turningOn = targets.contains { selectionState(for: $0) != .checked }
        for node in targets {
            switch node.kind {
            case .database, .group:
                setContainer(node, selected: turningOn)
            case .object(let databaseID, let objectID):
                setSelection(turningOn, databaseID: databaseID, objectID: objectID)
            case .pending:
                continue
            }
        }
    }

    internal func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ExportOutlineNode else { return }
        collapsedIdentities.remove(node.identity)
        requestObjectsIfPending(node)
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
        if let index = optionIndex(of: tableColumn) {
            return optionCell(column: index, node: node, in: outlineView)
        }
        let identifier = NSUserInterfaceItemIdentifier("ExportObjectRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? HostingTableCellView
            ?? HostingTableCellView(identifier: identifier)
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
                .disabled(!selectionIsEnabled(for: node))
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
                .disabled(!selectionIsEnabled(for: node))
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
                    offersRowScope: object.offersRowScope(on: owner.databaseType) && owner.options.readsRows,
                    toggle: { [weak self] in
                        self?.toggleObject(databaseID: databaseID, objectID: objectID)
                    },
                    setRowScope: { [weak self] scope in
                        self?.setRowScope(scope, databaseID: databaseID, objectID: objectID)
                    },
                    loadColumns: { [owner] in await owner.loadColumns(object) }
                )
            )
        case .pending:
            return AnyView(
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
    }

    // MARK: - Selection

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
        case .pending:
            return []
        }
    }

    /// The database behind a container row whose kinds are not all read yet, if this is one.
    private func unloadedDatabase(at node: ExportOutlineNode) -> ExportDatabaseItem? {
        guard case .database(let databaseID) = node.kind,
              let database = databases.first(where: { $0.id == databaseID }),
              database.hasUnloadedObjects
        else { return nil }
        return database
    }

    // An object a column checkbox turned all off stays out of a tick, or click order would decide the dump.
    private func selectableObjects(under node: ExportOutlineNode) -> [ExportObjectItem] {
        objects(under: node).filter(owner.options.writesSomething)
    }

    // A container where every loaded object writes nothing and no unread kind can arrive: a tick would
    // select nothing. An object row stays enabled, since ticking it restores the format's defaults.
    internal func selectionIsEnabled(for node: ExportOutlineNode) -> Bool {
        if case .object = node.kind { return true }
        let items = objects(under: node)
        return items.isEmpty || unloadedDatabase(at: node) != nil || items.contains(where: owner.options.writesSomething)
    }

    internal func containerState(for node: ExportOutlineNode) -> TristateCheckbox.State {
        let items = selectableObjects(under: node)
        guard !items.isEmpty else {
            return unloadedDatabase(at: node)?.selectsLoadedObjects == true ? .checked : .unchecked
        }
        let selected = items.count(where: \.isSelected)
        if selected == 0 { return .unchecked }
        return selected == items.count ? .checked : .mixed
    }

    private func selectionState(for node: ExportOutlineNode) -> TristateCheckbox.State {
        guard case .object(let databaseID, let objectID) = node.kind else { return containerState(for: node) }
        return object(databaseID: databaseID, objectID: objectID)?.isSelected == true ? .checked : .unchecked
    }

    private func object(databaseID: UUID, objectID: UUID) -> ExportObjectItem? {
        databases.first(where: { $0.id == databaseID })?.objects.first(where: { $0.id == objectID })
    }

    private func toggleContainer(_ node: ExportOutlineNode) {
        setContainer(node, selected: containerState(for: node) != .checked)
    }

    /// Ticking a container whose kinds are not all read yet also asks for them, and they arrive
    /// selected unless something in it is unticked first.
    private func setContainer(_ node: ExportOutlineNode, selected turningOn: Bool) {
        let items = turningOn ? selectableObjects(under: node) : objects(under: node)
        let unloaded = unloadedDatabase(at: node)
        let ids = Set(items.map(\.id))
        var reloading: Set<String> = []
        if let unloaded { reloading.insert("db:\(unloaded.id.uuidString)") }
        mutateDatabases(touching: ids, reloading: reloading) { databases in
            for databaseIndex in databases.indices {
                for objectIndex in databases[databaseIndex].objects.indices
                where ids.contains(databases[databaseIndex].objects[objectIndex].id) {
                    databases[databaseIndex].objects[objectIndex].isSelected = turningOn
                }
                if databases[databaseIndex].id == unloaded?.id {
                    databases[databaseIndex].selectsLoadedObjects = turningOn
                }
            }
        }
        if turningOn, let unloaded {
            owner.onNeedsObjects(unloaded.id)
        }
        guard turningOn else { return }
        normalizeOptions(for: ids)
    }

    internal func toggleObject(databaseID: UUID, objectID: UUID) {
        guard let object = object(databaseID: databaseID, objectID: objectID) else { return }
        setSelection(!object.isSelected, databaseID: databaseID, objectID: objectID)
    }

    // MARK: - Option columns

    private func optionCell(column index: Int, node: ExportOutlineNode, in outlineView: NSOutlineView) -> NSView? {
        let label = owner.options.columns[index].label
        let state: NSControl.StateValue
        let isEnabled: Bool
        let title: String
        let action: () -> Void
        switch node.kind {
        case .database, .group:
            guard let containerState = optionState(ofColumn: index, under: node) else { return nil }
            state = containerState
            isEnabled = true
            title = containerTitle(of: node)
            action = { [weak self] in self?.toggleOption(index, under: node) }
        case .object(let databaseID, let objectID):
            guard let object = object(databaseID: databaseID, objectID: objectID),
                  owner.options.supports(columnAt: index, kind: object.kind)
            else { return nil }
            let isOn = object.optionValues[safe: index] ?? owner.options.columns[index].defaultValue
            state = isOn ? .on : .off
            isEnabled = object.isSelected
            title = object.name
            action = { [weak self] in
                self?.setOption(index, to: !isOn, databaseID: databaseID, objectID: objectID)
            }
        case .pending:
            return nil
        }
        let cell = outlineView.makeView(withIdentifier: .exportOptionCell, owner: self) as? CheckboxTableCellView
            ?? CheckboxTableCellView(identifier: .exportOptionCell)
        cell.configure(
            state: state,
            isEnabled: isEnabled,
            accessibilityLabel: String(format: String(localized: "%1$@ for %2$@"), label, title),
            action: action
        )
        return cell
    }

    private func containerTitle(of node: ExportOutlineNode) -> String {
        switch node.kind {
        case .database(let databaseID):
            return databases.first(where: { $0.id == databaseID })?.name ?? ""
        case .group(_, let objectKind):
            return ExportObjectKindPresentation.groupTitle(for: objectKind)
        case .object, .pending:
            return ""
        }
    }

    private func optionValues(ofColumn index: Int, under node: ExportOutlineNode) -> [Bool] {
        let unloaded = unloadedDatabase(at: node)
        return owner.options.values(
            ofColumn: index,
            in: objects(under: node),
            unloadedKinds: unloaded?.unloadedKinds ?? [],
            arriving: unloaded?.arrivingOptionValues ?? [:]
        )
    }

    internal func optionState(ofColumn index: Int, under node: ExportOutlineNode) -> NSControl.StateValue? {
        let values = optionValues(ofColumn: index, under: node)
        guard !values.isEmpty else { return nil }
        if values.allSatisfy({ $0 }) { return .on }
        return values.contains(true) ? .mixed : .off
    }

    // Never selects: on a container with nothing ticked it sets what each object carries once ticked.
    internal func toggleOption(_ index: Int, under node: ExportOutlineNode) {
        guard let state = optionState(ofColumn: index, under: node) else { return }
        let turningOn = state != .on
        let options = owner.options
        let ids = Set(objects(under: node).filter { options.supports(columnAt: index, kind: $0.kind) }.map(\.id))
        let unloaded = unloadedDatabase(at: node).flatMap { database in
            database.unloadedKinds.contains { options.supports(columnAt: index, kind: $0) } ? database : nil
        }
        var reloading: Set<String> = []
        if let unloaded { reloading.insert("db:\(unloaded.id.uuidString)") }
        mutateDatabases(touching: ids, reloading: reloading) { databases in
            databases = databases.settingOption(index, to: turningOn, objectIDs: ids, arrivingIn: unloaded?.id)
        }
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
        let columns = owner.options.columns
        guard !columns.isEmpty else { return }
        let defaults = owner.options.defaultValues
        let supports = owner.options.supports
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
            databases = databases.settingOption(index, to: value, objectIDs: [objectID])
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
        reloading extraIdentities: Set<String> = [],
        _ change: (inout [ExportDatabaseItem]) -> Void
    ) {
        var updated = databases
        change(&updated)
        databases = updated
        markForReload(objectIDs: ids)
        pendingReloadIdentities?.formUnion(extraIdentities)
        owner.databaseItems = updated
    }
}
