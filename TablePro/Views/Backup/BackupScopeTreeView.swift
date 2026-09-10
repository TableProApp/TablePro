//
//  BackupScopeTreeView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The backup sheet's scope tree: databases, each expandable to the objects a dump can be narrowed
/// to.
///
/// An `NSOutlineView` rather than nested SwiftUI `DisclosureGroup`s, for the reason the export tree
/// and the connection sidebar both record: programmatic `isExpanded` bindings re-driven during an
/// animated outline diff crash on macOS. It also gives genuinely lazy children, which is what lets
/// a server with two hundred databases draw before any of their table lists are read.
internal struct BackupScopeTreeView: NSViewRepresentable {
    internal let model: BackupScopeModel
    internal let expand: (String) -> Void

    internal func makeCoordinator() -> BackupScopeTreeCoordinator {
        BackupScopeTreeCoordinator(model: model, expand: expand)
    }

    internal func makeNSView(context: Context) -> NSScrollView {
        let outlineView = CheckboxOutlineView()
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
        outlineView.setAccessibilityLabel(String(localized: "Databases and objects to back up"))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("BackupScopeColumn"))
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
        context.coordinator.expand = expand
        context.coordinator.apply(rows: model.rows)
    }
}

/// One row of the tree. `NSOutlineView` identifies its items by object identity, so these are
/// reference types rebuilt only when the shape of the tree changes, never on a checkbox toggle.
internal final class BackupScopeNode {
    internal enum Kind: Equatable {
        case database(String)
        case object(database: String, id: String)
        /// Stands in for a database's children before they are read, so AppKit draws a disclosure
        /// triangle on a row whose child count is still zero.
        case placeholder(database: String, isLoading: Bool)
    }

    internal let kind: Kind
    internal fileprivate(set) var children: [BackupScopeNode]

    internal init(kind: Kind, children: [BackupScopeNode] = []) {
        self.kind = kind
        self.children = children
    }

    internal var identity: String {
        switch kind {
        case .database(let name):
            return "db:\(name)"
        case .object(let database, let id):
            return "obj:\(database):\(id)"
        case .placeholder(let database, _):
            return "placeholder:\(database)"
        }
    }

    internal var databaseName: String {
        switch kind {
        case .database(let name): return name
        case .object(let database, _): return database
        case .placeholder(let database, _): return database
        }
    }
}

