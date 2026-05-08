//
//  DataGridView.swift
//  TablePro
//
//  High-performance NSTableView wrapper for SwiftUI.
//  Custom views extracted to separate files for maintainability.
//

import AppKit
import SwiftUI

struct CellPosition: Hashable {
    let row: Int
    let column: Int
}

struct RowVisualState {
    let isDeleted: Bool
    let isInserted: Bool
    let modifiedColumns: Set<Int>

    static let empty = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [])
}

struct DataGridView: NSViewRepresentable {
    var tableRowsProvider: @MainActor () -> TableRows = { TableRows() }
    var tableRowsMutator: @MainActor (@MainActor (inout TableRows) -> Void) -> Void = { _ in }
    var changeManager: AnyChangeManager
    let isEditable: Bool
    var configuration: DataGridConfiguration = .init()
    var sortedIDs: [RowID]?
    var displayFormats: [ValueDisplayFormat?] = []
    var delegate: (any DataGridViewDelegate)?
    var layoutPersister: (any ColumnLayoutPersisting)?

    @Binding var selectedRowIndices: Set<Int>
    @Binding var sortState: SortState
    @Binding var columnLayout: ColumnLayoutState

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        let tableView = KeyHandlingTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .plain
        tableView.wantsLayer = true
        tableView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        tableView.setAccessibilityLabel(String(localized: "Data grid"))
        tableView.setAccessibilityRole(.table)
        let settings = AppSettingsManager.shared.dataGrid
        tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)
        tableView.usesAutomaticRowHeights = false

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(TableViewCoordinator.handleClick(_:))
        tableView.doubleAction = #selector(TableViewCoordinator.handleDoubleClick(_:))

        let rowNumberColumn = Self.makeRowNumberColumn()
        tableView.addTableColumn(rowNumberColumn)
        rowNumberColumn.isHidden = !configuration.showRowNumbers

        let initialRows = tableRowsProvider()
        context.coordinator.rebuildColumnMetadataCache(from: initialRows)

        context.coordinator.isRebuildingColumns = true
        let initialLayout = context.coordinator.savedColumnLayout(binding: columnLayout)
        reconcileColumnPool(
            tableView: tableView,
            coordinator: context.coordinator,
            tableRows: initialRows,
            savedLayout: initialLayout
        )
        context.coordinator.isRebuildingColumns = false

        let sortableHeader = SortableHeaderView(frame: tableView.headerView?.frame ?? .zero)
        sortableHeader.coordinator = context.coordinator
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        sortableHeader.menu = headerMenu
        tableView.headerView = sortableHeader

        let hasMoveRow = delegate != nil
        if hasMoveRow {
            tableView.registerForDraggedTypes([NSPasteboard.PasteboardType("com.TablePro.rowDrag")])
            tableView.draggingDestinationFeedbackStyle = .gap
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.tableRowsController.attach(tableView)
        context.coordinator.tableRowsProvider = tableRowsProvider
        context.coordinator.tableRowsMutator = tableRowsMutator
        context.coordinator.sortedIDs = sortedIDs
        // Intentionally do not prime cachedRowCount/cachedColumnCount here.
        // They represent what NSTableView has actually rendered. Leaving them
        // at 0 ensures the first `updateNSView` detects a structure change
        // and triggers `reloadData()` — without this, a recreated grid (e.g.
        // after a Structure/JSON tab toggle) finds the cache already matching
        // the registry rows and skips the reload, leaving the table empty.
        context.coordinator.syncDisplayFormats(displayFormats)
        context.coordinator.delegate = delegate
        delegate?.dataGridAttach(tableViewCoordinator: context.coordinator)
        context.coordinator.dropdownColumns = configuration.dropdownColumns
        context.coordinator.typePickerColumns = configuration.typePickerColumns
        context.coordinator.customDropdownOptions = configuration.customDropdownOptions
        context.coordinator.connectionId = configuration.connectionId
        context.coordinator.databaseType = configuration.databaseType
        context.coordinator.tableName = configuration.tableName
        context.coordinator.primaryKeyColumns = configuration.primaryKeyColumns
        context.coordinator.tabType = configuration.tabType
        if let connectionId = configuration.connectionId {
            context.coordinator.observeTeardown(connectionId: connectionId)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator

        if tableView.editedRow >= 0 { return }
        if let editor = context.coordinator.overlayEditor, editor.isActive { return }

        if let rowNumCol = tableView.tableColumns.first(where: { $0.identifier == ColumnIdentitySchema.rowNumberIdentifier }) {
            let shouldHide = !configuration.showRowNumbers
            if rowNumCol.isHidden != shouldHide {
                rowNumCol.isHidden = shouldHide
            }
        }

        let rowDragType = NSPasteboard.PasteboardType("com.TablePro.rowDrag")
        let hasDragRegistered = tableView.registeredDraggedTypes.contains(rowDragType)
        let hasMoveRow = delegate != nil
        if hasMoveRow && !hasDragRegistered {
            tableView.registerForDraggedTypes([rowDragType])
            tableView.draggingDestinationFeedbackStyle = .gap
        } else if !hasMoveRow && hasDragRegistered {
            let remaining = tableView.registeredDraggedTypes.filter { $0 != rowDragType }
            tableView.unregisterDraggedTypes()
            if !remaining.isEmpty {
                tableView.registerForDraggedTypes(remaining)
            }
        }

        if let connectionId = configuration.connectionId, coordinator.teardownCancellable == nil {
            coordinator.observeTeardown(connectionId: connectionId)
        }

        let latestRows = tableRowsProvider()
        let rowDisplayCount = sortedIDs?.count ?? latestRows.count
        let columnCount = latestRows.columns.count

        let settings = AppSettingsManager.shared.dataGrid
        if tableView.rowHeight != CGFloat(settings.rowHeight.rawValue) {
            tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)
        }
        if tableView.usesAlternatingRowBackgroundColors != settings.showAlternateRows {
            tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows
        }

        let oldRowCount = coordinator.cachedRowCount
        let oldColumnCount = coordinator.cachedColumnCount

        let structureChanged = oldRowCount != rowDisplayCount || oldColumnCount != columnCount
        let needsFullReload = structureChanged

        coordinator.updateCache()
        coordinator.rebuildColumnMetadataCache(from: latestRows)

        if oldRowCount == 0, rowDisplayCount > 0 {
            let rowH = tableView.rowHeight
            if rowH > 0 {
                let visibleRows = Int(tableView.visibleRect.height / rowH) + 5
                coordinator.preWarmDisplayCache(upTo: visibleRows)
            }
        }

        coordinator.changeManager = changeManager
        coordinator.isEditable = isEditable
        coordinator.tableRowsProvider = tableRowsProvider
        coordinator.tableRowsMutator = tableRowsMutator
        coordinator.sortedIDs = sortedIDs
        coordinator.updateCache()
        coordinator.syncDisplayFormats(displayFormats)
        coordinator.delegate = delegate
        delegate?.dataGridAttach(tableViewCoordinator: coordinator)
        coordinator.dropdownColumns = configuration.dropdownColumns
        coordinator.typePickerColumns = configuration.typePickerColumns
        coordinator.customDropdownOptions = configuration.customDropdownOptions
        coordinator.connectionId = configuration.connectionId
        coordinator.databaseType = configuration.databaseType
        coordinator.tableName = configuration.tableName
        coordinator.primaryKeyColumns = configuration.primaryKeyColumns
        coordinator.tabType = configuration.tabType

        coordinator.visualIndex.rebuild(from: coordinator.changeManager, sortedIDs: coordinator.sortedIDs)

        if !latestRows.columns.isEmpty {
            coordinator.isRebuildingColumns = true
            let savedLayout = coordinator.savedColumnLayout(binding: columnLayout)
            reconcileColumnPool(
                tableView: tableView,
                coordinator: coordinator,
                tableRows: latestRows,
                savedLayout: savedLayout
            )
            coordinator.isRebuildingColumns = false

            if savedLayout == nil {
                coordinator.scheduleLayoutPersist()
            }
        }

        syncSortDescriptors(tableView: tableView, coordinator: coordinator, columns: latestRows.columns)

        reloadAndSyncSelection(
            tableView: tableView,
            coordinator: coordinator,
            needsFullReload: needsFullReload
        )
    }

    private func reconcileColumnPool(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        tableRows: TableRows,
        savedLayout: ColumnLayoutState?
    ) {
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: tableRows.columnTypes,
            savedLayout: savedLayout,
            isEditable: isEditable,
            hiddenColumnNames: configuration.hiddenColumns,
            widthCalculator: { columnName, slot in
                coordinator.cellFactory.calculateOptimalColumnWidth(
                    for: columnName,
                    columnIndex: slot,
                    tableRows: tableRows
                )
            }
        )
    }

    private func syncSortDescriptors(tableView: NSTableView, coordinator: TableViewCoordinator, columns: [String]) {
        coordinator.currentSortState = sortState

        let schema = coordinator.identitySchema
        let primaryIdentifier: NSUserInterfaceItemIdentifier?
        let primary: NSSortDescriptor?
        if let firstSort = sortState.columns.first,
           let identifier = schema.identifier(for: firstSort.columnIndex),
           let name = schema.columnName(for: firstSort.columnIndex) {
            primaryIdentifier = identifier
            primary = NSSortDescriptor(key: name, ascending: firstSort.direction == .ascending)
        } else {
            primaryIdentifier = nil
            primary = nil
        }

        let desired = primary.map { [$0] } ?? []
        let current = tableView.sortDescriptors.first
        let needsUpdate = (current?.key != primary?.key) || (current?.ascending != primary?.ascending)
        if needsUpdate {
            tableView.sortDescriptors = desired
        }

        if let primaryIdentifier {
            let columnIndex = tableView.column(withIdentifier: primaryIdentifier)
            tableView.highlightedTableColumn = columnIndex >= 0 ? tableView.tableColumns[columnIndex] : nil
        } else {
            tableView.highlightedTableColumn = nil
        }

        if let header = tableView.headerView as? SortableHeaderView {
            header.updateSortIndicators(state: sortState, schema: schema)
        }
    }

    private func reloadAndSyncSelection(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        needsFullReload: Bool
    ) {
        if needsFullReload {
            tableView.reloadData()
        }

        let currentSelection = tableView.selectedRowIndexes
        let targetSelection = IndexSet(selectedRowIndices)
        if currentSelection != targetSelection {
            coordinator.isSyncingSelection = true
            tableView.selectRowIndexes(targetSelection, byExtendingSelection: false)
            coordinator.isSyncingSelection = false
        }
    }

    // MARK: - Column Layout Helpers

    @MainActor
    static func makeRowNumberColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        column.title = "#"
        column.width = 40
        column.minWidth = 40
        column.maxWidth = 60
        column.isEditable = false
        column.resizingMask = []
        let defaultHeaderFont = column.headerCell.font
        let headerCell = SortableHeaderCell(textCell: "#")
        headerCell.font = defaultHeaderFont
        headerCell.alignment = .right
        headerCell.setAccessibilityLabel(String(localized: "Row number"))
        column.headerCell = headerCell
        return column
    }

    static let firstDataTableColumnIndex: Int = 1

    static func isDataTableColumn(_ tableColumnIndex: Int) -> Bool {
        tableColumnIndex >= firstDataTableColumnIndex
    }

    static func tableColumnIndex(
        for dataIndex: Int,
        in tableView: NSTableView,
        schema: ColumnIdentitySchema
    ) -> Int? {
        guard let identifier = schema.identifier(for: dataIndex) else { return nil }
        let index = tableView.column(withIdentifier: identifier)
        return index >= 0 ? index : nil
    }

    static func dataColumnIndex(
        for tableColumnIndex: Int,
        in tableView: NSTableView,
        schema: ColumnIdentitySchema
    ) -> Int? {
        guard tableColumnIndex >= 0, tableColumnIndex < tableView.tableColumns.count else { return nil }
        let identifier = tableView.tableColumns[tableColumnIndex].identifier
        return schema.dataIndex(from: identifier)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: TableViewCoordinator) {
        coordinator.overlayEditor?.dismiss(commit: false)
        coordinator.persistColumnLayoutToStorage()
        coordinator.settingsCancellable = nil
        coordinator.themeCancellable = nil
        coordinator.tableRowsController.detach()
    }

    func makeCoordinator() -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: changeManager,
            isEditable: isEditable,
            selectedRowIndices: $selectedRowIndices,
            delegate: delegate,
            layoutPersister: layoutPersister ?? FileColumnLayoutPersister()
        )
        let columnLayoutBinding = $columnLayout
        coordinator.onColumnLayoutDidChange = { layout in
            if columnLayoutBinding.wrappedValue != layout {
                columnLayoutBinding.wrappedValue = layout
            }
        }
        return coordinator
    }
}


// MARK: - Preview

private let previewTableRowsForDataGrid = TableRows.from(
    queryRows: [
        ["1", "John", "john@example.com"],
        ["2", "Jane", nil],
        ["3", "Bob", "bob@example.com"],
    ],
    columns: ["id", "name", "email"],
    columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: 3)
)

#Preview {
    DataGridView(
        tableRowsProvider: { previewTableRowsForDataGrid },
        changeManager: AnyChangeManager(DataChangeManager()),
        isEditable: true,
        selectedRowIndices: .constant([]),
        sortState: .constant(SortState()),
        columnLayout: .constant(ColumnLayoutState())
    )
    .frame(width: 600, height: 400)
}
