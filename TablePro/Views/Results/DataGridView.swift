//
//  DataGridView.swift
//  TablePro
//
//  High-performance NSTableView wrapper for SwiftUI.
//  Custom views extracted to separate files for maintainability.
//

import AppKit
import SwiftUI
import TableProPluginKit

struct CellPosition: Hashable {
    let row: Int
    let column: Int
}

struct RowVisualState: Equatable {
    let isDeleted: Bool
    let isInserted: Bool
    let modifiedColumns: Set<Int>

    func isModified(columnIndex: Int) -> Bool {
        modifiedColumns.contains(columnIndex)
    }

    static let empty = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [])
}

struct DataGridView: NSViewRepresentable {
    var tableRowsProvider: @MainActor () -> TableRows = { TableRows() }
    var tableRowsMutator: @MainActor (@MainActor (inout TableRows) -> Void) -> Void = { _ in }
    var paginationOffsetProvider: @MainActor () -> Int = { 0 }
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
    var contentRevision: Int = 0

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
        tableView.setAccessibilityIdentifier("data-grid")
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

        let rowNumberColumn = Self.makeRowNumberColumn()
        tableView.addTableColumn(rowNumberColumn)
        rowNumberColumn.isHidden = !configuration.showRowNumbers

        let sortableHeader = SortableHeaderView(frame: tableView.headerView?.frame ?? .zero)
        sortableHeader.coordinator = context.coordinator
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        sortableHeader.menu = headerMenu
        tableView.headerView = sortableHeader

        scrollView.documentView = tableView

        let coordinator = context.coordinator
        coordinator.tableView = tableView
        coordinator.tableRowsProvider = tableRowsProvider
        coordinator.tableRowsMutator = tableRowsMutator
        coordinator.paginationOffsetProvider = paginationOffsetProvider
        coordinator.sortedIDs = sortedIDs
        coordinator.delegate = delegate
        coordinator.syncDisplayFormats(displayFormats)
        coordinator.apply(configuration: configuration, isEditable: isEditable)
        delegate?.dataGridAttach(tableViewCoordinator: coordinator)

        let initialRows = tableRowsProvider()
        coordinator.rebuildColumnMetadataCache(from: initialRows)

        coordinator.isRebuildingColumns = true
        let storedInitialLayout = coordinator.savedColumnLayout(binding: columnLayout)
        coordinator.synchronizeUserSizedColumns(
            with: storedInitialLayout,
            columns: initialRows.columns,
            tableIdentityChanged: true
        )
        reconcileColumnPool(
            tableView: tableView,
            coordinator: coordinator,
            tableRows: initialRows,
            columnComments: Self.effectiveColumnComments(for: initialRows),
            savedLayout: storedInitialLayout
        )
        coordinator.isRebuildingColumns = false
        coordinator.updateColumnPresentations(from: initialRows)

        let hasMoveRow = delegate != nil
        if hasMoveRow {
            tableView.registerForDraggedTypes([NSPasteboard.PasteboardType("com.TablePro.rowDrag")])
            tableView.draggingDestinationFeedbackStyle = .gap
        }

        installSelectionOverlay(tableView: tableView, coordinator: coordinator)
        coordinator.attachScrollObservers(scrollView: scrollView)
        // Intentionally do not prime cachedRowCount/cachedColumnCount here.
        // They represent what NSTableView has actually rendered. Leaving them
        // at 0 ensures the first `updateNSView` detects a structure change
        // and triggers `reloadData()` — without this, a recreated grid (e.g.
        // after a Structure/JSON tab toggle) finds the cache already matching
        // the registry rows and skips the reload, leaving the table empty.
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator

        if tableView.editedRow >= 0 { return }
        if let editor = coordinator.overlayEditor, editor.isActive { return }
        if let viewer = coordinator.overlayViewer, viewer.isActive { return }

        coordinator.tableRowsProvider = tableRowsProvider
        coordinator.tableRowsMutator = tableRowsMutator
        coordinator.paginationOffsetProvider = paginationOffsetProvider
        coordinator.changeManager = changeManager

        let latestRows = tableRowsProvider()
        let rowDisplayCount = coordinator.valueFilteredIDs?.count ?? sortedIDs?.count ?? latestRows.count
        let columnCount = latestRows.columns.count
        let settings = AppSettingsManager.shared.dataGrid
        let rowHeight = CGFloat(settings.rowHeight.rawValue)
        let alternatingRows = settings.showAlternateRows
        let columnComments = Self.effectiveColumnComments(for: latestRows)

        let snapshot = DataGridUpdateSnapshot(
            rowDisplayCount: rowDisplayCount,
            columnCount: columnCount,
            columns: latestRows.columns,
            sortedIDsCount: sortedIDs?.count,
            valueFilteredIDsCount: coordinator.valueFilteredIDs?.count,
            displayFormats: displayFormats,
            configuration: configuration,
            isEditable: isEditable,
            hasMoveDelegate: delegate != nil,
            rowHeight: rowHeight,
            alternatingRows: alternatingRows,
            reloadVersion: changeManager.reloadVersion,
            contentRevision: contentRevision,
            columnComments: columnComments
        )

