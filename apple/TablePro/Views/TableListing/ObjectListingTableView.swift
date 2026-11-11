//
//  ObjectListingTableView.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

/// The Objects tab's rows as a list in the system font: the sidebar's glyph before each name, sortable
/// headers, columns shown or hidden from the header's menu, multi-select, the row menu, and a double
/// click or Return to open.
///
/// AppKit on purpose. The data grid draws records: monospaced cells, row numbers and a cell cursor,
/// which a list of objects has no use for. A SwiftUI `Table` cannot hide a column from the header's
/// menu or draw a records header and selection through `ThemeTableHeaderView` and `ThemeTableChrome`.
internal struct ObjectListingTableView: NSViewRepresentable {
    @ObservedObject var list: ObjectListingList
    let model: TableListingViewModel

    func makeCoordinator() -> ObjectListingTableCoordinator {
        ObjectListingTableCoordinator(list: list, model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.sync()
    }
}

/// Return opens and Copy copies the selected names. `NSTableView` routes neither on its own.
internal final class ObjectListingNSTableView: NSTableView {
    internal weak var coordinator: ObjectListingTableCoordinator?

    override internal func insertNewline(_ sender: Any?) {
        coordinator?.openSelection()
    }

    @objc internal func copy(_ sender: Any?) {
        coordinator?.copySelectedNames()
    }

    override internal func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return !selectedRowIndexes.isEmpty
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// A right-click on the header lists the columns to show or hide.
internal final class ObjectListingHeaderView: ThemeTableHeaderView {
    internal weak var coordinator: ObjectListingTableCoordinator?

    override internal func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.columnMenu() ?? super.menu(for: event)
    }
}

@MainActor
internal final class ObjectListingTableCoordinator: NSObject {
    private static let rowHeight: CGFloat = 22

    private(set) var list: ObjectListingList
    weak var model: TableListingViewModel?

    private weak var tableView: ObjectListingNSTableView?
    // Held here: its theme subscription and the row views hold it weakly.
    private var themeChrome: ThemeTableChrome?
    private var themeSubscription: AnyCancellable?
    private var iconStyleSubscription: AnyCancellable?
    private var iconStyle = AppSettingsManager.shared.appearance.objectIconStyle
    private var builtColumnIDs: [String] = []
    private var appliedRevision: Int?
    private var isApplyingSort = false
    private var isApplyingSelection = false

    init(list: ObjectListingList, model: TableListingViewModel) {
        self.list = list
        self.model = model
    }

    func makeScrollView() -> NSScrollView {
        let tableView = ObjectListingNSTableView()
        tableView.coordinator = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = Self.rowHeight
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow)
        tableView.setAccessibilityLabel(String(localized: "Objects"))
        tableView.setAccessibilityIdentifier("objects-list")

        let header = ObjectListingHeaderView()
        header.coordinator = self
        tableView.headerView = header

        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        self.tableView = tableView

        buildColumnsIfNeeded()
        // Attached once the table sits in its scroll view and before it builds rows: the chrome
        // records the scroll view's background to give it back.
        themeChrome = ThemeTableChrome(tableView: tableView, family: .records)
        themeSubscription = ThemeScope.live.changes
            .sink { [weak self] _ in self?.restyleVisibleCells() }
        iconStyleSubscription = AppEvents.shared.objectIconStyleChanged
            .sink { [weak self] style in self?.applyIconStyle(style) }
        sync()
        return scrollView
    }

    /// Brings the table up to the list: columns, then rows, then the sort arrow and the selection.
    func sync() {
        guard let tableView else { return }
        buildColumnsIfNeeded()
        applyColumnVisibility()
        applySortIndicator()
        if appliedRevision != list.revision {
            appliedRevision = list.revision
            // A reload keeps the selected positions, which may now hold other objects; the list's
            // selection by object is put back right after.
            isApplyingSelection = true
            tableView.reloadData()
            isApplyingSelection = false
        }
        applySelection()
    }

    // MARK: - Columns

