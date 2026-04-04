//
//  DataGridView.swift
//  TablePro
//
//  High-performance NSTableView wrapper for SwiftUI.
//  Custom views extracted to separate files for maintainability.
//

import AppKit
import SwiftUI

/// Position of a cell in the grid (row, column)
struct CellPosition: Equatable {
    let row: Int
    let column: Int
}

/// Cached visual state for a row - avoids repeated changeManager lookups
struct RowVisualState {
    let isDeleted: Bool
    let isInserted: Bool
    let modifiedColumns: Set<Int>

    static let empty = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [])
}

/// Identity snapshot used to skip redundant updateNSView work when nothing has changed
struct DataGridIdentity: Equatable {
    let reloadVersion: Int
    let resultVersion: Int
    let metadataVersion: Int
    let paginationVersion: Int
    let rowCount: Int
    let columnCount: Int
    let isEditable: Bool
    let hiddenColumns: Set<String>
}

/// High-performance table view using AppKit NSTableView
struct DataGridView: NSViewRepresentable {
    let rowProvider: InMemoryRowProvider
    var changeManager: AnyChangeManager
    var resultVersion: Int = 0
    var metadataVersion: Int = 0
    var paginationVersion: Int = 0
    let isEditable: Bool
    var onRefresh: (() -> Void)?
    var onCellEdit: ((Int, Int, String?) -> Void)?
    var onDeleteRows: ((Set<Int>) -> Void)?
    var onCopyRows: ((Set<Int>) -> Void)?
    var onPasteRows: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSort: ((Int, Bool, Bool) -> Void)?
    var onAddRow: (() -> Void)?
    var onUndoInsert: ((Int) -> Void)?
    var onFilterColumn: ((String) -> Void)?
    var onNavigateFK: ((String, ForeignKeyInfo) -> Void)?
    var getVisualState: ((Int) -> RowVisualState)?
    var dropdownColumns: Set<Int>? // Column indices that should use YES/NO dropdowns
    var typePickerColumns: Set<Int>?
    var connectionId: UUID?
    var databaseType: DatabaseType?
    var tableName: String?
    var primaryKeyColumn: String?
    var tabType: TabType?
    var showRowNumbers: Bool = true
    var hiddenColumns: Set<String> = []
    var onHideColumn: ((String) -> Void)?
    var onShowAllColumns: (() -> Void)?
    var onMoveRow: ((Int, Int) -> Void)?
    var rowViewProvider: ((NSTableView, Int, TableViewCoordinator) -> NSTableRowView)?
    var emptySpaceMenu: (() -> NSMenu?)?

    @Binding var selectedRowIndices: Set<Int>
    @Binding var sortState: SortState
    @Binding var editingCell: CellPosition?
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
        // Use settings for alternate row backgrounds
        let settings = AppSettingsManager.shared.dataGrid
        tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        // Use settings for row height
        tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(TableViewCoordinator.handleClick(_:))
        tableView.doubleAction = #selector(TableViewCoordinator.handleDoubleClick(_:))

        // Add row number column
        let rowNumberColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rowNumber__"))
        rowNumberColumn.title = "#"
        rowNumberColumn.width = 40
        rowNumberColumn.minWidth = 40
        rowNumberColumn.maxWidth = 60
        rowNumberColumn.isEditable = false
        rowNumberColumn.resizingMask = []
        rowNumberColumn.headerCell.setAccessibilityLabel(String(localized: "Row number"))
        tableView.addTableColumn(rowNumberColumn)
        rowNumberColumn.isHidden = !showRowNumbers

