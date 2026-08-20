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
    internal let isEnabled: Bool
    /// Drawn as a checkmark. A menu that reports the current value is how a picker-shaped command
    /// says which option is already chosen.
    internal let isOn: Bool
    internal let submenu: [FieldDrivenMenuItem]
    internal let action: () -> Void

    internal init(
        title: String,
        isEnabled: Bool = true,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSeparator = false
        self.isEnabled = isEnabled
        self.isOn = isOn
        self.submenu = []
        self.action = action
    }

    internal init(title: String, submenu: [FieldDrivenMenuItem]) {
        self.title = title
        self.isSeparator = false
        self.isEnabled = !submenu.isEmpty
        self.isOn = false
        self.submenu = submenu
        self.action = {}
    }

    private init() {
        self.title = ""
        self.isSeparator = true
        self.isEnabled = false
        self.isOn = false
        self.submenu = []
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
    /// A browser takes focus so it can be arrowed through; a chooser leaves focus in its field.
    internal var acceptsFocus = false
    internal var onDeleteCommand: (() -> Void)?
    internal var onCopyCommand: (() -> Void)?
    /// Set on the table view itself, because an identifier applied to the SwiftUI wrapper does not
    /// reach the AppKit view a test or a screen reader actually queries.
    internal var accessibilityIdentifier: String?
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
        tableView.acceptsFocus = acceptsFocus
        if let accessibilityIdentifier {
            tableView.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        context.coordinator.bindKeyboardActions(to: tableView)

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

        /// The closures capture the coordinator rather than the owner, because the owner is a
        /// struct that SwiftUI replaces on every update while the table view outlives all of them.
        internal func bindKeyboardActions(to tableView: FieldDrivenTableView) {
            tableView.onActivate = { [weak self] in
                guard let self, let id = owner.selection.first else { return }
                owner.onPrimaryAction(id)
            }
            tableView.onDelete = { [weak self] in self?.owner.onDeleteCommand?() }
            tableView.onCopy = { [weak self] in self?.owner.onCopyCommand?() }
        }

        internal func apply(owner: FieldDrivenList) {
            self.owner = owner
            guard let tableView else { return }
            tableView.acceptsFocus = owner.acceptsFocus
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

        /// The emphasis rule is pushed onto the row here rather than read back off the view
        /// hierarchy, because AppKit installs a row's cell views before the row itself reaches the
        /// table. See `FieldDrivenRowView`.
        internal func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: FieldDrivenRowView.reuseIdentifier, owner: self)
                as? FieldDrivenRowView ?? FieldDrivenRowView.make()
            rowView.followsWindowKeyState = !owner.acceptsFocus
            return rowView
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

        /// Auto-enabling asks the target whether it responds to the item's selector, which it
        /// always does, so a descriptor's own `isEnabled` would be overwritten on display.
        internal func menu(forRow row: Int) -> NSMenu? {
            guard let build = owner.menuItems, row >= 0, row < entries.count,
                  let id = entries[row].itemId else { return nil }
            let targets = owner.selection.contains(id) ? owner.selection : [id]
            let descriptors = build(targets)
            guard !descriptors.isEmpty else { return nil }
            return makeMenu(from: descriptors)
        }

        private func makeMenu(from descriptors: [FieldDrivenMenuItem]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for descriptor in descriptors {
                if descriptor.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: descriptor.title, action: nil, keyEquivalent: "")
                item.isEnabled = descriptor.isEnabled
                guard descriptor.submenu.isEmpty else {
                    item.submenu = makeMenu(from: descriptor.submenu)
                    menu.addItem(item)
                    continue
                }
                item.action = #selector(performMenuItem(_:))
                item.target = self
                item.state = descriptor.isOn ? .on : .off
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

/// A chooser's highlight stands for the search field's selection, so it draws emphasized whenever
/// the window is key: the field is the thing holding focus. A browser owns its own focus, so AppKit
/// already emphasizes it exactly right and this row leaves the property alone.
internal final class FieldDrivenRowView: NSTableRowView {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("FieldDrivenRow")

    /// Set from `tableView(_:rowViewForRow:)`, which runs before AppKit installs any cell view.
    internal var followsWindowKeyState = false

    internal static func make() -> FieldDrivenRowView {
        let view = FieldDrivenRowView()
        view.identifier = reuseIdentifier
        return view
    }

    /// The setter has to forward, because AppKit's own stored value is what a browser row draws
    /// from and swallowing the write would leave every browser row permanently unemphasized.
    override internal var isEmphasized: Bool {
        get { followsWindowKeyState ? window?.isKeyWindow ?? false : super.isEmphasized }
        set { super.isEmphasized = newValue }
    }

    /// AppKit copies `interiorBackgroundStyle` into the cell views from `didAddSubview`, and a row
    /// is populated before it is added to the table, so at that moment `window` is still nil and a
    /// key-state-derived emphasis reads false. The row then paints its accent fill from the live
    /// value while the cells keep the unemphasized foreground: blue fill, dark text, until some
    /// later selection change happens to re-run the copy. Repeating it here is the first point the
    /// derived value is true, and AppKit keeps the two in step from then on.
    override internal func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard followsWindowKeyState else { return }
        let style = interiorBackgroundStyle
        for case let cell as NSTableCellView in subviews where cell.backgroundStyle != style {
            cell.backgroundStyle = style
        }
    }
}

/// A chooser is a presentation of a search field's selection, so it never takes focus away from
/// that field. A browser is read by arrowing through it, so it has to take focus like any other
/// list. `acceptsFocus` is the difference, and it stays off unless a caller asks for it.
internal final class FieldDrivenTableView: NSTableView {
    internal var acceptsFocus = false
    internal var onActivate: (() -> Void)?
    internal var onDelete: (() -> Void)?
    internal var onCopy: (() -> Void)?

    override internal var acceptsFirstResponder: Bool { acceptsFocus }

    override internal func keyDown(with event: NSEvent) {
        guard acceptsFocus else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            onActivate?()
        case 51, 117:
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }

    @objc internal func copy(_ sender: Any?) {
        onCopy?()
    }

    /// The menu is resolved before the selection moves, because `selectRowIndexes` does not consult
    /// `tableView(_:shouldSelectRow:)`: a right-click on a section header would otherwise select a
    /// row that carries no item, which reads back as an empty selection. Resolving first also keeps
    /// a right-click that produces no menu from moving the selection behind it. The targets a menu
    /// is built for are unaffected, since a click outside the selection always acts on its own row.
    override internal func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0,
              let provider = delegate as? (any FieldDrivenMenuProviding),
              let menu = provider.menu(forRow: row) else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menu
    }
}

internal protocol FieldDrivenMenuProviding: AnyObject {
    @MainActor func menu(forRow row: Int) -> NSMenu?
}

extension FieldDrivenList.Coordinator: FieldDrivenMenuProviding {}

/// A row draws its content and nothing more. Left to itself the hosting view takes first responder
/// on a click, which parks focus inside a cell and leaves the table unable to be arrowed through.
private final class FieldDrivenCellHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
        let view = FieldDrivenCellHostingView(rootView: rootView)
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
