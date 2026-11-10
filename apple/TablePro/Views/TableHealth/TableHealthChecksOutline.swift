import AppKit
import SwiftUI

struct TableHealthChecksRow: Equatable {
    let scope: TableHealthScope
    let title: String
    let systemImage: String
    let badge: String?
    let toolTip: String?
}

struct TableHealthChecksSection: Equatable {
    let title: String?
    let rows: [TableHealthChecksRow]
}

// An NSOutlineView source list, not a SwiftUI List: under the app's bare NSHostingController a click on a
// SwiftUI List row lands on its cell hosting view, which never makes the list first responder, so the
// selection stays grey and the arrow keys reach whatever held the keyboard before (FavoritesOutlineView).
struct TableHealthChecksOutline: NSViewRepresentable {
    let sections: [TableHealthChecksSection]
    @Binding var scope: TableHealthScope
    let menu: (TableHealthScope) -> [SidebarMenuSection<TableHealthRowCommand>]
    let perform: (TableHealthRowCommand) -> Void
    let copyText: () -> String?

    func makeCoordinator() -> TableHealthChecksCoordinator {
        TableHealthChecksCoordinator(owner: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = TableHealthChecksNSOutlineView()
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        // Some scope is always shown, so the list never deselects into nothing.
        outlineView.allowsEmptySelection = false
        outlineView.floatsGroupRows = false
        outlineView.autosaveExpandedItems = false
        outlineView.setAccessibilityLabel(String(localized: "Checks"))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TableHealthChecksColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.copySource = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.attach(outlineView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(owner: self)
    }
}

final class TableHealthChecksNSOutlineView: NSOutlineView {
    weak var copySource: (any TableHealthCopySource)?

    // Without it Edit > Copy falls through to the window, which copies the sidebar's table names.
    @objc func copy(_ sender: Any?) {
        guard let text = copySource?.copyText() else { return }
        ClipboardService.shared.writeText(text)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(copy(_:)) else { return super.validateUserInterfaceItem(item) }
        return copySource?.copyText() != nil
    }
}

final class TableHealthChecksNode: NSObject {
    let id: String
    var title: String
    var row: TableHealthChecksRow?
    var children: [TableHealthChecksNode] = []

    init(id: String, title: String, row: TableHealthChecksRow?) {
        self.id = id
        self.title = title
        self.row = row
    }

    var isGroup: Bool { row == nil }
}

@MainActor
final class TableHealthChecksCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    TableHealthCopySource {
    private static let rowCellIdentifier = NSUserInterfaceItemIdentifier("TableHealthCheckCell")
    private static let headerCellIdentifier = NSUserInterfaceItemIdentifier("TableHealthChecksHeaderCell")

    private(set) var owner: TableHealthChecksOutline
    private weak var outlineView: NSOutlineView?
    // Kept by id and updated in place, so a refresh that changes only a badge keeps the rows and the selection.
    private var nodes: [String: TableHealthChecksNode] = [:]
    private var roots: [TableHealthChecksNode] = []
    private var structure: [String] = []
    private var isSyncing = false

    init(owner: TableHealthChecksOutline) {
        self.owner = owner
        super.init()
    }

    static func nodeId(for scope: TableHealthScope) -> String {
        switch scope {
        case .all: return "all"
        case .check(let kind): return "check." + kind.rawValue
        case .resolved: return "resolved"
        }
    }

    func attach(_ outlineView: NSOutlineView) {
        self.outlineView = outlineView
        update(owner: owner)
    }

    func update(owner: TableHealthChecksOutline) {
        self.owner = owner
        guard let outlineView else { return }
        isSyncing = true
        defer { isSyncing = false }

        roots = buildRoots(owner.sections)
        let shape = roots.flatMap { [$0.id] + $0.children.map { "  " + $0.id } }
        if shape != structure {
            structure = shape
            outlineView.reloadData()
            for node in roots where node.isGroup {
                outlineView.expandItem(node)
            }
        } else {
            refreshVisibleRows(in: outlineView)
        }

        if let node = nodes[Self.nodeId(for: owner.scope)] {
            let row = outlineView.row(forItem: node)
            if row >= 0, outlineView.selectedRow != row {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    private func buildRoots(_ sections: [TableHealthChecksSection]) -> [TableHealthChecksNode] {
        var built: [TableHealthChecksNode] = []
        for section in sections {
            let rows = section.rows.map { rowNode($0) }
            guard let title = section.title else {
                built += rows
                continue
            }
            let group = node(id: "group." + title, title: title, row: nil)
            group.children = rows
            built.append(group)
        }
        return built
    }

    private func rowNode(_ row: TableHealthChecksRow) -> TableHealthChecksNode {
        node(id: Self.nodeId(for: row.scope), title: row.title, row: row)
    }

    private func node(id: String, title: String, row: TableHealthChecksRow?) -> TableHealthChecksNode {
        if let existing = nodes[id] {
            existing.title = title
            existing.row = row
            return existing
        }
        let created = TableHealthChecksNode(id: id, title: title, row: row)
        nodes[id] = created
        return created
    }

    private func refreshVisibleRows(in outlineView: NSOutlineView) {
        for index in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: index) as? TableHealthChecksNode,
                  let row = node.row,
                  let cell = outlineView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TableHealthCheckCellView
            else { continue }
            cell.configure(row)
        }
    }

    // MARK: - Copy and menu

    func copyText() -> String? {
        owner.copyText()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = outlineView.flatMap { $0.clickedRow >= 0 ? $0.item(atRow: $0.clickedRow) as? TableHealthChecksNode : nil }
        let sections = clicked?.row.map { owner.menu($0.scope) } ?? []
        SidebarMenuBuilder.fill(menu, with: sections, target: self, action: #selector(performMenuCommand(_:)))
    }

    @objc func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SidebarMenuCommandBox<TableHealthRowCommand> else { return }
        owner.perform(box.command)
    }

    // MARK: - Data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? TableHealthChecksNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? TableHealthChecksNode)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TableHealthChecksNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? TableHealthChecksNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? TableHealthChecksNode)?.isGroup == false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? TableHealthChecksNode)?.row?.title
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TableHealthChecksNode else { return nil }
        guard let row = node.row else {
            let cell = outlineView.makeView(withIdentifier: Self.headerCellIdentifier, owner: self)
                as? TableHealthChecksHeaderCellView ?? TableHealthChecksHeaderCellView(identifier: Self.headerCellIdentifier)
            cell.textField?.stringValue = node.title
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: Self.rowCellIdentifier, owner: self)
            as? TableHealthCheckCellView ?? TableHealthCheckCellView(identifier: Self.rowCellIdentifier)
        cell.configure(row)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, let outlineView,
              let scope = (outlineView.item(atRow: outlineView.selectedRow) as? TableHealthChecksNode)?.row?.scope,
              scope != owner.scope
        else { return }
        owner.scope = scope
    }
}

// AppKit sets the title's font and the symbol's size from the row size and turns both white on the
// emphasized selection; the symbol slot and the badge follow the title's size.
final class TableHealthCheckCellView: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private var symbolWidth: NSLayoutConstraint?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [image, title, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = image
        textField = title
        // One slot width for every symbol, so the titles line up.
        let symbolWidth = image.widthAnchor.constraint(equalToConstant: Self.slotWidth(forTitleSize: NSFont.systemFontSize))
        self.symbolWidth = symbolWidth
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolWidth,
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TableHealthCheckCellView does not support NSCoder init")
    }

    private static func slotWidth(forTitleSize titleSize: CGFloat) -> CGFloat {
        (titleSize * 1.75).rounded()
    }

    func configure(_ row: TableHealthChecksRow) {
        imageView?.image = NSImage(systemSymbolName: row.systemImage, accessibilityDescription: nil)
        textField?.stringValue = row.title
        badge.stringValue = row.badge ?? ""
        badge.isHidden = row.badge == nil
        toolTip = row.toolTip
    }

    override func layout() {
        if let size = textField?.font?.pointSize {
            let width = Self.slotWidth(forTitleSize: size)
            if let symbolWidth, symbolWidth.constant != width {
                symbolWidth.constant = width
            }
            let font = NSFont.monospacedDigitSystemFont(ofSize: max(size - 2, NSFont.smallSystemFontSize - 1), weight: .regular)
            if badge.font != font {
                badge.font = font
            }
        }
        super.layout()
    }
}

final class TableHealthChecksHeaderCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let title = NSTextField(labelWithString: "")
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TableHealthChecksHeaderCellView does not support NSCoder init")
    }
}
