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

        let tableView = KeyHandlingTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .plain
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

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(TableViewCoordinator.handleClick(_:))
        tableView.doubleAction = #selector(TableViewCoordinator.handleDoubleClick(_:))

        let rowNumberColumn = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        rowNumberColumn.title = "#"
        rowNumberColumn.width = 40
        rowNumberColumn.minWidth = 40
        rowNumberColumn.maxWidth = 60
        rowNumberColumn.isEditable = false
        rowNumberColumn.resizingMask = []
        rowNumberColumn.headerCell.setAccessibilityLabel(String(localized: "Row number"))
        tableView.addTableColumn(rowNumberColumn)
        rowNumberColumn.isHidden = !configuration.showRowNumbers

        let initialRows = tableRowsProvider()
        context.coordinator.rebuildColumnMetadataCache(from: initialRows)
        let identitySchema = context.coordinator.identitySchema

        context.coordinator.isRebuildingColumns = true
        for (index, columnName) in initialRows.columns.enumerated() {
            guard let identifier = identitySchema.identifier(for: index) else { continue }
            let column = NSTableColumn(identifier: identifier)
            let suppressedCell = SuppressedSortIndicatorCell(textCell: columnName)
            suppressedCell.font = column.headerCell.font
            suppressedCell.alignment = column.headerCell.alignment
            column.headerCell = suppressedCell
            if index < initialRows.columnTypes.count {
                let typeName = initialRows.columnTypes[index].rawType ?? initialRows.columnTypes[index].displayName
                column.headerToolTip = "\(columnName) (\(typeName))"
            }
            column.headerCell.setAccessibilityLabel(
                String(format: String(localized: "Column: %@"), columnName)
            )
            column.width = context.coordinator.cellFactory.calculateOptimalColumnWidth(
                for: columnName,
                columnIndex: index,
                tableRows: initialRows
            )
            column.minWidth = 30
            column.resizingMask = .userResizingMask
            column.isEditable = isEditable
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: identifier.rawValue,
                ascending: true
            )
            tableView.addTableColumn(column)
        }

        let initialLayout = context.coordinator.savedColumnLayout(binding: columnLayout)
        applySavedLayout(
            to: tableView,
            coordinator: context.coordinator,
            columns: initialRows.columns,
            layout: initialLayout
        )
        context.coordinator.isRebuildingColumns = false

        applyColumnVisibility(to: tableView, coordinator: context.coordinator, columns: initialRows.columns)

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

        if let connectionId = configuration.connectionId, coordinator.teardownObserver == nil {
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

        coordinator.rebuildVisualStateCache()

        let currentDataColumns = tableView.tableColumns.dropFirst()
        let currentColumnIds = Set(currentDataColumns.map { $0.identifier.rawValue })
        let expectedColumnIds = Set(coordinator.identitySchema.identifiers.map { $0.rawValue })
        let columnsChanged = !latestRows.columns.isEmpty && (currentColumnIds != expectedColumnIds)

        let isInitialDataLoad = structureChanged && oldRowCount == 0 && !latestRows.columns.isEmpty
        let shouldRebuildColumns = columnsChanged || isInitialDataLoad

        updateColumns(
            tableView: tableView,
            coordinator: coordinator,
            tableRows: latestRows,
            columnsChanged: columnsChanged,
            shouldRebuild: shouldRebuildColumns,
            structureChanged: structureChanged
        )

        applyColumnVisibility(to: tableView, coordinator: coordinator, columns: latestRows.columns)

        syncSortDescriptors(tableView: tableView, coordinator: coordinator, columns: latestRows.columns)

        reloadAndSyncSelection(
            tableView: tableView,
            coordinator: coordinator,
            needsFullReload: needsFullReload
        )
    }

    // MARK: - updateNSView Helpers

    private func updateColumns(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        tableRows: TableRows,
        columnsChanged: Bool,
        shouldRebuild: Bool,
        structureChanged: Bool
    ) {
        if shouldRebuild {
            coordinator.isRebuildingColumns = true
            defer { coordinator.isRebuildingColumns = false }

            let savedLayout = coordinator.savedColumnLayout(binding: columnLayout)

            if columnsChanged {
                rebuildColumns(
                    tableView: tableView,
                    coordinator: coordinator,
                    tableRows: tableRows,
                    savedLayout: savedLayout
                )
            } else {
                refreshColumnTitles(
                    tableView: tableView,
                    coordinator: coordinator,
                    tableRows: tableRows,
                    hasSavedWidths: !(savedLayout?.columnWidths.isEmpty ?? true)
                )
            }

            applySavedLayout(to: tableView, coordinator: coordinator, columns: tableRows.columns, layout: savedLayout)

            if savedLayout == nil {
                coordinator.scheduleLayoutPersist()
            }
        } else {
            for column in tableView.tableColumns
            where column.identifier != ColumnIdentitySchema.rowNumberIdentifier {
                column.isEditable = isEditable
            }
        }
    }

    private func rebuildColumns(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        tableRows: TableRows,
        savedLayout: ColumnLayoutState?
    ) {
        let columnsToRemove = tableView.tableColumns.filter {
            $0.identifier != ColumnIdentitySchema.rowNumberIdentifier
        }
        for column in columnsToRemove {
            tableView.removeTableColumn(column)
        }

        let willRestoreWidths = !(savedLayout?.columnWidths.isEmpty ?? true)
        let schema = coordinator.identitySchema
        for (index, columnName) in tableRows.columns.enumerated() {
            guard let identifier = schema.identifier(for: index) else { continue }
            let column = NSTableColumn(identifier: identifier)
            let suppressedCell = SuppressedSortIndicatorCell(textCell: columnName)
            suppressedCell.font = column.headerCell.font
            suppressedCell.alignment = column.headerCell.alignment
            column.headerCell = suppressedCell
            if index < tableRows.columnTypes.count {
                let typeName = tableRows.columnTypes[index].rawType
                    ?? tableRows.columnTypes[index].displayName
                column.headerToolTip = "\(columnName) (\(typeName))"
            }
            column.headerCell.setAccessibilityLabel(
                String(format: String(localized: "Column: %@"), columnName)
            )
            if willRestoreWidths {
                column.width = savedLayout?.columnWidths[columnName] ?? 100
            } else {
                column.width = coordinator.cellFactory.calculateOptimalColumnWidth(
                    for: columnName,
                    columnIndex: index,
                    tableRows: tableRows
                )
            }
            column.minWidth = 30
            column.resizingMask = .userResizingMask
            column.isEditable = isEditable
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: identifier.rawValue,
                ascending: true
            )
            tableView.addTableColumn(column)
        }
    }

    private func refreshColumnTitles(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        tableRows: TableRows,
        hasSavedWidths: Bool
    ) {
        for column in tableView.tableColumns
        where column.identifier != ColumnIdentitySchema.rowNumberIdentifier {
            guard let colIndex = coordinator.dataColumnIndex(from: column.identifier),
                  colIndex < tableRows.columns.count else { continue }
            let columnName = tableRows.columns[colIndex]
            column.title = columnName
            if colIndex < tableRows.columnTypes.count {
                let typeName = tableRows.columnTypes[colIndex].rawType
                    ?? tableRows.columnTypes[colIndex].displayName
                column.headerToolTip = "\(columnName) (\(typeName))"
            }
            if !hasSavedWidths {
                column.width = coordinator.cellFactory.calculateOptimalColumnWidth(
                    for: columnName,
                    columnIndex: colIndex,
                    tableRows: tableRows
                )
            }
            column.isEditable = isEditable
        }
    }

    private func applySavedLayout(
        to tableView: NSTableView,
        coordinator: TableViewCoordinator,
        columns: [String],
        layout: ColumnLayoutState?
    ) {
        guard let layout else { return }

        for column in tableView.tableColumns
        where column.identifier != ColumnIdentitySchema.rowNumberIdentifier {
            guard let colIndex = coordinator.dataColumnIndex(from: column.identifier),
                  colIndex < columns.count else { continue }
            if let savedWidth = layout.columnWidths[columns[colIndex]] {
                column.width = savedWidth
            }
        }

        if let savedOrder = layout.columnOrder {
            DataGridView.applyColumnOrder(
                savedOrder,
                to: tableView,
                schema: coordinator.identitySchema,
                columns: columns
            )
        }
    }

    private func syncSortDescriptors(tableView: NSTableView, coordinator: TableViewCoordinator, columns: [String]) {
        coordinator.currentSortState = sortState

        let primaryIdentifier: NSUserInterfaceItemIdentifier?
        let primary: NSSortDescriptor?
        if let firstSort = sortState.columns.first,
           let identifier = coordinator.identitySchema.identifier(for: firstSort.columnIndex) {
            primaryIdentifier = identifier
            primary = NSSortDescriptor(key: identifier.rawValue, ascending: firstSort.direction == .ascending)
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
            header.updateSortIndicators(state: sortState, schema: coordinator.identitySchema)
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

    // MARK: - Column Visibility

    private func applyColumnVisibility(to tableView: NSTableView, coordinator: TableViewCoordinator, columns: [String]) {
        for column in tableView.tableColumns
        where column.identifier != ColumnIdentitySchema.rowNumberIdentifier {
            guard let colIndex = coordinator.dataColumnIndex(from: column.identifier),
                  colIndex < columns.count else { continue }
            let columnName = columns[colIndex]
            let shouldHide = configuration.hiddenColumns.contains(columnName)
            if column.isHidden != shouldHide {
                column.isHidden = shouldHide
            }
        }
    }

    // MARK: - Column Layout Helpers

    static func tableColumnIndex(for dataIndex: Int) -> Int {
        dataIndex + 1
    }

    static func dataColumnIndex(for tableColumnIndex: Int) -> Int {
        tableColumnIndex - 1
    }

    private static func applyColumnOrder(
        _ order: [String],
        to tableView: NSTableView,
        schema: ColumnIdentitySchema,
        columns: [String]
    ) {
        guard Set(order) == Set(columns) else { return }

        var columnByName: [String: NSTableColumn] = [:]
        for col in tableView.tableColumns
        where col.identifier != ColumnIdentitySchema.rowNumberIdentifier {
            if let idx = schema.dataIndex(from: col.identifier), idx < columns.count {
                columnByName[columns[idx]] = col
            }
        }

        for (targetDataIndex, columnName) in order.enumerated() {
            guard let desired = columnByName[columnName] else { continue }
            let targetTableIndex = tableColumnIndex(for: targetDataIndex)
            guard targetTableIndex < tableView.numberOfColumns else { continue }

            let current = tableView.tableColumns
            var currentIndex = -1
            for i in targetTableIndex..<current.count where current[i] === desired {
                currentIndex = i
                break
            }
            guard currentIndex >= 0, currentIndex != targetTableIndex else { continue }
            tableView.moveColumn(currentIndex, toColumn: targetTableIndex)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: TableViewCoordinator) {
        coordinator.overlayEditor?.dismiss(commit: false)
        coordinator.persistColumnLayoutToStorage()
        if let observer = coordinator.settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.settingsObserver = nil
        }
        if let observer = coordinator.themeObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.themeObserver = nil
        }
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
