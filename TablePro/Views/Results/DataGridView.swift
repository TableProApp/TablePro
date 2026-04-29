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

struct DataGridIdentity: Equatable {
    let schemaVersion: Int
    let metadataVersion: Int
    let paginationVersion: Int
    let rowCount: Int
    let columnCount: Int
    let isEditable: Bool
    let tabType: TabType?
    let tableName: String?
    let primaryKeyColumns: [String]
    let hiddenColumns: Set<String>

    init(schemaVersion: Int, metadataVersion: Int, paginationVersion: Int,
         rowCount: Int, columnCount: Int, isEditable: Bool, configuration: DataGridConfiguration) {
        self.schemaVersion = schemaVersion
        self.metadataVersion = metadataVersion
        self.paginationVersion = paginationVersion
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.isEditable = isEditable
        self.tabType = configuration.tabType
        self.tableName = configuration.tableName
        self.primaryKeyColumns = configuration.primaryKeyColumns
        self.hiddenColumns = configuration.hiddenColumns
    }
}

struct DataGridView: NSViewRepresentable {
    var tableRowsProvider: @MainActor () -> TableRows = { TableRows() }
    var tableRowsMutator: @MainActor (@MainActor (inout TableRows) -> Void) -> Void = { _ in }
    var changeManager: AnyChangeManager
    var schemaVersion: Int = 0
    var metadataVersion: Int = 0
    var paginationVersion: Int = 0
    let isEditable: Bool
    var configuration: DataGridConfiguration = .init()
    var sortedIDs: [RowID]?
    var displayFormats: [ValueDisplayFormat?] = []
    var delegate: (any DataGridViewDelegate)?

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

        let rowNumberColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rowNumber__"))
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