    private func buildColumnsIfNeeded() {
        guard let tableView else { return }
        let ids = list.columns.map(\.id)
        guard ids != builtColumnIDs else { return }
        builtColumnIDs = ids
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        for column in list.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.headerCell = ThemeTableHeaderCell()
            tableColumn.title = column.title
            tableColumn.headerToolTip = column.title
            tableColumn.minWidth = 40
            tableColumn.width = list.columnWidths[column.id] ?? Self.defaultWidth(of: column)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.id,
                // Numbers and dates read largest or newest first; names read A to Z.
                ascending: column.format == .text
            )
            tableColumn.isHidden = !list.isShown(column)
            tableView.addTableColumn(tableColumn)
        }
    }

    // Hiding keeps the column's place and width. The list has a dozen columns at most, so the cost
    // `isHidden` has on a wide grid does not apply.
    private func applyColumnVisibility() {
        guard let tableView else { return }
        for column in list.columns {
            guard let tableColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.id)) else {
                continue
            }
            let hidden = !list.isShown(column)
            if tableColumn.isHidden != hidden {
                tableColumn.isHidden = hidden
            }
        }
    }

    private static func defaultWidth(of column: ObjectListingColumn) -> CGFloat {
        if column.id == "name" { return 240 }
        switch column.format {
        case .count, .bytes: return 96
        case .date: return 150
        case .text: return column.id == "comment" ? 240 : 130
        }
    }

    func columnMenu() -> NSMenu {
        let menu = NSMenu()
        for column in list.columns where column.id != "name" {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.id
            item.state = list.isShown(column) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = list.columns.first(where: { $0.id == id })
        else { return }
        list.setColumn(id, shown: !list.isShown(column))
        applyColumnVisibility()
    }

    // MARK: - Sort

    private func applySortIndicator() {
        guard let tableView else { return }
        let descriptors = list.sort.map { [NSSortDescriptor(key: $0.columnID, ascending: $0.ascending)] } ?? []
        if tableView.sortDescriptors != descriptors {
            // Setting the descriptors calls back into `sortDescriptorsDidChange`.
            isApplyingSort = true
            tableView.sortDescriptors = descriptors
            isApplyingSort = false
        }
        // AppKit reports no sort direction to VoiceOver on its own.
        for tableColumn in tableView.tableColumns {
            let direction: NSAccessibilitySortDirection
            if let sort = list.sort, sort.columnID == tableColumn.identifier.rawValue {
                direction = sort.ascending ? .ascending : .descending
            } else {
                direction = .unknown
            }
            tableColumn.headerCell.setAccessibilitySortDirection(direction)
        }
    }

    // MARK: - Selection

    private func applySelection() {
        guard let tableView else { return }
        let wanted = IndexSet(list.rows.indices.filter { list.selection.contains(list.rows[$0].item.key) })
        guard tableView.selectedRowIndexes != wanted else { return }
        isApplyingSelection = true
        tableView.selectRowIndexes(wanted, byExtendingSelection: false)
        isApplyingSelection = false
    }

    private func row(at index: Int) -> ObjectListingRow? {
        list.rows.indices.contains(index) ? list.rows[index] : nil
    }

    private var selectedRows: [ObjectListingRow] {
        tableView?.selectedRowIndexes.compactMap(row(at:)) ?? []
    }

    // MARK: - Commands

    @objc private func openClickedRow() {
        guard let tableView, let row = row(at: tableView.clickedRow) else { return }
        model?.open(row.item)
    }

    func openSelection() {
        model?.openSelection()
    }

    func copySelectedNames() {
        let names = selectedRows.map(\.item.name)
        guard !names.isEmpty else { return }
        ClipboardService.shared.writeText(names.joined(separator: ","))
    }

    // MARK: - Theme

    private func restyleVisibleCells() {
        tableView?.enumerateAvailableRowViews { rowView, _ in
            for index in 0 ..< rowView.numberOfColumns {
                (rowView.view(atColumn: index) as? ObjectListingCellView)?.applyStyle()
            }
        }
    }

    // MARK: - Icon style

    private func icon(for row: ObjectListingRow) -> ObjectIcon {
        ObjectIconProvider.icon(for: row.item.iconKind, style: iconStyle)
    }

    /// A glyph is set when its cell is configured, so the cells on screen are given the new one;
    /// the rest pick it up as they are configured.
    private func applyIconStyle(_ style: ObjectIconStyle) {
        iconStyle = style
        guard let tableView else { return }
        let nameIndex = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard nameIndex >= 0 else { return }
        tableView.enumerateAvailableRowViews { rowView, index in
            guard let row = row(at: index),
                  let cell = rowView.view(atColumn: nameIndex) as? ObjectListingCellView else { return }
            cell.showGlyph(icon(for: row), label: row.item.kindName)
        }
    }
}