        // Add data columns (suppress resize notifications during setup)
        context.coordinator.isRebuildingColumns = true
        for (index, columnName) in rowProvider.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
            column.title = columnName
            if index < rowProvider.columnTypes.count {
                let typeName = rowProvider.columnTypes[index].rawType ?? rowProvider.columnTypes[index].displayName
                column.headerToolTip = "\(columnName) (\(typeName))"
            }
            column.headerCell.setAccessibilityLabel(
                String(localized: "Column: \(columnName)")
            )
            column.width = context.coordinator.cellFactory.calculateOptimalColumnWidth(
                for: columnName,
                columnIndex: index,
                rowProvider: rowProvider
            )
            column.minWidth = 30
            column.resizingMask = .userResizingMask
            column.isEditable = isEditable
            column.sortDescriptorPrototype = NSSortDescriptor(key: "col_\(index)", ascending: true)
            tableView.addTableColumn(column)
        }

        // Apply saved column widths (from user resizing)
        if !columnLayout.columnWidths.isEmpty {
            for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                guard let colIndex = Self.columnIndex(from: column.identifier),
                      colIndex < rowProvider.columns.count else { continue }
                let baseName = rowProvider.columns[colIndex]
                if let savedWidth = columnLayout.columnWidths[baseName] {
                    column.width = savedWidth
                }
            }
            context.coordinator.hasUserResizedColumns = true
        }

        // Apply saved column order
        if let savedOrder = columnLayout.columnOrder {
            DataGridView.applyColumnOrder(savedOrder, to: tableView, columns: rowProvider.columns)
        }
        context.coordinator.isRebuildingColumns = false

        // Apply column visibility
        applyColumnVisibility(to: tableView)

        if let headerView = tableView.headerView {
            let headerMenu = NSMenu()
            headerMenu.delegate = context.coordinator
            headerView.menu = headerMenu
        }

        // Register for row drag-and-drop if onMoveRow is provided
        if onMoveRow != nil {
            tableView.registerForDraggedTypes([NSPasteboard.PasteboardType("com.TablePro.rowDrag")])
            tableView.draggingDestinationFeedbackStyle = .gap
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.onMoveRow = onMoveRow
        context.coordinator.rowViewProvider = rowViewProvider
        context.coordinator.emptySpaceMenu = emptySpaceMenu
        context.coordinator.onShowAllColumns = onShowAllColumns
        context.coordinator.rebuildColumnMetadataCache()
        if let connectionId {
            context.coordinator.observeTeardown(connectionId: connectionId)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator

        // Don't reload while editing (field editor or overlay)
        if tableView.editedRow >= 0 { return }
        if let editor = context.coordinator.overlayEditor, editor.isActive { return }

        // Sync row number visibility before identity check (setting can change without data change)
        if let rowNumCol = tableView.tableColumns.first(where: { $0.identifier.rawValue == "__rowNumber__" }) {
            let shouldHide = !showRowNumbers
            if rowNumCol.isHidden != shouldHide {
                rowNumCol.isHidden = shouldHide
            }
        }

        // Sync row drag registration when onMoveRow availability changes
        let rowDragType = NSPasteboard.PasteboardType("com.TablePro.rowDrag")
        let hasDragRegistered = tableView.registeredDraggedTypes.contains(rowDragType)
        if onMoveRow != nil && !hasDragRegistered {
            tableView.registerForDraggedTypes([rowDragType])
            tableView.draggingDestinationFeedbackStyle = .gap
        } else if onMoveRow == nil && hasDragRegistered {
            let remaining = tableView.registeredDraggedTypes.filter { $0 != rowDragType }
            tableView.unregisterDraggedTypes()
            if !remaining.isEmpty {
                tableView.registerForDraggedTypes(remaining)
            }
        }

        // Identity-based early-return BEFORE reading settings — avoids
        // AppSettingsManager access on every SwiftUI re-evaluation.
        let currentIdentity = DataGridIdentity(
            reloadVersion: changeManager.reloadVersion,
            resultVersion: resultVersion,
            metadataVersion: metadataVersion,
            paginationVersion: paginationVersion,
            rowCount: rowProvider.totalRowCount,
            columnCount: rowProvider.columns.count,
            isEditable: isEditable,
            hiddenColumns: hiddenColumns
        )
        if currentIdentity == coordinator.lastIdentity {
            // Only refresh closure callbacks — they capture new state on each body eval
            coordinator.onCellEdit = onCellEdit
            coordinator.onSort = onSort
            coordinator.onAddRow = onAddRow
            coordinator.onUndoInsert = onUndoInsert
            coordinator.onFilterColumn = onFilterColumn
            coordinator.onHideColumn = onHideColumn
            coordinator.onShowAllColumns = onShowAllColumns
            coordinator.onMoveRow = onMoveRow
            coordinator.onRefresh = onRefresh
            coordinator.onDeleteRows = onDeleteRows
            coordinator.getVisualState = getVisualState
            coordinator.onNavigateFK = onNavigateFK
            coordinator.rowViewProvider = rowViewProvider
            coordinator.emptySpaceMenu = emptySpaceMenu
            return
        }
        let previousIdentity = coordinator.lastIdentity
        coordinator.lastIdentity = currentIdentity

        // Update settings-based properties dynamically (after identity check)
        let settings = AppSettingsManager.shared.dataGrid
        if tableView.rowHeight != CGFloat(settings.rowHeight.rawValue) {
            tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)
        }
        if tableView.usesAlternatingRowBackgroundColors != settings.showAlternateRows {
            tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows
        }

        let versionChanged = coordinator.lastReloadVersion != changeManager.reloadVersion
        let metadataChanged = previousIdentity.map { $0.metadataVersion != metadataVersion } ?? false
        let oldRowCount = coordinator.cachedRowCount
        let oldColumnCount = coordinator.cachedColumnCount
        let newRowCount = rowProvider.totalRowCount
        let newColumnCount = rowProvider.columns.count

        // Only do full reload if row/column count changed or columns changed
        // For cell edits (versionChanged but same count), use granular reload
        let structureChanged = oldRowCount != newRowCount || oldColumnCount != newColumnCount
        let needsFullReload = structureChanged

        coordinator.rowProvider = rowProvider

        // Re-apply pending cell edits only when changes have been modified
        if changeManager.reloadVersion != coordinator.lastReapplyVersion {
            coordinator.lastReapplyVersion = changeManager.reloadVersion
            for change in changeManager.changes {
                guard let rowChange = change as? RowChange else { continue }
                for cellChange in rowChange.cellChanges {
                    coordinator.rowProvider.updateValue(
                        cellChange.newValue,
                        at: rowChange.rowIndex,
                        columnIndex: cellChange.columnIndex
                    )
                }
            }
        }

        coordinator.updateCache()
        coordinator.rebuildColumnMetadataCache()

        if previousIdentity == nil || previousIdentity?.rowCount == 0 {
            let rowH = tableView.rowHeight
            if rowH > 0 {
                let visibleRows = Int(tableView.visibleRect.height / rowH) + 5
                coordinator.rowProvider.preWarmDisplayCache(upTo: visibleRows)
            }
        }

        coordinator.changeManager = changeManager
        coordinator.isEditable = isEditable
        coordinator.onRefresh = onRefresh
        coordinator.onCellEdit = onCellEdit
        coordinator.onDeleteRows = onDeleteRows
        coordinator.onSort = onSort
        coordinator.onAddRow = onAddRow
        coordinator.onUndoInsert = onUndoInsert
        coordinator.onFilterColumn = onFilterColumn
        coordinator.onHideColumn = onHideColumn
        coordinator.onShowAllColumns = onShowAllColumns
        coordinator.onMoveRow = onMoveRow
        coordinator.getVisualState = getVisualState
        coordinator.onNavigateFK = onNavigateFK
        coordinator.rowViewProvider = rowViewProvider
        coordinator.emptySpaceMenu = emptySpaceMenu
        coordinator.dropdownColumns = dropdownColumns
        coordinator.typePickerColumns = typePickerColumns
        coordinator.connectionId = connectionId
        coordinator.databaseType = databaseType
        coordinator.tableName = tableName
        coordinator.primaryKeyColumn = primaryKeyColumn
        coordinator.tabType = tabType

        coordinator.rebuildVisualStateCache()

        // Capture current column layout before any rebuilds (only if not about to rebuild)
        // Check if columns changed (by name or structure)
        let currentDataColumns = tableView.tableColumns.dropFirst()
        let currentColumnIds = currentDataColumns.map { $0.identifier.rawValue }
        let expectedColumnIds = rowProvider.columns.indices.map { "col_\($0)" }
        let columnsChanged = !rowProvider.columns.isEmpty && (currentColumnIds != expectedColumnIds)

        // Only recalculate column widths when transitioning from 0 rows (initial data load).
        // When row count changes but columns are the same and already have widths, skip
        // the expensive calculateOptimalColumnWidth calls.
        let isInitialDataLoad = structureChanged && oldRowCount == 0 && !rowProvider.columns.isEmpty
        let shouldRebuildColumns = columnsChanged || isInitialDataLoad

        updateColumns(
            tableView: tableView,
            coordinator: coordinator,
            columnsChanged: columnsChanged,
            shouldRebuild: shouldRebuildColumns,
            structureChanged: structureChanged
        )

        // Sync column visibility
        applyColumnVisibility(to: tableView)

        syncSortDescriptors(tableView: tableView, coordinator: coordinator)

        let paginationChanged = previousIdentity.map { $0.paginationVersion != paginationVersion } ?? false

        reloadAndSyncSelection(
            tableView: tableView,
            coordinator: coordinator,
            needsFullReload: needsFullReload,
            versionChanged: versionChanged,
            metadataChanged: metadataChanged,
            paginationChanged: paginationChanged
        )
    }

    // MARK: - updateNSView Helpers

    /// Rebuild or sync table columns based on data changes
    private func updateColumns(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        columnsChanged: Bool,
        shouldRebuild: Bool,
        structureChanged: Bool
    ) {
        if shouldRebuild {
            coordinator.isRebuildingColumns = true
            defer { coordinator.isRebuildingColumns = false }

            if columnsChanged {
                // Column count changed — full rebuild (remove all, create all)
                let columnsToRemove = tableView.tableColumns.filter { $0.identifier.rawValue != "__rowNumber__" }
                for column in columnsToRemove {
                    tableView.removeTableColumn(column)
                }

                let willRestoreWidths = !columnLayout.columnWidths.isEmpty
                for (index, columnName) in rowProvider.columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
                    column.title = columnName
                    if index < rowProvider.columnTypes.count {
                        let typeName = rowProvider.columnTypes[index].rawType
                            ?? rowProvider.columnTypes[index].displayName
                        column.headerToolTip = "\(columnName) (\(typeName))"
                    }
                    column.headerCell.setAccessibilityLabel(
                        String(localized: "Column: \(columnName)")
                    )
                    if willRestoreWidths {
                        column.width = columnLayout.columnWidths[columnName] ?? 100
                    } else {
                        column.width = coordinator.cellFactory.calculateOptimalColumnWidth(
                            for: columnName,
                            columnIndex: index,
                            rowProvider: rowProvider
                        )
                    }
                    column.minWidth = 30
                    column.resizingMask = .userResizingMask
                    column.isEditable = isEditable
                    column.sortDescriptorPrototype = NSSortDescriptor(key: "col_\(index)", ascending: true)
                    tableView.addTableColumn(column)
                }
            } else {
                // Same column count — lightweight in-place update (avoids remove/add overhead)
                let hasSavedWidths = !columnLayout.columnWidths.isEmpty
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.columnIndex(from: column.identifier),
                          colIndex < rowProvider.columns.count else { continue }
                    let columnName = rowProvider.columns[colIndex]
                    column.title = columnName
                    if colIndex < rowProvider.columnTypes.count {
                        let typeName = rowProvider.columnTypes[colIndex].rawType
                            ?? rowProvider.columnTypes[colIndex].displayName
                        column.headerToolTip = "\(columnName) (\(typeName))"
                    }
                    if !hasSavedWidths {
                        column.width = coordinator.cellFactory.calculateOptimalColumnWidth(
                            for: columnName,
                            columnIndex: colIndex,
                            rowProvider: rowProvider
                        )
                    }
                    column.isEditable = isEditable
                }
            }
            let hasSavedLayout = !columnLayout.columnWidths.isEmpty

            // Restore saved column widths after rebuild (from user resize or persisted layout)
            if hasSavedLayout {
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.columnIndex(from: column.identifier),
                          colIndex < rowProvider.columns.count else { continue }
                    let baseName = rowProvider.columns[colIndex]
                    if let savedWidth = columnLayout.columnWidths[baseName] {
                        column.width = savedWidth
                    }
                }
                coordinator.hasUserResizedColumns = true
            }

            // Restore saved column order after rebuild
            if let savedOrder = columnLayout.columnOrder {
                DataGridView.applyColumnOrder(savedOrder, to: tableView, columns: rowProvider.columns)
                coordinator.hasUserResizedColumns = true
            }

            // Persist calculated widths so subsequent tab switches reuse them
            // instead of calling the expensive calculateOptimalColumnWidth.
            // Skip when saved layout exists to avoid overwriting persisted values.
            if !coordinator.hasUserResizedColumns, !hasSavedLayout {
                var newWidths: [String: CGFloat] = [:]
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.columnIndex(from: column.identifier),
                          colIndex < rowProvider.columns.count else { continue }
                    newWidths[rowProvider.columns[colIndex]] = column.width
                }
                if !newWidths.isEmpty && newWidths != columnLayout.columnWidths {
                    coordinator.isWritingColumnLayout = true
                    DispatchQueue.main.async {
                        coordinator.isWritingColumnLayout = false
                        self.columnLayout.columnWidths = newWidths
                    }
                }
            }
        } else {
            // Always sync column editability (e.g., view tabs reusing table columns)
            for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                column.isEditable = isEditable
            }

            // Skip layout capture when an async layout write-back is pending —
            // prevents the two-frame bounce where stale widths are applied
            // before the async block updates them.
            guard !coordinator.isWritingColumnLayout else { return }

            // Capture current column layout from user interactions (resize/reorder)
            // Only done in the non-rebuild path to avoid feedback loops
            if coordinator.hasUserResizedColumns, tableView.tableColumns.count > 1 {
                var currentWidths: [String: CGFloat] = [:]
                var currentOrder: [String] = []
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.columnIndex(from: column.identifier),
                          colIndex < rowProvider.columns.count else { continue }
                    let baseName = rowProvider.columns[colIndex]
                    currentWidths[baseName] = column.width
                    currentOrder.append(baseName)
                }
                let widthsChanged = !currentWidths.isEmpty && currentWidths != columnLayout.columnWidths
                let orderChanged = !currentOrder.isEmpty && columnLayout.columnOrder != currentOrder
                if widthsChanged || orderChanged {
                    coordinator.isWritingColumnLayout = true
                    DispatchQueue.main.async {
                        coordinator.isWritingColumnLayout = false
                        if widthsChanged {
                            self.columnLayout.columnWidths = currentWidths
                        }
                        if orderChanged {
                            self.columnLayout.columnOrder = currentOrder
                        }
                    }
                }
                coordinator.hasUserResizedColumns = false
            }
        }
    }

    /// Synchronize sort descriptors and indicators with the table view
    private func syncSortDescriptors(tableView: NSTableView, coordinator: TableViewCoordinator) {
        coordinator.isSyncingSortDescriptors = true
        defer { coordinator.isSyncingSortDescriptors = false }

        if !sortState.isSorting {
            if !tableView.sortDescriptors.isEmpty {
                tableView.sortDescriptors = []
            }
        } else if let firstSort = sortState.columns.first,
                  firstSort.columnIndex >= 0 && firstSort.columnIndex < rowProvider.columns.count {
            // Sync with first sort column for NSTableView's built-in sort indicators
            let key = "col_\(firstSort.columnIndex)"
            let ascending = firstSort.direction == .ascending
            let currentDescriptor = tableView.sortDescriptors.first
            if currentDescriptor?.key != key || currentDescriptor?.ascending != ascending {
                tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            }
        }

        // Update column header titles for multi-sort indicators
        Self.updateSortIndicators(tableView: tableView, sortState: sortState, columns: rowProvider.columns)
    }

    /// Reload table data as needed and synchronize selection and editing state
    private func reloadAndSyncSelection(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        needsFullReload: Bool,
        versionChanged: Bool,
        metadataChanged: Bool = false,
        paginationChanged: Bool = false
    ) {
        if needsFullReload {
            tableView.reloadData()
        } else if metadataChanged {
            // FK metadata arrived (Phase 2) — reload only FK columns to show arrow buttons.
            // Use display-order indices from tableView.tableColumns (respects user column reordering).
            let fkColumnIndices = IndexSet(
                tableView.tableColumns.enumerated().compactMap { displayIndex, tableColumn in
                    guard tableColumn.identifier.rawValue != "__rowNumber__",
                          let modelIndex = Self.columnIndex(from: tableColumn.identifier),
                          modelIndex < rowProvider.columns.count else { return nil }
                    let columnName = rowProvider.columns[modelIndex]
                    return rowProvider.columnForeignKeys[columnName] != nil ? displayIndex : nil
                }
            )
            if !fkColumnIndices.isEmpty {
                let visibleRange = tableView.rows(in: tableView.visibleRect)
                if visibleRange.length > 0 {
                    let visibleRows = IndexSet(
                        integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)
                    )
                    tableView.reloadData(forRowIndexes: visibleRows, columnIndexes: fkColumnIndices)
                }
            }
        } else if versionChanged {
            // Granular reload: only reload rows that changed
            let changedRows = changeManager.consumeChangedRowIndices()
            if changedRows.count > 500 {
                // Too many changed rows — full reload is faster than granular
                tableView.reloadData()
            } else if !changedRows.isEmpty {
                // Some rows changed → granular reload for performance
                let rowIndexSet = IndexSet(changedRows)
                let columnIndexSet = IndexSet(integersIn: 0..<tableView.numberOfColumns)
                tableView.reloadData(forRowIndexes: rowIndexSet, columnIndexes: columnIndexSet)
            } else {
                // Version changed but no specific rows tracked → full reload
                // Covers: undo/redo operations, cleared changes (refresh), etc.
                tableView.reloadData()
            }
        }

        coordinator.lastReloadVersion = changeManager.reloadVersion

        // Scroll to first row when page changes
        if paginationChanged && tableView.numberOfRows > 0 {
            tableView.scrollRowToVisible(0)
        }

        // Sync selection
        let currentSelection = tableView.selectedRowIndexes
        let targetSelection = IndexSet(selectedRowIndices)
        if currentSelection != targetSelection {
            coordinator.isSyncingSelection = true
            tableView.selectRowIndexes(targetSelection, byExtendingSelection: false)
            coordinator.isSyncingSelection = false
        }

        // Handle editingCell
        if let cell = editingCell {
            let tableColumn = cell.column + 1
            if cell.row < tableView.numberOfRows && tableColumn < tableView.numberOfColumns {
                tableView.scrollRowToVisible(cell.row)
                DispatchQueue.main.async { [weak tableView] in
                    guard let tableView = tableView else { return }
                    tableView.selectRowIndexes(IndexSet(integer: cell.row), byExtendingSelection: false)
                    tableView.editColumn(tableColumn, row: cell.row, with: nil, select: true)
                }
            }
            DispatchQueue.main.async {
                self.editingCell = nil
            }
        }
    }

    // MARK: - Column Visibility

    /// Apply hidden column state to the table view
    private func applyColumnVisibility(to tableView: NSTableView) {
        for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
            guard let colIndex = Self.columnIndex(from: column.identifier),
                  colIndex < rowProvider.columns.count else { continue }
            let columnName = rowProvider.columns[colIndex]
            let shouldHide = hiddenColumns.contains(columnName)
            if column.isHidden != shouldHide {
                column.isHidden = shouldHide
            }
        }
    }

    // MARK: - Column Layout Helpers

    /// Extract column index from a stable identifier like "col_3"
    static func columnIndex(from identifier: NSUserInterfaceItemIdentifier) -> Int? {
        let raw = identifier.rawValue
        guard raw.hasPrefix("col_") else { return nil }
        return Int(raw.dropFirst(4))
    }

    private static func applyColumnOrder(_ order: [String], to tableView: NSTableView, columns: [String]) {
        // Only apply if saved order is a permutation of current columns
        guard Set(order) == Set(columns) else { return }

        let dataColumns = tableView.tableColumns.filter { $0.identifier.rawValue != "__rowNumber__" }

        // Build name→column map for O(1) lookup
        var columnMap: [String: NSTableColumn] = [:]
        for col in dataColumns {
            if let idx = columnIndex(from: col.identifier), idx < columns.count {
                columnMap[columns[idx]] = col
            }
        }

        for (targetIndex, columnName) in order.enumerated() {
            guard let sourceColumn = columnMap[columnName],
                  let currentIndex = tableView.tableColumns.firstIndex(of: sourceColumn) else { continue }
            let targetTableIndex = targetIndex + 1  // +1 for row number column
            if currentIndex != targetTableIndex && targetTableIndex < tableView.numberOfColumns {
                tableView.moveColumn(currentIndex, toColumn: targetTableIndex)
            }
        }
    }

    // MARK: - Sort Indicator Helpers

    /// Update column header titles to show multi-sort priority indicators (e.g., "name 1▲", "age 2▼")
    private static func updateSortIndicators(tableView: NSTableView, sortState: SortState, columns: [String]) {
        for column in tableView.tableColumns where column.identifier.rawValue.hasPrefix("col_") {
            let idString = column.identifier.rawValue
            guard let colIndex = Int(idString.dropFirst(4)),
                  colIndex < columns.count else { continue }

            let baseName = columns[colIndex]

            if let sortIndex = sortState.columns.firstIndex(where: { $0.columnIndex == colIndex }) {
                let sortCol = sortState.columns[sortIndex]
                if sortState.columns.count > 1 {
                    let indicator = " \(sortIndex + 1)\(sortCol.direction.indicator)"
                    column.title = "\(baseName)\(indicator)"
                } else {
                    // Single sort: NSTableView shows its own indicator, keep base name
                    column.title = baseName
                }
            } else {
                // Not sorted: restore base name
                column.title = baseName
            }
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
        coordinator.rowProvider = InMemoryRowProvider(rows: [], columns: [])
    }

    func makeCoordinator() -> TableViewCoordinator {
        TableViewCoordinator(
            rowProvider: rowProvider,
            changeManager: changeManager,
            isEditable: isEditable,
            selectedRowIndices: $selectedRowIndices,
            onRefresh: onRefresh,
            onCellEdit: onCellEdit,
            onDeleteRows: onDeleteRows,
            onCopyRows: onCopyRows,
            onPasteRows: onPasteRows,
            onUndo: onUndo,
            onRedo: onRedo
        )
    }
}


// MARK: - Preview

#Preview {
    DataGridView(
        rowProvider: InMemoryRowProvider(
            rows: [
                ["1", "John", "john@example.com"],
                ["2", "Jane", nil],
                ["3", "Bob", "bob@example.com"],
            ],
            columns: ["id", "name", "email"]
        ),
        changeManager: AnyChangeManager(dataManager: DataChangeManager()),
        isEditable: true,
        selectedRowIndices: .constant([]),
        sortState: .constant(SortState()),
        editingCell: .constant(nil as CellPosition?),
        columnLayout: .constant(ColumnLayoutState())
    )
    .frame(width: 600, height: 400)
}
