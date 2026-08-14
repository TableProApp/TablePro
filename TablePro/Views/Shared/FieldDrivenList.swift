//
//  FieldDrivenList.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct FieldDrivenListSection<Item: Identifiable>: Identifiable {
    internal let id: String
    internal let title: String?
    internal let items: [Item]

    internal init(id: String, title: String? = nil, items: [Item]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

internal struct FieldDrivenMenuItem {
    internal let title: String
    internal let isSeparator: Bool
    internal let action: () -> Void

    internal init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.isSeparator = false
        self.action = action
    }

    private init() {
        self.title = ""
        self.isSeparator = true
        self.action = {}
    }

    internal static var separator: FieldDrivenMenuItem { FieldDrivenMenuItem() }
}

/// A list whose selection belongs to a search field rather than to the list itself.
///
/// Spotlight, Xcode's Open Quickly and AppKit's own completion window all keep the text field
/// focused and still draw the highlighted row emphasized, because that highlight is the field's
/// navigation state and not a second focus. A SwiftUI `List` cannot express this: it derives
/// emphasis from its own first-responder status, so a list sitting behind a focused field is drawn
/// permanently inactive, and the accent state is reachable only by clicking, which is not the path
/// the design uses. `NSTableRowView.isEmphasized` is AppKit's supported way to declare it.
///
/// The rows stay SwiftUI. AppKit publishes `NSTableCellView.backgroundStyle` into the hosted view's
/// environment as `backgroundProminence`, so `selectionAwareTint` and friends keep working with no
/// emphasis plumbing of their own.
internal struct FieldDrivenList<Item: Identifiable, Row: View>: NSViewRepresentable where Item.ID: Hashable {
    internal let sections: [FieldDrivenListSection<Item>]
    @Binding internal var selection: Set<Item.ID>
    internal var allowsMultipleSelection: Bool = false
    internal var rowHeight: CGFloat = 28
    internal var usesSourceListStyle: Bool = false
    /// A chooser commits on the first click; a browser waits for a double-click. Both are set,
    /// because which one a list uses is the list's decision, not this type's.
    internal var onSingleClickAction: ((Item.ID) -> Void)?
    internal var onPrimaryAction: (Item.ID) -> Void = { _ in }
    internal var menuItems: ((Set<Item.ID>) -> [FieldDrivenMenuItem])?
    @ViewBuilder internal let row: (Item) -> Row