@MainActor
internal final class BackupScopeTreeCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let model: BackupScopeModel
    internal var expand: (String) -> Void

    private weak var outlineView: NSOutlineView?
    private var nodes: [BackupScopeNode] = []
    private var rows: [BackupScopeModel.DatabaseRow] = []
    private var shapeFingerprint = ""

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("BackupScopeCell")

    internal init(model: BackupScopeModel, expand: @escaping (String) -> Void) {
        self.model = model
        self.expand = expand
    }

    internal func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        apply(rows: model.rows)
    }

    /// A checkbox toggle changes no row's place in the tree, so only the rows it can redraw are
    /// reloaded. Rebuilding the nodes on every toggle would collapse every expanded database under
    /// the pointer, and reloading the whole outline redraws hundreds of rows to change one.
    internal func apply(rows: [BackupScopeModel.DatabaseRow]) {
        let previous = self.rows
        self.rows = rows
        let fingerprint = Self.fingerprint(of: rows)
        guard fingerprint != shapeFingerprint else {
            reloadChangedRows(from: previous, to: rows)
            syncExpansion()
            return
        }
        shapeFingerprint = fingerprint
        nodes = rows.map { row in
            BackupScopeNode(
                kind: .database(row.name),
                children: Self.children(of: row)
            )
        }
        outlineView?.reloadData()
        syncExpansion()
    }

    private func reloadChangedRows(
        from previous: [BackupScopeModel.DatabaseRow],
        to current: [BackupScopeModel.DatabaseRow]
    ) {
        guard let outlineView else { return }
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, $0) })
        for row in current {
            guard let old = before[row.name] else { continue }
            guard old.isSelected != row.isSelected || old.objects != row.objects else { continue }
            guard let node = nodes.first(where: { $0.databaseName == row.name }) else { continue }
            let objectsChanged = old.objects != row.objects
            outlineView.reloadItem(node, reloadChildren: false)
            guard objectsChanged else { continue }
            for child in node.children {
                outlineView.reloadItem(child, reloadChildren: false)
            }
        }
    }

    private static func children(of row: BackupScopeModel.DatabaseRow) -> [BackupScopeNode] {
        switch row.load {
        case .notLoaded:
            return [BackupScopeNode(kind: .placeholder(database: row.name, isLoading: false))]
        case .loading:
            return [BackupScopeNode(kind: .placeholder(database: row.name, isLoading: true))]
        case .failed:
            return []
        case .loaded:
            return row.objects.map {
                BackupScopeNode(kind: .object(database: row.name, id: $0.id))
            }
        }
    }

    private static func fingerprint(of rows: [BackupScopeModel.DatabaseRow]) -> String {
        rows.map { row in
            "\(row.name)|\(row.load)|\(row.objects.map(\.id).joined(separator: ","))"
        }
        .joined(separator: ";")
    }

    private func syncExpansion() {
        guard let outlineView else { return }
        for node in nodes {
            guard let row = rows.first(where: { $0.name == node.databaseName }) else { continue }
            let isExpanded = outlineView.isItemExpanded(node)
            guard row.isExpanded != isExpanded else { continue }
            if row.isExpanded {
                outlineView.expandItem(node)
            } else {
                outlineView.collapseItem(node)
            }
        }
    }

    // MARK: - Data source

    internal func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? BackupScopeNode else { return nodes.count }
        return node.children.count
    }

    internal func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? BackupScopeNode else { return nodes[index] }
        return node.children[index]
    }

    internal func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? BackupScopeNode else { return false }
        guard case .database = node.kind else { return false }
        return model.objectScope.allowsNarrowing && !node.children.isEmpty
    }

    internal func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? BackupScopeNode else { return }
        guard case .database(let name) = node.kind else { return }
        model.setExpanded(true, database: name)
        expand(name)
    }

    internal func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? BackupScopeNode else { return }
        guard case .database(let name) = node.kind else { return }
        model.setExpanded(false, database: name)
    }

    // MARK: - Delegate

    internal func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? BackupScopeNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? HostingTableCellView
            ?? HostingTableCellView(identifier: Self.cellIdentifier)
        cell.configure(with: AnyView(content(for: node).id(node.identity)))
        return cell
    }

    @ViewBuilder
    private func content(for node: BackupScopeNode) -> some View {
        switch node.kind {
        case .database(let name):
            databaseRow(name)
        case .object(let database, let id):
            objectRow(database: database, id: id)
        case .placeholder(_, let isLoading):
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Text(isLoading ? String(localized: "Loading\u{2026}") : String(localized: "Not loaded yet"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func databaseRow(_ name: String) -> some View {
        if let row = rows.first(where: { $0.name == name }) {
            HStack(spacing: 6) {
                TristateCheckbox(
                    state: row.isMixed ? .mixed : (row.isSelected ? .checked : .unchecked),
                    accessibilityLabel: row.label,
                    accessibilityValue: Self.accessibilityValue(for: row, scope: model.objectScope)
                ) { [weak self] in
                    self?.model.toggleDatabase(name)
                }
                Text(row.label).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Self.countLabel(for: row, scope: model.objectScope))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func objectRow(database: String, id: String) -> some View {
        if let row = rows.first(where: { $0.name == database }),
           let object = row.objects.first(where: { $0.id == id }) {
            HStack(spacing: 6) {
                TristateCheckbox(
                    state: object.isSelected ? .checked : .unchecked,
                    accessibilityLabel: object.id
                ) { [weak self] in
                    self?.model.toggleObject(id, in: database)
                }
                Text(object.id).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
        }
    }

    private static func countLabel(
        for row: BackupScopeModel.DatabaseRow,
        scope: NativeDumpObjectScope
    ) -> String {
        guard row.load == .loaded else { return "" }
        guard !row.coversWholeDatabase else {
            return String(
                format: String(localized: "%1$lld %2$@"),
                Int64(row.objects.count),
                row.objects.count == 1 ? scope.singularUnitNoun : scope.unitNoun
            )
        }
        return String(
            format: String(localized: "%1$lld of %2$lld %3$@"),
            Int64(row.selectedObjects.count),
            Int64(row.objects.count),
            scope.unitNoun
        )
    }

    private static func accessibilityValue(
        for row: BackupScopeModel.DatabaseRow,
        scope: NativeDumpObjectScope
    ) -> String {
        guard row.isSelected else { return String(localized: "Not backed up") }
        guard !row.coversWholeDatabase else { return String(localized: "Whole database") }
        return countLabel(for: row, scope: scope)
    }

    // MARK: - Keyboard

    internal func toggleSelectedRows() {
        guard let outlineView else { return }
        for index in outlineView.selectedRowIndexes {
            guard let node = outlineView.item(atRow: index) as? BackupScopeNode else { continue }
            switch node.kind {
            case .database(let name):
                model.toggleDatabase(name)
            case .object(let database, let id):
                model.toggleObject(id, in: database)
            case .placeholder:
                continue
            }
        }
    }
}