        context.coordinator.isRebuildingColumns = true
        for (index, columnName) in initialRows.columns.enumerated() {
            let column = NSTableColumn(identifier: Self.columnIdentifier(for: index))
            column.title = columnName
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
                key: Self.columnIdentifier(for: index).rawValue,
                ascending: true
            )
            tableView.addTableColumn(column)
        }

        if !columnLayout.columnWidths.isEmpty {
            for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                guard let colIndex = Self.dataColumnIndex(from: column.identifier),
                      colIndex < initialRows.columns.count else { continue }
                let baseName = initialRows.columns[colIndex]
                if let savedWidth = columnLayout.columnWidths[baseName] {
                    column.width = savedWidth
                }
            }
            context.coordinator.hasUserResizedColumns = true
        }

        if let savedOrder = columnLayout.columnOrder {
            DataGridView.applyColumnOrder(savedOrder, to: tableView, columns: initialRows.columns)
        }
        context.coordinator.isRebuildingColumns = false

        applyColumnVisibility(to: tableView, columns: initialRows.columns)

        if let headerView = tableView.headerView {
            let headerMenu = NSMenu()
            headerMenu.delegate = context.coordinator
            headerView.menu = headerMenu
        }

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
        context.coordinator.rebuildColumnMetadataCache(from: tableRowsProvider())
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

        if let rowNumCol = tableView.tableColumns.first(where: { $0.identifier.rawValue == "__rowNumber__" }) {
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

        let currentIdentity = DataGridIdentity(
            schemaVersion: schemaVersion,
            metadataVersion: metadataVersion,
            paginationVersion: paginationVersion,
            rowCount: rowDisplayCount,
            columnCount: columnCount,
            isEditable: isEditable,
            configuration: configuration
        )
        if currentIdentity == coordinator.lastIdentity {
            coordinator.delegate = delegate
            coordinator.tableRowsProvider = tableRowsProvider
            coordinator.tableRowsMutator = tableRowsMutator
            coordinator.sortedIDs = sortedIDs
            coordinator.syncDisplayFormats(displayFormats)
            delegate?.dataGridAttach(tableViewCoordinator: coordinator)
            return
        }
        let previousIdentity = coordinator.lastIdentity
        coordinator.lastIdentity = currentIdentity

        let settings = AppSettingsManager.shared.dataGrid
        if tableView.rowHeight != CGFloat(settings.rowHeight.rawValue) {
            tableView.rowHeight = CGFloat(settings.rowHeight.rawValue)
        }
        if tableView.usesAlternatingRowBackgroundColors != settings.showAlternateRows {
            tableView.usesAlternatingRowBackgroundColors = settings.showAlternateRows
        }

        let metadataChanged = previousIdentity.map { $0.metadataVersion != metadataVersion } ?? false
        let oldRowCount = coordinator.cachedRowCount
        let oldColumnCount = coordinator.cachedColumnCount

        let structureChanged = oldRowCount != rowDisplayCount || oldColumnCount != columnCount
        let needsFullReload = structureChanged

        coordinator.updateCache()
        coordinator.rebuildColumnMetadataCache(from: latestRows)

        if previousIdentity == nil || previousIdentity?.rowCount == 0 {
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
        let currentColumnIds = currentDataColumns.map { $0.identifier.rawValue }
        let expectedColumnIds = latestRows.columns.indices.map { Self.columnIdentifier(for: $0).rawValue }
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

        applyColumnVisibility(to: tableView, columns: latestRows.columns)

        syncSortDescriptors(tableView: tableView, coordinator: coordinator, columns: latestRows.columns)

        let paginationChanged = previousIdentity.map { $0.paginationVersion != paginationVersion } ?? false

        reloadAndSyncSelection(
            tableView: tableView,
            coordinator: coordinator,
            tableRows: latestRows,
            needsFullReload: needsFullReload,
            metadataChanged: metadataChanged,
            paginationChanged: paginationChanged
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

            if columnsChanged {
                let columnsToRemove = tableView.tableColumns.filter { $0.identifier.rawValue != "__rowNumber__" }
                for column in columnsToRemove {
                    tableView.removeTableColumn(column)
                }

                let willRestoreWidths = !columnLayout.columnWidths.isEmpty
                for (index, columnName) in tableRows.columns.enumerated() {
                    let column = NSTableColumn(identifier: Self.columnIdentifier(for: index))
                    column.title = columnName
                    if index < tableRows.columnTypes.count {
                        let typeName = tableRows.columnTypes[index].rawType
                            ?? tableRows.columnTypes[index].displayName
                        column.headerToolTip = "\(columnName) (\(typeName))"
                    }
                    column.headerCell.setAccessibilityLabel(
                        String(format: String(localized: "Column: %@"), columnName)
                    )
                    if willRestoreWidths {
                        column.width = columnLayout.columnWidths[columnName] ?? 100
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
                        key: Self.columnIdentifier(for: index).rawValue,
                        ascending: true
                    )
                    tableView.addTableColumn(column)
                }
            } else {
                let hasSavedWidths = !columnLayout.columnWidths.isEmpty
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.dataColumnIndex(from: column.identifier),
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
            let hasSavedLayout = !columnLayout.columnWidths.isEmpty

            if hasSavedLayout {
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.dataColumnIndex(from: column.identifier),
                          colIndex < tableRows.columns.count else { continue }
                    let baseName = tableRows.columns[colIndex]
                    if let savedWidth = columnLayout.columnWidths[baseName] {
                        column.width = savedWidth
                    }
                }
                coordinator.hasUserResizedColumns = true
            }

            if let savedOrder = columnLayout.columnOrder {
                DataGridView.applyColumnOrder(savedOrder, to: tableView, columns: tableRows.columns)
                coordinator.hasUserResizedColumns = true
            }

            if !coordinator.hasUserResizedColumns, !hasSavedLayout {
                var newWidths: [String: CGFloat] = [:]
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.dataColumnIndex(from: column.identifier),
                          colIndex < tableRows.columns.count else { continue }
                    newWidths[tableRows.columns[colIndex]] = column.width
                }
                if !newWidths.isEmpty && newWidths != columnLayout.columnWidths {
                    coordinator.isWritingColumnLayout = true
                    Task { @MainActor in
                        coordinator.isWritingColumnLayout = false
                        self.columnLayout.columnWidths = newWidths
                    }
                }
            }
        } else {
            for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                column.isEditable = isEditable
            }

            guard !coordinator.isWritingColumnLayout else { return }

            if coordinator.hasUserResizedColumns, tableView.tableColumns.count > 1 {
                var currentWidths: [String: CGFloat] = [:]
                var currentOrder: [String] = []
                for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
                    guard let colIndex = Self.dataColumnIndex(from: column.identifier),
                          colIndex < tableRows.columns.count else { continue }
                    let baseName = tableRows.columns[colIndex]
                    currentWidths[baseName] = column.width
                    currentOrder.append(baseName)
                }
                let widthsChanged = !currentWidths.isEmpty && currentWidths != columnLayout.columnWidths
                let orderChanged = !currentOrder.isEmpty && columnLayout.columnOrder != currentOrder
                if widthsChanged || orderChanged {
                    coordinator.isWritingColumnLayout = true
                    Task { @MainActor in
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

    private func syncSortDescriptors(tableView: NSTableView, coordinator: TableViewCoordinator, columns: [String]) {
        coordinator.isSyncingSortDescriptors = true
        defer { coordinator.isSyncingSortDescriptors = false }

        if !sortState.isSorting {
            if !tableView.sortDescriptors.isEmpty {
                tableView.sortDescriptors = []
            }
        } else if let firstSort = sortState.columns.first,
                  firstSort.columnIndex >= 0 && firstSort.columnIndex < columns.count {
            let key = Self.columnIdentifier(for: firstSort.columnIndex).rawValue
            let ascending = firstSort.direction == .ascending
            let currentDescriptor = tableView.sortDescriptors.first
            if currentDescriptor?.key != key || currentDescriptor?.ascending != ascending {
                tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            }
        }

        Self.updateSortIndicators(tableView: tableView, sortState: sortState, columns: columns)
    }

    private func reloadAndSyncSelection(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        tableRows: TableRows,
        needsFullReload: Bool,
        metadataChanged: Bool = false,
        paginationChanged: Bool = false
    ) {
        if needsFullReload {
            tableView.reloadData()
        } else if metadataChanged {
            let fkColumnIndices = IndexSet(
                tableView.tableColumns.enumerated().compactMap { displayIndex, tableColumn in
                    guard tableColumn.identifier.rawValue != "__rowNumber__",
                          let modelIndex = Self.dataColumnIndex(from: tableColumn.identifier),
                          modelIndex < tableRows.columns.count else { return nil }
                    let columnName = tableRows.columns[modelIndex]
                    return tableRows.columnForeignKeys[columnName] != nil ? displayIndex : nil
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
        }

        if paginationChanged && tableView.numberOfRows > 0 {
            tableView.scrollRowToVisible(0)
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

    private func applyColumnVisibility(to tableView: NSTableView, columns: [String]) {
        for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
            guard let colIndex = Self.dataColumnIndex(from: column.identifier),
                  colIndex < columns.count else { continue }
            let columnName = columns[colIndex]
            let shouldHide = configuration.hiddenColumns.contains(columnName)
            if column.isHidden != shouldHide {
                column.isHidden = shouldHide
            }
        }
    }

    // MARK: - Column Layout Helpers

    static func columnIdentifier(for dataIndex: Int) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("col_\(dataIndex)")
    }

    static func tableColumnIndex(for dataIndex: Int) -> Int {
        dataIndex + 1
    }

    static func dataColumnIndex(for tableColumnIndex: Int) -> Int {
        tableColumnIndex - 1
    }

    static func dataColumnIndex(from identifier: NSUserInterfaceItemIdentifier) -> Int? {
        let raw = identifier.rawValue
        guard raw.hasPrefix("col_") else { return nil }
        return Int(raw.dropFirst(4))
    }

    private static func applyColumnOrder(_ order: [String], to tableView: NSTableView, columns: [String]) {
        guard Set(order) == Set(columns) else { return }

        let dataColumns = tableView.tableColumns.filter { $0.identifier.rawValue != "__rowNumber__" }

        var columnMap: [String: NSTableColumn] = [:]
        for col in dataColumns {
            if let idx = dataColumnIndex(from: col.identifier), idx < columns.count {
                columnMap[columns[idx]] = col
            }
        }

        for (targetIndex, columnName) in order.enumerated() {
            guard let sourceColumn = columnMap[columnName],
                  let currentIndex = tableView.tableColumns.firstIndex(of: sourceColumn) else { continue }
            let targetTableIndex = tableColumnIndex(for: targetIndex)
            if currentIndex != targetTableIndex && targetTableIndex < tableView.numberOfColumns {
                tableView.moveColumn(currentIndex, toColumn: targetTableIndex)
            }
        }
    }

    // MARK: - Sort Indicator Helpers

    private static func updateSortIndicators(tableView: NSTableView, sortState: SortState, columns: [String]) {
        for column in tableView.tableColumns {
            guard let colIndex = dataColumnIndex(from: column.identifier),
                  colIndex < columns.count else { continue }

            let baseName = columns[colIndex]

            if let sortIndex = sortState.columns.firstIndex(where: { $0.columnIndex == colIndex }) {
                let sortCol = sortState.columns[sortIndex]
                if sortState.columns.count > 1 {
                    let indicator = " \(sortIndex + 1)\(sortCol.direction.indicator)"
                    column.title = "\(baseName)\(indicator)"
                } else {
                    column.title = baseName
                }
            } else {
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
        coordinator.tableRowsController.detach()
    }

    func makeCoordinator() -> TableViewCoordinator {
        TableViewCoordinator(
            changeManager: changeManager,
            isEditable: isEditable,
            selectedRowIndices: $selectedRowIndices,
            delegate: delegate
        )
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
