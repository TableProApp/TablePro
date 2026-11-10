import AppKit
import SwiftUI

struct TableHealthTableColumn: Sendable {
    let column: TableHealthColumn
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat?

    init(_ column: TableHealthColumn, min: CGFloat, ideal: CGFloat, max: CGFloat? = nil) {
        self.column = column
        minWidth = min
        idealWidth = ideal
        maxWidth = max
    }
}

// An NSTableView, not a SwiftUI Table: under the app's bare NSHostingController a click on a SwiftUI
// Table row lands on its cell hosting view, which handles it without making the table first responder,
// so the selection stays grey and the arrow keys reach whatever held the keyboard before.
struct TableHealthRowsTable: NSViewRepresentable {
    let rows: [TableHealthFindingRow]
    let columns: [TableHealthTableColumn]
    @Binding var selection: Set<TableHealthFindingID>
    @Binding var sortOrder: [KeyPathComparator<TableHealthFindingRow>]
    let accessibilityLabel: String
    let menu: ([TableHealthFindingRow]) -> [SidebarMenuSection<TableHealthRowCommand>]
    let perform: (TableHealthRowCommand, [TableHealthFindingRow]) -> Void
    var primaryAction: (([TableHealthFindingRow]) -> Void)?
    let copyText: () -> String?

    func makeCoordinator() -> TableHealthRowsTableCoordinator {
        TableHealthRowsTableCoordinator(owner: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = TableHealthNSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setAccessibilityLabel(accessibilityLabel)
        for spec in columns {
            let column = NSTableColumn(identifier: spec.column.identifier)
            column.title = spec.column.title
            column.minWidth = spec.minWidth
            column.width = spec.idealWidth
            if let maxWidth = spec.maxWidth {
                column.maxWidth = maxWidth
            }
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.column.identifier.rawValue, ascending: true)
            tableView.addTableColumn(column)
        }

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(TableHealthRowsTableCoordinator.handleDoubleClick)
        tableView.copySource = context.coordinator
        tableView.primaryActionSource = context.coordinator
        // The table owns the menu, so AppKit sets `clickedRow` and draws the clicked-row outline.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.attach(tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(owner: self)
    }
}

@MainActor
protocol TableHealthCopySource: AnyObject {
    func copyText() -> String?
}

@MainActor
protocol TableHealthPrimaryActionSource: AnyObject {
    func performPrimaryAction() -> Bool
}

// Return runs the primary action and Edit > Copy copies the selection; NSTableView routes neither on its own.
final class TableHealthNSTableView: NSTableView {
    weak var copySource: (any TableHealthCopySource)?
    weak var primaryActionSource: (any TableHealthPrimaryActionSource)?

    // Measured: NSTableView takes Return in keyDown and never sends insertNewline(_:).
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = KeyCode(rawValue: event.keyCode)
        if key == .return || key == .enter,
           modifiers.isDisjoint(with: [.command, .option, .control, .shift]),
           primaryActionSource?.performPrimaryAction() == true {
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = copySource?.copyText() else { return }
        ClipboardService.shared.writeText(text)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(copy(_:)) else { return super.validateUserInterfaceItem(item) }
        return copySource?.copyText() != nil
    }
}

@MainActor
final class TableHealthRowsTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    TableHealthCopySource, TableHealthPrimaryActionSource {
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("TableHealthTextCell")

    // What a reload has to redraw. Rows equal in all of it keep their views and the selection.
    private struct RowKey: Equatable {
        let id: TableHealthFindingID
        let status: TableHealthRowStatus
        let checkTitle: String
        let size: Int64
        let detail: String
        let lastSeen: Date

        init(_ row: TableHealthFindingRow) {
            id = row.id
            status = row.status
            checkTitle = row.checkTitle
            size = row.sizeSortKey
            detail = row.detail
            lastSeen = row.lastSeenSortKey
        }
    }

    private(set) var owner: TableHealthRowsTable
    private weak var tableView: NSTableView?
    private var rows: [TableHealthFindingRow] = []
    private var rowKeys: [RowKey] = []
    private var menuRows: [TableHealthFindingRow] = []
    private var isSyncing = false

    init(owner: TableHealthRowsTable) {
        self.owner = owner
        super.init()
    }

    func attach(_ tableView: NSTableView) {
        self.tableView = tableView
        update(owner: owner)
    }

    func update(owner: TableHealthRowsTable) {
        self.owner = owner
        guard let tableView else { return }
        isSyncing = true
        defer { isSyncing = false }

        rows = owner.rows
        let keys = owner.rows.map(RowKey.init)
        if keys != rowKeys {
            rowKeys = keys
            tableView.reloadData()
        }

        let descriptors = TableHealthTableSort.descriptors(for: owner.sortOrder, columns: columnKinds)
        if !TableHealthTableSort.same(tableView.sortDescriptors, descriptors) {
            tableView.sortDescriptors = descriptors
        }

        let wanted = IndexSet(rows.indices.filter { owner.selection.contains(rows[$0].id) })
        if wanted != tableView.selectedRowIndexes {
            tableView.selectRowIndexes(wanted, byExtendingSelection: false)
        }
    }

    private var columnKinds: [TableHealthColumn] {
        owner.columns.map(\.column)
    }

