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
    var displayFormats: [ValueDisplayFormat?] = []
    var delegate: (any DataGridViewDelegate)?
    var layoutPersister: (any ColumnLayoutPersisting)?
    /// Whether a row may be dragged to a new position, and why not when it may not.
    var rowReorder: DataGridRowReorder = .disabled

    @Binding var selectedRowIndices: Set<Int>
    @Binding var sortState: SortState
    @Binding var columnLayout: ColumnLayoutState
    /// The per-column value filter, bound to an owner that outlives this view.
    ///
    /// SwiftUI destroys the coordinator whenever the grid leaves the view tree, and the display
    /// order this filter produces has to survive that: JSON mode, the row inspector and the Edit
    /// menu's row commands all read it with no grid mounted. A grid with no owner keeps the filter
    /// on its own coordinator, which is all a structure or create-table grid ever needs. (#2251)
    var valueFilter: Binding<GridValueFilterState>?
    /// The formatted text and viewport anchor for this result, owned the same way and for the same
    /// reason as the value filter above. The owner hands back a fresh instance whenever the inputs
    /// that decide the text have moved, so adopting one is always safe. (#2424)
    var displayState: DataGridDisplayState?
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
        tableView.gridStyleMask = []
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
        coordinator.valueFilterBinding = valueFilter
        if let valueFilter {
            coordinator.adoptValueFilter(valueFilter.wrappedValue)
        }
        if let displayState {
            coordinator.adoptDisplayState(displayState)
        }
        coordinator.delegate = delegate
        coordinator.syncDisplayFormats(displayFormats)
        // A remount inherits the owner's filter, so resolve the order before the first update
        // builds its snapshot from it. Otherwise the grid reports the unfiltered count once.
        coordinator.recomputeValueFilteredIDs()
        coordinator.apply(configuration: configuration, isEditable: isEditable)
        delegate?.dataGridAttach(tableViewCoordinator: coordinator)

        let initialRows = tableRowsProvider()
        coordinator.rebuildColumnMetadataCache(from: initialRows)

        coordinator.isRebuildingColumns = true
        let storedInitialLayout = coordinator.layoutDiscardingUnownedWidths(
            coordinator.savedColumnLayout(binding: columnLayout),
            tableRows: initialRows
        )
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

        coordinator.rowReorder = rowReorder
        if rowReorder.isEnabled {
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

        // The owner can change the filter while the grid is unmounted, so adopt and re-resolve
        // before the snapshot is built. A snapshot taken from the stale order would report no
        // change and skip the reload.
        coordinator.valueFilterBinding = valueFilter
        if let valueFilter, coordinator.valueFilterState != valueFilter.wrappedValue {
            coordinator.adoptValueFilter(valueFilter.wrappedValue)
            coordinator.recomputeValueFilteredIDs()
        }
        if let displayState {
            coordinator.adoptDisplayState(displayState)
        }

        let latestRows = tableRowsProvider()
        let rowDisplayCount = coordinator.valueFilteredIDs?.count ?? latestRows.count
        let columnCount = latestRows.columns.count
        let settings = AppSettingsManager.shared.dataGrid
        let rowHeight = CGFloat(settings.rowHeight.rawValue)
        let alternatingRows = settings.showAlternateRows
        let columnComments = Self.effectiveColumnComments(for: latestRows)

        let snapshot = DataGridUpdateSnapshot(
            rowDisplayCount: rowDisplayCount,
            columnCount: columnCount,
            columns: latestRows.columns,
            valueFilteredIDsCount: coordinator.valueFilteredIDs?.count,
            displayFormats: displayFormats,
            configuration: configuration,
            isEditable: isEditable,
            rowReorder: rowReorder,
            rowHeight: rowHeight,
            alternatingRows: alternatingRows,
            reloadVersion: changeManager.reloadVersion,
            contentRevision: contentRevision,
            columnComments: columnComments
        )

        var contentReplaced = false
        if snapshot != coordinator.lastUpdateSnapshot {
            // Read from the retained state rather than from `lastUpdateSnapshot`, which is nil on a
            // freshly mounted coordinator and would therefore report every remount as a content
            // change and discard the text the owner just handed over.
            let contentIdentity = DataGridContentIdentity(
                reloadVersion: changeManager.reloadVersion,
                contentRevision: contentRevision
            )
            let contentChanged = coordinator.displayState.contentIdentity != contentIdentity
            contentReplaced = contentChanged
            coordinator.displayState.contentIdentity = contentIdentity
            applyStructuralUpdate(
                tableView: tableView,
                coordinator: coordinator,
                latestRows: latestRows,
                rowDisplayCount: rowDisplayCount,
                columnCount: columnCount,
                rowHeight: rowHeight,
                alternatingRows: alternatingRows,
                rowReorder: snapshot.rowReorder,
                contentChanged: contentChanged,
                columnComments: columnComments
            )
            coordinator.lastUpdateSnapshot = snapshot
        }

        syncSortState(tableView: tableView, coordinator: coordinator)
        syncSelection(tableView: tableView, coordinator: coordinator)
        coordinator.schedulePendingColumnJump(contentReplaced: contentReplaced)
    }

    private func applyStructuralUpdate(
        tableView: NSTableView,
        coordinator: TableViewCoordinator,
        latestRows: TableRows,
        rowDisplayCount: Int,
        columnCount: Int,
        rowHeight: CGFloat,
        alternatingRows: Bool,
        rowReorder: DataGridRowReorder,
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
                coordinator.columnGeometryDidChange()
            }
        }

        coordinator.rowReorder = rowReorder
        let rowDragType = NSPasteboard.PasteboardType("com.TablePro.rowDrag")
        let hasDragRegistered = tableView.registeredDraggedTypes.contains(rowDragType)
        if rowReorder.isEnabled && !hasDragRegistered {
            tableView.registerForDraggedTypes([rowDragType])
            tableView.draggingDestinationFeedbackStyle = .gap
        } else if !rowReorder.isEnabled && hasDragRegistered {
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
            coordinator.preWarmDisplayCache(rowCount: visibleRows, from: coordinator.scrollAnchorRow)
        }

        coordinator.updateCache()
        coordinator.delegate = delegate
        let displayFormatsChanged = coordinator.columnDisplayFormats != displayFormats
        let remappedValueFilters = coordinator.syncDisplayFormats(displayFormats)
        delegate?.dataGridAttach(tableViewCoordinator: coordinator)
        coordinator.recomputeValueFilteredIDs()
        coordinator.updateCache()
        coordinator.visualIndex.rebuild(from: coordinator.changeManager, displayIDs: coordinator.displayIDs)

        if !latestRows.columns.isEmpty {
            coordinator.isRebuildingColumns = true
            let sameTableLiveWidths = TableViewCoordinator.liveWidthsForSameTable(
                previous: previousColumnKey,
                current: coordinator.columnLayoutKey,
                liveWidths: liveColumnWidths
            )
            let storedLayout = coordinator.layoutDiscardingUnownedWidths(
                coordinator.savedColumnLayout(binding: columnLayout),
                tableRows: latestRows
            )
            coordinator.synchronizeUserSizedColumns(
                with: storedLayout,
                columns: latestRows.columns,
                tableIdentityChanged: previousColumnKey != coordinator.columnLayoutKey
            )
            let reconciliationWidths = coordinator.liveWidthsForReconciliation(sameTableLiveWidths)
            let savedLayout = coordinator.resolvedColumnLayout(
                saved: storedLayout,
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
            coordinator.applyAccessoryWidthChanges(presentationChanges, tableRows: latestRows)
        }

        coordinator.updateValueFilterHeaderIndicators()

        if needsFullReload || remappedValueFilters {
            coordinator.selectionController.clear()
            tableView.reloadData()
            coordinator.restoreScrollAnchor()
            coordinator.startBackgroundPrewarm()
        } else if displayFormatsChanged {
            coordinator.reloadAfterDisplayFormatChange()
        }
    }

    private func syncSelection(tableView: NSTableView, coordinator: TableViewCoordinator) {
        let currentSelection = tableView.selectedRowIndexes
        let targetSelection = IndexSet(selectedRowIndices)
        guard currentSelection != targetSelection else { return }
        coordinator.selectRowsProgrammatically(targetSelection, in: tableView)
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
        let visibilityChanged = coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: tableRows.columnTypes,
            columnComments: columnComments,
            savedLayout: savedLayout,
            isEditable: isEditable,
            hiddenColumnNames: configuration.hiddenColumns,
            widthCalculator: { columnName, slot in
                coordinator.automaticColumnWidth(
                    for: columnName,
                    columnIndex: slot,
                    tableRows: tableRows
                )
            }
        )
        guard visibilityChanged else { return }
        coordinator.columnGeometryDidChange()
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
    /// The column is pinned to one width, so the interval has to be opened before the width can be
    /// assigned through it.
    ///
    /// Raising `minWidth` past the current width does move `width` with it, but `NSTableView` keeps
    /// its cumulative column geometry at the old value and posts no `columnDidResizeNotification`,
    /// and the assignment that follows then has nothing left to change, so `rect(ofColumn:)` never
    /// catches up. Measured on macOS 27: pinning 40 to 60 reported `width == 60` while the
    /// row-number rect stayed 47pt wide and the next column's origin stayed at 57, and neither
    /// `tile()` nor a display pass repaired it. Assigning the width while it genuinely moves is what
    /// makes AppKit adopt the geometry and announce it.
    static func sizeRowNumberColumn(_ column: NSTableColumn, forMaxRowNumber maxNumber: Int) {
        let display = "\(max(maxNumber, 1))"
        let font = ThemeEngine.shared.dataGridFonts.rowNumber
        let textWidth = (display as NSString).size(withAttributes: [.font: font]).width
        let measured = ceil(textWidth)
            + 2 * DataGridMetrics.cellHorizontalInset
            + DataGridMetrics.rowNumberHeaderPadding
        let columnWidth = max(DataGridMetrics.rowNumberColumnMinWidth, measured)
        guard column.width != columnWidth
            || column.minWidth != columnWidth
            || column.maxWidth != columnWidth else { return }
        column.minWidth = min(column.minWidth, columnWidth)
        column.maxWidth = max(column.maxWidth, columnWidth)
        column.width = columnWidth
        column.minWidth = columnWidth
        column.maxWidth = columnWidth
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
        coordinator.recordScrollAnchor()
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