    internal func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    internal func makeNSView(context: Context) -> NSScrollView {
        let tableView = FieldDrivenTableView()
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = allowsMultipleSelection
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.style = usesSourceListStyle ? .sourceList : .inset
        tableView.floatsGroupRows = false
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.handleSingleClick)
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FieldDrivenColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        return scrollView
    }

    internal func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(owner: self)
    }

    @MainActor
    internal final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var owner: FieldDrivenList
        private var entries: [FieldDrivenListEntry<Item>] = []
        private var isApplyingSelection = false

        internal weak var tableView: FieldDrivenTableView?

        internal init(owner: FieldDrivenList) {
            self.owner = owner
            super.init()
            entries = FieldDrivenListEntry.flatten(owner.sections)
        }

        internal func apply(owner: FieldDrivenList) {
            self.owner = owner
            guard let tableView else { return }
            let next = FieldDrivenListEntry.flatten(owner.sections)
            let identityChanged = next.map(\.identity) != entries.map(\.identity)
            entries = next
            tableView.allowsMultipleSelection = owner.allowsMultipleSelection
            tableView.rowHeight = owner.rowHeight
            if identityChanged {
                tableView.reloadData()
            } else {
                reloadItemContents(in: tableView)
            }
            syncSelection(in: tableView)
        }

        /// A refilter that keeps the same rows must not reload them, because reloading throws away
        /// the hosted SwiftUI views and their animation state. Only the row contents are refreshed.
        private func reloadItemContents(in tableView: NSTableView) {
            for (index, entry) in entries.enumerated() {
                guard case .item(let item) = entry,
                      let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                        as? FieldDrivenCellView<Row> else { continue }
                cell.update(rootView: owner.row(item))
            }
        }

        private func syncSelection(in tableView: NSTableView) {
            let target = IndexSet(
                entries.enumerated().compactMap { index, entry in
                    entry.itemId.map { owner.selection.contains($0) ? index : nil } ?? nil
                }
            )
            guard tableView.selectedRowIndexes != target else { return }
            isApplyingSelection = true
            tableView.selectRowIndexes(target, byExtendingSelection: false)
            isApplyingSelection = false
            if let first = target.first {
                tableView.scrollRowToVisible(first)
            }
        }

        // MARK: - Data source

        internal func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        internal func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard row < entries.count else { return nil }
            switch entries[row] {
            case .header(_, let title):
                return FieldDrivenHeaderView.make(title: title)
            case .item(let item):
                let cell = tableView.makeView(
                    withIdentifier: FieldDrivenCellView<Row>.reuseIdentifier,
                    owner: self
                ) as? FieldDrivenCellView<Row> ?? FieldDrivenCellView<Row>()
                cell.update(rootView: owner.row(item))
                return cell
            }
        }

        internal func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            tableView.makeView(withIdentifier: FieldDrivenRowView.reuseIdentifier, owner: self) as? FieldDrivenRowView
                ?? FieldDrivenRowView.make()
        }

        internal func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            guard row < entries.count else { return false }
            return entries[row].isHeader
        }

        internal func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row < entries.count else { return false }
            return !entries[row].isHeader
        }

        internal func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let ids = tableView.selectedRowIndexes.compactMap { entries[$0].itemId }
            let next = Set(ids)
            guard next != owner.selection else { return }
            owner.selection = next
        }

        // MARK: - Actions

        @objc internal func handleSingleClick() {
            guard let action = owner.onSingleClickAction, let id = clickedItemId() else { return }
            action(id)
        }

        @objc internal func handleDoubleClick() {
            guard let id = clickedItemId() else { return }
            owner.onPrimaryAction(id)
        }

        private func clickedItemId() -> Item.ID? {
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedRow < entries.count else { return nil }
            return entries[tableView.clickedRow].itemId
        }

        @objc private func performMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuAction)?.perform()
        }

        internal func menu(forRow row: Int) -> NSMenu? {
            guard let build = owner.menuItems, row >= 0, row < entries.count,
                  let id = entries[row].itemId else { return nil }
            let targets = owner.selection.contains(id) ? owner.selection : [id]
            let descriptors = build(targets)
            guard !descriptors.isEmpty else { return nil }
            let menu = NSMenu()
            for descriptor in descriptors {
                if descriptor.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: descriptor.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = MenuAction(descriptor.action)
                menu.addItem(item)
            }
            return menu
        }
    }

    private final class MenuAction {
        private let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        func perform() { body() }
    }
}

/// The row draws emphasized whenever the window carrying it is key, because the highlight stands
/// for the search field's selection and that field is the thing holding focus. `window` is read
/// rather than `NSApp.keyWindow`, which does not return a popover's own window.
internal final class FieldDrivenRowView: NSTableRowView {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("FieldDrivenRow")

    internal static func make() -> FieldDrivenRowView {
        let view = FieldDrivenRowView()
        view.identifier = reuseIdentifier
        return view
    }

    /// `NSTableRowView` declares this settable, so an override has to supply a setter. AppKit is
    /// the only caller and it has nothing to tell this row that the key window does not.
    override internal var isEmphasized: Bool {
        get { window?.isKeyWindow ?? false }
        set {}
    }
}

/// The table is a presentation of the field's selection, so it never takes focus away from the
/// field. Refusing first responder is what makes that true rather than incidental.
internal final class FieldDrivenTableView: NSTableView {
    override internal var acceptsFirstResponder: Bool { false }

    override internal func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return (delegate as? (any FieldDrivenMenuProviding))?.menu(forRow: row)
    }
}

internal protocol FieldDrivenMenuProviding: AnyObject {
    @MainActor func menu(forRow row: Int) -> NSMenu?
}

extension FieldDrivenList.Coordinator: FieldDrivenMenuProviding {}

internal final class FieldDrivenCellView<Row: View>: NSTableCellView {
    internal static var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("FieldDrivenCell")
    }

    private var hosting: NSHostingView<Row>?

    internal func update(rootView: Row) {
        identifier = Self.reuseIdentifier
        if let hosting {
            hosting.rootView = rootView
            return
        }
        let view = NSHostingView(rootView: rootView)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosting = view
    }
}

internal enum FieldDrivenHeaderView {
    internal static func make(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}