extension ObjectListingTableCoordinator: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        list.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let tableColumn, let row = row(at: index),
              let column = list.columns.first(where: { $0.id == tableColumn.identifier.rawValue })
        else { return nil }
        let isName = column.id == "name"
        let identifier = isName ? ObjectListingCellView.nameIdentifier : ObjectListingCellView.valueIdentifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ObjectListingCellView
            ?? ObjectListingCellView(identifier: identifier, showsGlyph: isName)
        let text = row.texts.indices.contains(column.valueIndex) ? row.texts[column.valueIndex] : ""
        cell.configure(
            text: text,
            alignsTrailing: column.format.alignsTrailing,
            glyph: isName ? icon(for: row) : nil,
            glyphLabel: isName ? row.item.kindName : nil
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        themeChrome?.makeRowView(in: tableView)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row index: Int) -> String? {
        guard tableColumn?.identifier.rawValue == "name" else { return nil }
        return row(at: index)?.item.name
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSort else { return }
        // One key at a time: a click replaces the sort rather than adding a second key behind it.
        let sort = tableView.sortDescriptors.first.flatMap { descriptor in
            descriptor.key.map { ObjectListingSort(columnID: $0, ascending: descriptor.ascending) }
        }
        list.setSort(sort)
        sync()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, themeChrome?.isRebuildingRows != true else { return }
        list.select(Set(selectedRows.map(\.item.key)))
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        list.columnWidths[column.identifier.rawValue] = column.width
    }
}

extension ObjectListingTableCoordinator: NSMenuDelegate {
    /// Built from `clickedRow`, so the clicked row's highlight is AppKit's own. The menu acts on the
    /// selection when the clicked row is part of it, else on the clicked row alone.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView, let model, let clicked = row(at: tableView.clickedRow) else { return }
        let targets = tableView.selectedRowIndexes.contains(tableView.clickedRow) ? selectedRows.map(\.item) : [clicked.item]
        for item in model.menuItems(clicked: clicked.item, targets: targets) {
            menu.addItem(item)
        }
    }
}

/// One line of text, with the object's glyph in the Name column.
internal final class ObjectListingCellView: NSTableCellView {
    internal static let nameIdentifier = NSUserInterfaceItemIdentifier("ObjectListingNameCell")
    internal static let valueIdentifier = NSUserInterfaceItemIdentifier("ObjectListingValueCell")

    private let label = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    /// The colorful style's hue; nil draws the glyph in the accent, as the sidebar does.
    private var glyphTint: NSColor?

    internal init(identifier: NSUserInterfaceItemIdentifier, showsGlyph: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label

        var constraints = [
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if showsGlyph {
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.imageScaling = .scaleProportionallyDown
            addSubview(glyph)
            imageView = glyph
            constraints += [
                glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: 16),
                glyph.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("ObjectListingCellView does not support NSCoder init")
    }

    override internal var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    internal func configure(text: String, alignsTrailing: Bool, glyph icon: ObjectIcon?, glyphLabel: String?) {
        label.stringValue = text
        label.alignment = alignsTrailing ? .right : .natural
        // Digits of one width, so counts and sizes line up down the column.
        label.font = alignsTrailing
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        if let icon {
            showGlyph(icon, label: glyphLabel)
        } else {
            applyStyle()
        }
    }

    internal func showGlyph(_ icon: ObjectIcon, label: String?) {
        glyph.image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: label)
        glyphTint = icon.tint?.nsColor
        applyStyle()
    }

    /// Also run on a theme change: a field redraws only when it is handed a new color.
    internal func applyStyle() {
        let isEmphasized = backgroundStyle == .emphasized
        let slot = ThemeTableChrome.recordsTextSlot(
            onEmphasizedSelection: isEmphasized,
            highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        label.textColor = slot.map { ThemeScope.live.palette[$0] } ?? .labelColor
        // The sidebar's tint for the same glyph, turning white on the emphasized selection as the text does.
        glyph.contentTintColor = isEmphasized ? .alternateSelectedControlTextColor : glyphTint ?? .controlAccentColor
    }
}

extension ObjectListingItem {
    /// What VoiceOver says the glyph shows.
    var kindName: String {
        switch self {
        case .relation(_, _, let type): return TableRowLogic.accessibilityKindLabel(for: type)
        case .sourced(let ref): return ref.kind.displayName
        }
    }
}