    private func rows(at indexes: IndexSet) -> [TableHealthFindingRow] {
        indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    // A right-click on a selected row acts on the whole selection, on any other row on that row alone.
    private func clickedRows() -> [TableHealthFindingRow] {
        guard let tableView, rows.indices.contains(tableView.clickedRow) else { return [] }
        if tableView.selectedRowIndexes.contains(tableView.clickedRow) {
            return rows(at: tableView.selectedRowIndexes)
        }
        return [rows[tableView.clickedRow]]
    }

    // MARK: - Actions

    @objc func handleDoubleClick() {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        owner.primaryAction?(clickedRows())
    }

    func performPrimaryAction() -> Bool {
        guard let primaryAction = owner.primaryAction, let tableView else { return false }
        primaryAction(rows(at: tableView.selectedRowIndexes))
        return true
    }

    func copyText() -> String? {
        owner.copyText()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuRows = clickedRows()
        SidebarMenuBuilder.fill(
            menu,
            with: owner.menu(menuRows),
            target: self,
            action: #selector(performMenuCommand(_:))
        )
    }

    @objc func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SidebarMenuCommandBox<TableHealthRowCommand> else { return }
        owner.perform(box.command, menuRows)
    }

    // MARK: - Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row),
              let column = columnKinds.first(where: { $0.identifier == tableColumn.identifier })
        else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? TableHealthTextCellView
            ?? TableHealthTextCellView(identifier: Self.cellIdentifier)
        cell.configure(column: column, row: rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, let tableView else { return }
        owner.selection = Set(rows(at: tableView.selectedRowIndexes).map(\.id))
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncing else { return }
        owner.sortOrder = TableHealthTableSort.comparators(for: tableView.sortDescriptors, columns: columnKinds)
    }
}

final class TableHealthTextCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(column: TableHealthColumn, row: TableHealthFindingRow) {
        guard let field = textField else { return }
        let text = column.text(for: row)
        field.stringValue = text
        field.lineBreakMode = column.lineBreakMode
        field.alignment = column.alignment
        field.font = column.usesMonospacedDigits
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        field.toolTip = column == .detail && !text.isEmpty ? text : nil
    }
}

extension TableHealthColumn {
    var identifier: NSUserInterfaceItemIdentifier {
        switch self {
        case .status: return NSUserInterfaceItemIdentifier("status")
        case .check: return NSUserInterfaceItemIdentifier("check")
        case .table: return NSUserInterfaceItemIdentifier("table")
        case .object: return NSUserInterfaceItemIdentifier("object")
        case .size: return NSUserInterfaceItemIdentifier("size")
        case .detail: return NSUserInterfaceItemIdentifier("detail")
        case .lastSeen: return NSUserInterfaceItemIdentifier("lastSeen")
        }
    }

    var lineBreakMode: NSLineBreakMode {
        switch self {
        case .table, .object: return .byTruncatingMiddle
        case .status, .check, .size, .detail, .lastSeen: return .byTruncatingTail
        }
    }

    var alignment: NSTextAlignment {
        self == .size ? .right : .natural
    }

    var usesMonospacedDigits: Bool {
        self == .size || self == .lastSeen
    }
}

// The header's sort descriptors and the view model's comparators, each derived from the other.
enum TableHealthTableSort {
    static func comparator(for column: TableHealthColumn, order: SortOrder) -> KeyPathComparator<TableHealthFindingRow> {
        switch column {
        case .status:
            return KeyPathComparator(\TableHealthFindingRow.statusRank, order: order)
        case .check:
            return KeyPathComparator(\TableHealthFindingRow.checkOrder, order: order)
        case .table:
            return KeyPathComparator(
                \TableHealthFindingRow.tableSortKey,
                comparator: String.StandardComparator.localizedStandard,
                order: order
            )
        case .object:
            return KeyPathComparator(
                \TableHealthFindingRow.objectSortKey,
                comparator: String.StandardComparator.localizedStandard,
                order: order
            )
        case .size:
            return KeyPathComparator(\TableHealthFindingRow.sizeSortKey, order: order)
        case .detail:
            return KeyPathComparator(
                \TableHealthFindingRow.detail,
                comparator: String.StandardComparator.localizedStandard,
                order: order
            )
        case .lastSeen:
            return KeyPathComparator(\TableHealthFindingRow.lastSeenSortKey, order: order)
        }
    }

    static func comparators(
        for descriptors: [NSSortDescriptor],
        columns: [TableHealthColumn]
    ) -> [KeyPathComparator<TableHealthFindingRow>] {
        descriptors.compactMap { descriptor in
            guard let column = columns.first(where: { $0.identifier.rawValue == descriptor.key }) else { return nil }
            return comparator(for: column, order: descriptor.ascending ? .forward : .reverse)
        }
    }

    static func descriptors(
        for comparators: [KeyPathComparator<TableHealthFindingRow>],
        columns: [TableHealthColumn]
    ) -> [NSSortDescriptor] {
        comparators.compactMap { sort in
            guard let column = columns.first(where: { comparator(for: $0, order: .forward).keyPath == sort.keyPath })
            else { return nil }
            return NSSortDescriptor(key: column.identifier.rawValue, ascending: sort.order == .forward)
        }
    }

    static func same(_ lhs: [NSSortDescriptor], _ rhs: [NSSortDescriptor]) -> Bool {
        lhs.map(\.key) == rhs.map(\.key) && lhs.map(\.ascending) == rhs.map(\.ascending)
    }
}