        if snapshot != coordinator.lastUpdateSnapshot {
            let contentChanged = snapshot.reloadVersion != coordinator.lastUpdateSnapshot?.reloadVersion
                || snapshot.contentRevision != coordinator.lastUpdateSnapshot?.contentRevision
            applyStructuralUpdate(
                tableView: tableView,
                coordinator: coordinator,
                latestRows: latestRows,
                rowDisplayCount: rowDisplayCount,
                columnCount: columnCount,
                rowHeight: rowHeight,
                alternatingRows: alternatingRows,
                hasMoveDelegate: snapshot.hasMoveDelegate,
                contentChanged: contentChanged,
                columnComments: columnComments
            )
            coordinator.lastUpdateSnapshot = snapshot
        }

        syncSortState(tableView: tableView, coordinator: coordinator)
        syncSelection(tableView: tableView, coordinator: coordinator)
    }

    private func applyStructuralUpdate(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        latestRows: TableRows,
        rowDisplayCount: Int,
        columnCount: Int,
        rowHeight: CGFloat,
        alternatingRows: Bool,
        hasMoveDelegate: Bool,
        contentChanged: Bool,
        columnComments: [String: String]
    ) {
        if let rowNumCol = tableView.tableColumns.first(where: { $0.identifier == ColumnIdentitySchema.rowNumberIdentifier }) {
            let shouldHide = !configuration.showRowNumbers
            if rowNumCol.isHidden != shouldHide {
                rowNumCol.isHidden = shouldHide
                if !shouldHide {
                    coordinator.resizeRowNumberColumnForCurrentRange()
                }
            }
        }

        let rowDragType = NSPasteboard.PasteboardType("com.TablePro.rowDrag")
        let hasDragRegistered = tableView.registeredDraggedTypes.contains(rowDragType)
        if hasMoveDelegate && !hasDragRegistered {
            tableView.registerForDraggedTypes([rowDragType])
            tableView.draggingDestinationFeedbackStyle = .gap
        } else if !hasMoveDelegate && hasDragRegistered {
            let remaining = tableView.registeredDraggedTypes.filter { $0 != rowDragType }
            tableView.unregisterDraggedTypes()
            if !remaining.isEmpty {
                tableView.registerForDraggedTypes(remaining)
            }
        }

        if tableView.rowHeight != rowHeight {
            tableView.rowHeight = rowHeight
        }
        if tableView.usesAlternatingRowBackgroundColors != alternatingRows {
            tableView.usesAlternatingRowBackgroundColors = alternatingRows
        }

        let oldRowCount = coordinator.cachedRowCount
        let oldColumnCount = coordinator.cachedColumnCount
        let structureChanged = oldRowCount != rowDisplayCount || oldColumnCount != columnCount

        let previousColumnKey = coordinator.columnLayoutKey
        let liveColumnWidths = latestRows.columns.isEmpty ? [:] : coordinator.currentColumnWidths()
        coordinator.apply(configuration: configuration, isEditable: isEditable)
        let schemaChanged = coordinator.rebuildColumnMetadataCache(from: latestRows)
        let presentationChanges = coordinator.updateColumnPresentations(from: latestRows)
        let needsFullReload = structureChanged
            || schemaChanged
            || contentChanged
            || !presentationChanges.isEmpty
        if contentChanged {
            coordinator.invalidateDisplayCache()
        }

        if oldRowCount == 0, rowDisplayCount > 0, rowHeight > 0 {
            let visibleRows = Int(tableView.visibleRect.height / rowHeight) + 5
            coordinator.preWarmDisplayCache(upTo: visibleRows)
        }

        coordinator.sortedIDs = sortedIDs
        coordinator.updateCache()
        coordinator.delegate = delegate
        let displayFormatsChanged = coordinator.columnDisplayFormats != displayFormats
        let remappedValueFilters = coordinator.syncDisplayFormats(displayFormats)
        delegate?.dataGridAttach(tableViewCoordinator: coordinator)
        coordinator.recomputeValueFilteredIDs()
        coordinator.updateCache()
        coordinator.visualIndex.rebuild(from: coordinator.changeManager, sortedIDs: coordinator.displayIDs)

        if !latestRows.columns.isEmpty {
            coordinator.isRebuildingColumns = true
            let sameTableLiveWidths = TableViewCoordinator.liveWidthsForSameTable(
                previous: previousColumnKey,
                current: coordinator.columnLayoutKey,
                liveWidths: liveColumnWidths
            )
            let storedLayout = coordinator.savedColumnLayout(binding: columnLayout)
            coordinator.synchronizeUserSizedColumns(
                with: storedLayout,
                columns: latestRows.columns,
                tableIdentityChanged: previousColumnKey != coordinator.columnLayoutKey
            )
            let reconciliationWidths = coordinator.liveWidthsForReconciliation(sameTableLiveWidths)
            let savedLayout = coordinator.resolvedColumnLayout(
                binding: columnLayout,
                liveWidths: reconciliationWidths
            )
            reconcileColumnPool(
                tableView: tableView,
                coordinator: coordinator,
                tableRows: latestRows,
                columnComments: columnComments,
                savedLayout: savedLayout
            )
            coordinator.isRebuildingColumns = false
            coordinator.invalidateColumnIndexCache()
        }

        coordinator.updateValueFilterHeaderIndicators()

        if needsFullReload || remappedValueFilters {
            coordinator.selectionController.clear()
            tableView.reloadData()
            coordinator.startBackgroundPrewarm()
        } else if displayFormatsChanged {
            coordinator.reloadAfterDisplayFormatChange()
        }
    }

    private func syncSelection(tableView: NSTableView, coordinator: TableViewCoordinator) {
        let currentSelection = tableView.selectedRowIndexes
        let targetSelection = IndexSet(selectedRowIndices)
        guard currentSelection != targetSelection else { return }
        coordinator.isApplyingProgrammaticRowSelection = true
        tableView.selectRowIndexes(targetSelection, byExtendingSelection: false)
        coordinator.isApplyingProgrammaticRowSelection = false
    }

    private static func effectiveColumnComments(for tableRows: TableRows) -> [String: String] {
        guard AppSettingsManager.shared.general.showObjectComments else { return [:] }
        return tableRows.columnComments
    }

    private func reconcileColumnPool(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        tableRows: TableRows,
        columnComments: [String: String],
        savedLayout: ColumnLayoutState?
    ) {
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: tableRows.columnTypes,
            columnComments: columnComments,
            savedLayout: savedLayout,
            isEditable: isEditable,
            hiddenColumnNames: configuration.hiddenColumns,
            widthCalculator: { columnName, slot in
                coordinator.cellFactory.calculateOptimalColumnWidth(
                    for: columnName,
                    columnIndex: slot,
                    tableRows: tableRows,
                    accessory: coordinator.columnPresentation(
                        for: slot,
                        in: tableRows
                    ).accessory,
                    displayFormat: slot < coordinator.columnDisplayFormats.count
                        ? coordinator.columnDisplayFormats[slot]
                        : nil,
                    databaseType: coordinator.databaseType,
                    isLargeDataset: coordinator.isLargeDataset,
                    nullDisplayString: coordinator.cellRegistry.nullDisplayString
                )
            }
        )
    }

    private func syncSortState(tableView: NSTableView, coordinator: TableViewCoordinator) {
        let schema = coordinator.identitySchema
        let resolved = SortColumnResolver.reindexed(sortState, displayColumns: schema.columnNames)
        coordinator.currentSortState = resolved
        guard let header = tableView.headerView as? SortableHeaderView else { return }
        header.applySortState(resolved, schema: schema)
    }

    // MARK: - Column Layout Helpers

    @MainActor
    static func makeRowNumberColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        column.title = "#"
        column.isEditable = false
        column.resizingMask = []
        sizeRowNumberColumn(column, forMaxRowNumber: 1)
        let defaultHeaderFont = column.headerCell.font
        let headerCell = SortableHeaderCell(textCell: "#")
        headerCell.font = defaultHeaderFont
        headerCell.alignment = .right
        headerCell.supportsValueFilter = false
        headerCell.setAccessibilityLabel(String(localized: "Row number"))
        column.headerCell = headerCell
        return column
    }

    @MainActor
    static func sizeRowNumberColumn(_ column: NSTableColumn, forMaxRowNumber maxNumber: Int) {
        let display = "\(max(maxNumber, 1))"
        let font = ThemeEngine.shared.dataGridFonts.rowNumber
        let textWidth = (display as NSString).size(withAttributes: [.font: font]).width
        let measured = ceil(textWidth)
            + 2 * DataGridMetrics.cellHorizontalInset
            + DataGridMetrics.rowNumberHeaderPadding
        let columnWidth = max(DataGridMetrics.rowNumberColumnMinWidth, measured)
        column.minWidth = columnWidth
        column.maxWidth = columnWidth
        column.width = columnWidth
    }

    private func installSelectionOverlay(tableView: KeyHandlingTableView, coordinator: TableViewCoordinator) {
        let overlay = GridSelectionOverlay(frame: tableView.bounds)
        overlay.tableView = tableView
        overlay.coordinator = coordinator
        tableView.addSubview(overlay)
        coordinator.selectionController.tableView = tableView
        coordinator.selectionController.overlay = overlay
        coordinator.selectionController.coordinator = coordinator
        tableView.selectionOverlay = overlay
    }

    static let firstDataTableColumnIndex: Int = 1

    static func isDataTableColumn(_ tableColumnIndex: Int) -> Bool {
        tableColumnIndex >= firstDataTableColumnIndex
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
        coordinator.overlayEditor?.dismiss(commit: true)
        coordinator.flushPendingColumnLayoutPersistence()
        coordinator.settingsCancellable = nil
        coordinator.themeCancellable = nil
    }

    func makeCoordinator() -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: changeManager,
            isEditable: isEditable,
            selectedRowIndices: $selectedRowIndices,
            delegate: delegate,
            layoutPersister: layoutPersister ?? FileColumnLayoutPersister.shared
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
