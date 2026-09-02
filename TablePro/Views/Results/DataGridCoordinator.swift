import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit

private let fkTraceLogger = Logger(subsystem: "com.TablePro", category: "DataGrid")

/// Which columns need repainting because their accessory changed. Deliberately carries no width
/// information: a column's width is decided when the column is built or auto-fitted, and metadata
/// arriving afterwards repaints the cell without moving anything the user is already reading.
struct DataGridColumnPresentationChanges {
    var indices = IndexSet()

    var isEmpty: Bool { indices.isEmpty }
}

struct DataGridColumnPresentationIdentity: Hashable {
    let name: String
    let occurrence: Int
}

struct PendingColumnLayoutPersistence: Equatable {
    let layout: ColumnLayoutState
    let tableKey: ColumnLayoutTableKey?
    let writesToTableStorage: Bool
}

// MARK: - Coordinator

@MainActor
final class TableViewCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
                                  NSMenuDelegate
{
    var tableRowsProvider: @MainActor () -> TableRows = { TableRows() }
    var tableRowsMutator: @MainActor (@MainActor (inout TableRows) -> Void) -> Void = { _ in }
    var paginationOffsetProvider: @MainActor () -> Int = { 0 }
    var changeManager: AnyChangeManager
    var isEditable: Bool
    var editRefusalMessage: String?
    var valueFilteredIDs: [RowID]? { didSet { bumpDisplayRevision() } }
    /// Ticks whenever the displayed row order or the value filter changes.
    ///
    /// `displayIDs` reaches SwiftUI only through weak, observation-ignored hops, so a filter change
    /// produces no signal on its own. Views that render the same rows outside the grid key off this
    /// instead of comparing the id array, which is O(rows) on every body evaluation.
    private(set) var displayRevision: Int = 0
    /// Set by `DataGridView` when the grid has an owner that holds the filter for it. Without one
    /// the filter lives here alone and dies with this coordinator, which is all a structure or
    /// create-table grid needs.
    var valueFilterBinding: Binding<GridValueFilterState>?
    private var storedValueFilterState = GridValueFilterState()
    /// Reads never go back through the binding, because a SwiftUI `Binding` built from a captured
    /// value type returns the pre-write value until the next body pass. The mirror is authoritative
    /// for this coordinator and `adoptValueFilter(_:)` pulls owner-driven changes in.
    ///
    /// A write reaches the owner's observable state, and `remapValueFilters` performs one from
    /// inside `updateNSView` when a column's display format changes. That is bounded to a single
    /// extra update: the guard below drops a no-op write, and the next pass finds the formats
    /// already synced, so `syncDisplayFormats` returns before it can remap again.
    var valueFilterState: GridValueFilterState {
        get { storedValueFilterState }
        set {
            guard newValue != storedValueFilterState else { return }
            storedValueFilterState = newValue
            valueFilterBinding?.wrappedValue = newValue
        }
    }
    var displayIDs: [RowID]? { valueFilteredIDs }
    private(set) var columnDisplayFormats: [ValueDisplayFormat?] = []
    private(set) var currentFindMatch: FindMatch?
    /// Owned by whoever outlives this coordinator when there is one, so a remount reuses the text it
    /// already formatted instead of formatting the whole result again. A grid with no owner keeps
    /// its own, which is all a structure or create-table grid ever needs. (#2424)
    private(set) var displayState = DataGridDisplayState()
    var displayCache: RowDisplayCache { displayState.cache }
    private var pendingScrollAnchorRow: Int?
    var pendingColumnJump: PendingColumnJump?
    weak var delegate: (any DataGridViewDelegate)?
    var rowReorder: DataGridRowReorder = .disabled
    weak var activeFKPreviewPopover: NSPopover?
    weak var activeCellEditorPopover: NSPopover?
    weak var activePoppedOutEditor: JSONViewerWindowController?
    weak var activeValueFilterPopover: NSPopover?
    var activeFKPreviewModel: FKPreviewModel?
    var activeFKPreviewColumnIndex: Int?
    var dropdownColumns: Set<Int>?
    var typePickerColumns: Set<Int>?
    var customDropdownOptions: [Int: [String]]?
    var connectionId: UUID?
    var databaseType: DatabaseType?
    var tableName: String?
    var databaseName: String?
    var schemaName: String?
    var primaryKeyColumns: [String] = []
    var primaryKeyColumn: String? { primaryKeyColumns.first }
    var tabType: TabType?
    var layoutPersister: any ColumnLayoutPersisting
    var onColumnLayoutDidChange: ((ColumnLayoutState) -> Void)?
    private(set) var identitySchema: ColumnIdentitySchema = .empty
    var currentSortState = SortState()

    private var columnIndexByDataIndex: [Int: Int] = [:]
    private static let selectionCacheLogger = Logger(subsystem: "com.TablePro", category: "DataGrid.ColumnIndexCache")

    func tableColumnIndex(for dataIndex: Int) -> Int? {
        if let cached = columnIndexByDataIndex[dataIndex] {
            return cached
        }
        guard let tableView,
              let identifier = identitySchema.identifier(for: dataIndex) else { return nil }
        let resolved = tableView.column(withIdentifier: identifier)
        guard resolved >= 0 else { return nil }
        columnIndexByDataIndex[dataIndex] = resolved
        return resolved
    }

    /// Takes an owner-driven filter change without writing it back, which a plain assignment would.
    func adoptValueFilter(_ state: GridValueFilterState) {
        storedValueFilterState = state
    }

    /// Takes over the formatted text and viewport anchor the owner kept while no grid was mounted.
    ///
    /// The owner hands back a fresh state whenever the inputs that decide the text have moved, so
    /// there is nothing to validate here.
    func adoptDisplayState(_ state: DataGridDisplayState) {
        guard state !== displayState else { return }
        displayState = state
        pendingScrollAnchorRow = state.firstVisibleRow
        /// Both directions, because either side can be the one that knows. A fresh coordinator
        /// takes the schema and formats the state carries, so its first update does not report them
        /// as a change and clear the text. A state handed over while the grid stays mounted carries
        /// neither, and the writers that would fill them are change-gated and will not fire, so it
        /// takes them from here instead and the next remount still restores.
        if let schema = state.identitySchema {
            identitySchema = schema
        } else {
            state.identitySchema = identitySchema
        }
        if let formats = state.displayFormats {
            columnDisplayFormats = formats
        } else {
            state.displayFormats = columnDisplayFormats
        }
    }

    var scrollAnchorRow: Int { pendingScrollAnchorRow ?? 0 }

    /// Records where the user was looking, so returning to this tab does not start at the first row.
    func recordScrollAnchor() {
        guard let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        displayState.firstVisibleRow = max(0, visible.location)
    }

    /// `scrollRowToVisible` only guarantees visibility, so from a grid scrolled to the top it puts
    /// the anchor at the bottom of the viewport rather than back where the user left it.
    func restoreScrollAnchor() {
        guard let tableView, let row = pendingScrollAnchorRow else { return }
        pendingScrollAnchorRow = nil
        guard row > 0, row < tableView.numberOfRows else { return }
        let origin = tableView.rect(ofRow: row).origin
        let x = tableView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        tableView.scroll(NSPoint(x: x, y: origin.y))
    }

    func invalidateColumnIndexCache() {
        guard !columnIndexByDataIndex.isEmpty else { return }
        Self.selectionCacheLogger.debug("invalidate column index cache (had \(self.columnIndexByDataIndex.count))")
        columnIndexByDataIndex.removeAll()
    }

    func columnIdentifier(for dataIndex: Int) -> NSUserInterfaceItemIdentifier? {
        identitySchema.identifier(for: dataIndex)
    }

    func dataColumnIndex(from identifier: NSUserInterfaceItemIdentifier) -> Int? {
        identitySchema.dataIndex(from: identifier)
    }

    /// Whether the result presents this column, regardless of whether the window has it mounted.
    func presentsColumn(_ column: NSTableColumn) -> Bool {
        columnPool.presentsColumn(column)
    }

    /// Whether this position in `tableColumns` holds one of the columns the result presents.
    ///
    /// The row-number column and the window's two spacers are attached columns as well, and one
    /// spacer sits immediately before the first data column, so no fixed position answers this.
    func presentsColumn(atTableColumnIndex index: Int) -> Bool {
        guard let tableView else { return false }
        return columnPool.presentsColumn(atTableColumnIndex: index, in: tableView)
    }

    func firstPresentedColumnIndex() -> Int? {
        guard let tableView else { return nil }
        return columnPool.firstPresentedColumnIndex(in: tableView)
    }

    func lastPresentedColumnIndex() -> Int? {
        guard let tableView else { return nil }
        return columnPool.lastPresentedColumnIndex(in: tableView)
    }

    func nextPresentedColumnIndex(after index: Int) -> Int? {
        guard let tableView else { return nil }
        return columnPool.nextPresentedColumnIndex(after: index, in: tableView)
    }

    func previousPresentedColumnIndex(before index: Int) -> Int? {
        guard let tableView else { return nil }
        return columnPool.previousPresentedColumnIndex(before: index, in: tableView)
    }

    /// The single way to reach a column, for Find, cell navigation and the inline editor alike.
    func scrollColumnToVisible(tableColumnIndex index: Int) {
        guard let tableView, index >= 0, index < tableView.numberOfColumns else { return }
        tableView.scrollColumnToVisible(index)
    }

    /// The columns the user is looking at, which is every presented column and not merely the
    /// mounted ones. Copy, find and size-all all read this, so narrowing it to the window would
    /// silently drop the columns off screen from a copied row or a search.
    func visibleColumnDataIndices() -> [Int]? {
        guard let tableView else { return nil }
        return tableView.tableColumns
            .filter { presentsColumn($0) }
            .compactMap { dataColumnIndex(from: $0.identifier) }
    }

    var columnLayoutKey: ColumnLayoutTableKey? {
        guard let connectionId, let tableName, !tableName.isEmpty else { return nil }
        return ColumnLayoutTableKey(
            connectionId: connectionId,
            databaseName: databaseName ?? "",
            schemaName: schemaName,
            tableName: tableName
        )
    }

    func apply(configuration: DataGridConfiguration, isEditable: Bool) {
        let identityChanged = connectionId != configuration.connectionId
            || tableName != configuration.tableName
            || databaseName != configuration.databaseName
            || schemaName != configuration.schemaName
            || tabType != configuration.tabType
        if identityChanged {
            flushPendingColumnLayoutPersistence()
            columnLayoutPersistenceGeneration &+= 1
        }
        self.isEditable = isEditable
        editRefusalMessage = configuration.editRefusalMessage
        tableView?.toolTip = isEditable ? nil : configuration.editRefusalMessage
        dropdownColumns = configuration.dropdownColumns
        typePickerColumns = configuration.typePickerColumns
        customDropdownOptions = configuration.customDropdownOptions
        connectionId = configuration.connectionId
        databaseType = configuration.databaseType
        tableName = configuration.tableName
        databaseName = configuration.databaseName
        schemaName = configuration.schemaName
        primaryKeyColumns = configuration.primaryKeyColumns
        tabType = configuration.tabType
    }

    /// A grid with no table behind it keeps a saved column order only while its columns are still the
    /// ones that order was saved for.
    ///
    /// A query result's columns are authored by the SELECT list and their order is meaningful, so an
    /// order saved for a different set must not be replayed over it: `computeTargetOrder` appends
    /// every column the saved order does not name, which landed a newly written column at the far
    /// right instead of where it was typed (#1565). Dropping the order outright answered that and
    /// also threw away orders the columns had never moved under, so a reorder was captured, persisted
    /// and then silently undone on the next update.
    func savedColumnLayout(binding: ColumnLayoutState) -> ColumnLayoutState? {
        guard tabType == .table else {
            var layout = binding
            if let order = layout.columnOrder, !canRestoreColumnOrder(order) {
                layout.columnOrder = nil
            }
            guard !layout.columnWidths.isEmpty
                || layout.columnContentWidths?.isEmpty == false
                || layout.columnOrder?.isEmpty == false else { return nil }
            return layout
        }

        if let columnLayoutKey, let stored = layoutPersister.load(for: columnLayoutKey) {
            return stored
        }
        if binding.columnWidths.isEmpty,
           binding.columnContentWidths?.isEmpty != false,
           binding.columnOrder == nil {
            return nil
        }
        return binding
    }

    /// A saved order is a list of names, and a name identifies a column only while the names are
    /// unique. `SELECT a.id, b.id` gives two columns called `id`, and `ColumnIdentitySchema` resolves
    /// a duplicate name to its last slot, so replaying such an order swaps the two columns.
    private func canRestoreColumnOrder(_ order: [String]) -> Bool {
        let columns = identitySchema.columnNames
        let names = Set(columns)
        return names.count == columns.count && Set(order) == names
    }

    /// A saved width is the width the column had, accessory or not. Nothing here re-derives it from
    /// the accessory, because the accessory no longer contributes to column width: a layout saved
    /// while the arrow was showing and restored before it is known has to come back the same size.
    func resolvedColumnLayout(
        binding: ColumnLayoutState,
        liveWidths: [String: CGFloat]
    ) -> ColumnLayoutState? {
        resolvedColumnLayout(saved: savedColumnLayout(binding: binding), liveWidths: liveWidths)
    }

    func resolvedColumnLayout(
        saved: ColumnLayoutState?,
        liveWidths: [String: CGFloat]
    ) -> ColumnLayoutState? {
        guard let saved else {
            guard !liveWidths.isEmpty else { return nil }
            return ColumnLayoutState(columnWidths: liveWidths)
        }
        guard !liveWidths.isEmpty else { return saved }
        return saved.mergingWidths(liveWidths)
    }

    static func liveWidthsForSameTable(
        previous: ColumnLayoutTableKey?,
        current: ColumnLayoutTableKey?,
        liveWidths: [String: CGFloat]
    ) -> [String: CGFloat] {
        previous == current ? liveWidths : [:]
    }

    func currentColumnWidths() -> [String: CGFloat] {
        guard let tableView else { return [:] }
        var widths: [String: CGFloat] = [:]
        for column in tableView.tableColumns
        where column.identifier != ColumnIdentitySchema.rowNumberIdentifier {
            guard let dataIndex = dataColumnIndex(from: column.identifier),
                  let name = identitySchema.columnName(for: dataIndex) else { continue }
            widths[name] = max(widths[name] ?? 0, column.width)
        }
        return widths
    }

    func synchronizeUserSizedColumns(
        with savedLayout: ColumnLayoutState?,
        columns: [String],
        tableIdentityChanged: Bool
    ) {
        let savedWidthNames = Set(savedLayout?.columnWidths.keys.map { $0 } ?? [])
        let savedContentWidthNames = Set(savedLayout?.columnContentWidths?.keys.map { $0 } ?? [])
        let savedNames = savedWidthNames.union(savedContentWidthNames)
        if tableIdentityChanged || !hasUnpersistedColumnLayoutChanges {
            userSizedColumnNames = savedNames
        } else {
            userSizedColumnNames.formUnion(savedNames)
        }
        userSizedColumnNames.formIntersection(columns)
    }

    @discardableResult
    func markColumnWidthUserSized(_ column: NSTableColumn) -> Bool {
        guard column.identifier != ColumnIdentitySchema.rowNumberIdentifier,
              let dataIndex = dataColumnIndex(from: column.identifier),
              let name = identitySchema.columnName(for: dataIndex)
        else { return false }
        userSizedColumnNames.insert(name)
        unownedRestoredColumnNames.remove(name)
        hasUnpersistedColumnLayoutChanges = true
        return true
    }

    func resetColumnWidthOwnership() {
        userSizedColumnNames.removeAll()
        shouldRecalculateAutomaticColumnWidths = true
        hasUnpersistedColumnLayoutChanges = false
        layoutPersistTask?.cancel()
        layoutPersistTask = nil
        pendingColumnLayoutPersistence = nil
    }

    /// Dropping a live width is what asks the reconcile pass to size that column from its content
    /// again, so only an explicit auto-fit does it. A column the user sized keeps its width even
    /// then, and no accessory change reaches here at all.
    func liveWidthsForReconciliation(_ liveWidths: [String: CGFloat]) -> [String: CGFloat] {
        guard shouldRecalculateAutomaticColumnWidths else { return liveWidths }
        shouldRecalculateAutomaticColumnWidths = false
        return liveWidths.filter { userSizedColumnNames.contains($0.key) }
    }

    func captureColumnLayout() -> ColumnLayoutState? {
        guard let tableView else { return nil }
        let tableRows = tableRowsProvider()
        guard !tableRows.columns.isEmpty else { return nil }

        var legacyWidths: [String: CGFloat] = [:]
        var contentWidths: [String: CGFloat] = [:]
        var order: [String] = []
        for column in tableView.tableColumns
        where column.identifier != ColumnIdentitySchema.rowNumberIdentifier {
            guard let colIndex = dataColumnIndex(from: column.identifier),
                  colIndex < tableRows.columns.count else { continue }
            let name = tableRows.columns[colIndex]
            order.append(name)
            if userSizedColumnNames.contains(name) {
                legacyWidths[name] = max(legacyWidths[name] ?? 0, column.width)
                contentWidths[name] = max(contentWidths[name] ?? 0, column.width)
            }
        }

        guard !order.isEmpty else { return nil }
        var layout = ColumnLayoutState()
        layout.columnWidths = legacyWidths
        layout.columnContentWidths = contentWidths.isEmpty ? nil : contentWidths
        layout.columnOrder = order
        return layout
    }

    func persistColumnLayoutToStorage() {
        layoutPersistTask?.cancel()
        layoutPersistTask = nil
        let pending = makePendingColumnLayoutPersistence()
        pendingColumnLayoutPersistence = nil
        guard let pending else { return }
        persistColumnLayout(pending)
    }

    func makePendingColumnLayoutPersistence() -> PendingColumnLayoutPersistence? {
        guard let layout = captureColumnLayout() else { return nil }
        return PendingColumnLayoutPersistence(
            layout: layout,
            tableKey: columnLayoutKey,
            writesToTableStorage: tabType == .table
        )
    }

    func persistColumnLayout(_ pending: PendingColumnLayoutPersistence) {
        onColumnLayoutDidChange?(pending.layout)
        if pending.writesToTableStorage, let tableKey = pending.tableKey {
            layoutPersister.save(pending.layout, for: tableKey)
        }
        hasUnpersistedColumnLayoutChanges = false
    }

    weak var tableView: NSTableView?
    let cellFactory = DataGridCellFactory()
    let cellRegistry: DataGridCellRegistry
    let columnPool = DataGridColumnPool()
    /// Draws every data cell in the grid. One renderer for the whole table, because its only state
    /// is a cache of laid-out lines and every row draws the same values as it scrolls.
    let cellRenderer = DataGridCellRenderer()
    /// The cell an overlay editor or viewer is open over, which draws no text of its own behind it.
    var overlayCell: CellPosition? {
        didSet {
            guard overlayCell != oldValue else { return }
            for position in [oldValue, overlayCell].compactMap({ $0 }) {
                redrawCell(row: position.row, columnIndex: position.column)
            }
        }
    }

    /// Repaints every drawn cell on screen, for a change that moves all of them at once.
    func redrawVisibleCells() {
        guard let tableView else { return }
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? DataGridRowView)?.redrawCells()
        }
    }

    /// Repaints whole rows, across the row-number column and every drawn cell.
    ///
    /// `reloadData(forRowIndexes:columnIndexes:)` rebuilds a cell view, and the row-number column is
    /// the only one that still mounts one, so on its own it repaints a row's number and nothing
    /// else. Every caller that used to reload a row's full column range goes through here (#2381).
    ///
    /// A row past the end is dropped rather than passed on: `reloadData(forRowIndexes:)` raises
    /// `NSRangeException` for one, and a row view can outlive the result that shrank under it.
    func repaintRows(_ rows: IndexSet) {
        guard let tableView else { return }
        let rows = rows.filteredIndexSet { $0 >= 0 && $0 < tableView.numberOfRows }
        guard !rows.isEmpty else { return }
        let rowNumberColumn = tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        if rowNumberColumn >= 0 {
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: rowNumberColumn))
        }
        for row in rows {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView)?.redrawCells()
        }
    }

    /// Repaints one drawn cell, which is what a mounted cell got from `setNeedsDisplay` on itself.
    func redrawCell(row: Int, columnIndex: Int) {
        guard let tableView,
              let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView,
              let position = tableColumnIndex(for: columnIndex) else { return }
        rowView.redrawCell(atTableColumnIndex: position)
    }
    let selectionController = GridSelectionController()
    var overlayEditor: CellOverlayEditor?
    var overlayViewer: CellOverlayViewer?

    var settingsCancellable: AnyCancellable?
    var themeCancellable: AnyCancellable?
    private var accessibilityActivationObserver: (any NSObjectProtocol)?
    private var accessibilityMountedRows = NSRange(location: 0, length: 0)
    private var lastDataGridSettings: DataGridSettings

    @Binding var selectedRowIndices: Set<Int>

    private(set) var cachedRowCount: Int = 0
    private(set) var cachedColumnCount: Int = 0
    private(set) var enumOrSetColumns: Set<Int> = []
    private(set) var fkColumns: Set<Int> = []
    private(set) var columnPresentations: [DataGridColumnPresentationIdentity: DataGridColumnPresentation] = [:]
    private(set) var userSizedColumnNames: Set<String> = []
    /// Widths restored from a layout that recorded no ownership, so `userSizedColumnNames` counts
    /// them only because they were saved at all. An accessory that resolves later is still allowed
    /// to widen these, because nobody chose their width.
    var unownedRestoredColumnNames: Set<String> = []
    var isApplyingProgrammaticRowSelection = false
    var isRebuildingColumns: Bool = false
    var hasUnpersistedColumnLayoutChanges = false
    var shouldRecalculateAutomaticColumnWidths = false
    var pendingCellPresentationRefresh = false
    var isEscapeCancelling = false
    var isCommittingCellEdit = false
    var layoutPersistTask: Task<Void, Never>?
    var pendingColumnLayoutPersistence: PendingColumnLayoutPersistence?
    var columnLayoutPersistenceGeneration = 0
    var lastUpdateSnapshot: DataGridUpdateSnapshot?
    var prewarmTask: Task<Void, Never>?
    var prewarmResumeTask: Task<Void, Never>?
    var scrollObservers: [NSObjectProtocol] = []
    static let prewarmFrameBudget: Duration = .milliseconds(2)
    static let prewarmResumeDelay: Duration = .milliseconds(300)

    static let rowViewIdentifier = NSUserInterfaceItemIdentifier("TableRowView")
    let visualIndex = RowVisualIndex()
    private let largeDatasetThreshold = 5_000

    var isLargeDataset: Bool { cachedRowCount > largeDatasetThreshold }

    init(
        changeManager: AnyChangeManager,
        isEditable: Bool,
        selectedRowIndices: Binding<Set<Int>>,
        delegate: (any DataGridViewDelegate)?,
        layoutPersister: any ColumnLayoutPersisting
    ) {
        self.changeManager = changeManager
        self.isEditable = isEditable
        self._selectedRowIndices = selectedRowIndices
        self.delegate = delegate
        self.layoutPersister = layoutPersister
        self.lastDataGridSettings = AppSettingsManager.shared.dataGrid
        self.cellRegistry = DataGridCellRegistry()
        super.init()
        cellRegistry.accessoryDelegate = self
        updateCache()

        observeThemeChanges()
        observeAccessibilityActivation()

        settingsCancellable = AppEvents.shared.dataGridSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let settings = AppSettingsManager.shared.dataGrid
                let prev = self.lastDataGridSettings
                self.lastDataGridSettings = settings
                self.applyDataGridSettingsChange(from: prev, to: settings)
            }
    }

    func applyDataGridSettingsChange(from previous: DataGridSettings, to settings: DataGridSettings) {
        guard let tableView else { return }
        let newRowHeight = CGFloat(settings.rowHeight.rawValue)
        if tableView.rowHeight != newRowHeight {
            tableView.rowHeight = newRowHeight
            tableView.tile()
        }

        let dataChanged = previous.dateFormat != settings.dateFormat
            || previous.nullDisplay != settings.nullDisplay
            || previous.enableSmartValueDetection != settings.enableSmartValueDetection

        if dataChanged {
            invalidateDisplayCache()
            let visibleRect = tableView.visibleRect
            let visibleRange = tableView.rows(in: visibleRect)
            if visibleRange.length > 0 {
                repaintRows(IndexSet(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)))
            }
            startBackgroundPrewarm()
        }
    }

    func observeThemeChanges() {
        themeCancellable = AppEvents.shared.themeChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadVisibleRowsAndStates()
            }
    }

    /// The grid mounts no view for a data cell, so a client that attaches mid-session finds a table
    /// of empty cells until the visible rows are built again. The remount is deferred off the
    /// accessibility query that raised the flag, because rebuilding rows inside it would re-enter
    /// the tree AppKit is walking.
    private func observeAccessibilityActivation() {
        accessibilityActivationObserver = NotificationCenter.default.addObserver(
            forName: DataGridAccessibility.didActivateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.remountAccessibilityCells()
            }
        }
    }

    /// Whether this row is one an assistive client can be reading right now.
    ///
    /// Walking the accessibility tree makes `NSTableView` prepare every row of the page, not the
    /// twenty-five on screen, and it asks for a view for each one. Mounting a cell there put 9,000
    /// views and a 21,000 element tree behind a 1,000-row page, which is the cost `#2381` removed
    /// and enough to starve the app of the main thread. Only the viewport mounts, and scrolling
    /// mounts what it brings into view.
    func mountsAccessibilityCell(forRow row: Int) -> Bool {
        guard let tableView else { return false }
        return NSLocationInRange(row, tableView.rows(in: tableView.visibleRect))
    }

    /// Rebuilds the cells for the rows now on screen. A row prepared while it was off screen was
    /// answered with no view and is never asked again, so the rows a scroll reveals have to be
    /// reloaded rather than waited for.
    func remountAccessibilityCells() {
        guard DataGridAccessibility.isActive, let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0, !NSEqualRanges(visible, accessibilityMountedRows) else { return }
        let upperBound = min(visible.location + visible.length, tableView.numberOfRows)
        guard visible.location >= 0, upperBound > visible.location, tableView.numberOfColumns > 0 else { return }
        accessibilityMountedRows = visible
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<upperBound),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    func releaseData() {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        detachScrollObservers()
        selectionController.clear()
        pendingColumnJump = nil
        overlayEditor?.dismiss(commit: false)
        overlayViewer?.dismiss()
        settingsCancellable?.cancel()
        settingsCancellable = nil
        themeCancellable?.cancel()
        themeCancellable = nil
        if let accessibilityActivationObserver {
            NotificationCenter.default.removeObserver(accessibilityActivationObserver)
        }
        accessibilityActivationObserver = nil
        visualIndex.clear()
        displayCache.removeAll()
        columnDisplayFormats = []
        cachedRowCount = 0
        cachedColumnCount = 0
        invalidateColumnIndexCache()
        valueFilteredIDs = nil
        // Local only: this runs while the window is being torn down, and the filter's owner is
        // either about to go away with it or is deliberately keeping the filter for the next mount.
        valueFilterBinding = nil
        adoptValueFilter(GridValueFilterState())
        lastUpdateSnapshot = nil
        columnPool.detachFromTableView()
        if let tableView {
            while let col = tableView.tableColumns.last {
                tableView.removeTableColumn(col)
            }
            tableView.reloadData()
        }
        delegate = nil
        dismissPopoversBoundToDisplayPositions()
        activeFKPreviewPopover?.close()
        clearFKPreviewState()
    }

    func updateCache() {
        let tableRows = tableRowsProvider()
        cachedRowCount = displayIDs?.count ?? tableRows.count
        cachedColumnCount = tableRows.columns.count
        /// A reload throws away the cells that were mounted, so the record of which rows carry one
        /// has to go with them or the next scroll decides there is nothing to remount.
        accessibilityMountedRows = NSRange(location: 0, length: 0)
        resizeRowNumberColumnForCurrentRange()
    }

    func resizeRowNumberColumnForCurrentRange() {
        guard let tableView,
              let column = tableView.tableColumns.first(where: {
                  $0.identifier == ColumnIdentitySchema.rowNumberIdentifier
              }),
              !column.isHidden else { return }
        let maxRowNumber = paginationOffsetProvider() + cachedRowCount
        DataGridView.sizeRowNumberColumn(column, forMaxRowNumber: maxRowNumber)
    }

    func applyInsertedRows(_ indices: IndexSet) {
        guard let tableView else { return }
        if valueFilterState.isActive {
            reloadAfterRowMutationWithValueFilter()
            return
        }
        visualIndex.rebuild(from: changeManager, displayIDs: displayIDs)
        updateCache()
        tableView.insertRows(at: indices, withAnimation: Self.rowAnimation(.slideDown))
    }

    /// Accessibility > Display > Reduce Motion asks for no sliding rows, and the app
    /// already honours it elsewhere.
    static func rowAnimation(_ preferred: NSTableView.AnimationOptions) -> NSTableView.AnimationOptions {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : preferred
    }

    func applyRemovedRows(_ indices: IndexSet) {
        guard let tableView else { return }
        if valueFilterState.isActive {
            reloadAfterRowMutationWithValueFilter()
            return
        }
        visualIndex.rebuild(from: changeManager, displayIDs: displayIDs)
        updateCache()
        tableView.removeRows(at: indices, withAnimation: Self.rowAnimation(.slideUp))
    }

    private func bumpDisplayRevision() {
        displayRevision &+= 1
        delegate?.dataGridDisplayOrderChanged()
    }

    /// Drops the row selection before a wholesale replacement.
    ///
    /// `reloadData()` leaves `selectedRowIndexes` alone when the new result happens to have as
    /// many rows as the old one, so without this the grid keeps highlighting positions that now
    /// hold different rows, and every consumer of the selection reads those stale positions.
    func clearRowSelection() {
        guard let tableView, !tableView.selectedRowIndexes.isEmpty else { return }
        tableView.deselectAll(nil)
    }

    func applyFullReplace() {
        dismissPopoversBoundToDisplayPositions()
        pruneStaleValueFilters()
        guard let tableView else { return }
        invalidateAllDisplayCaches()
        recomputeValueFilteredIDs()
        updateValueFilterHeaderIndicators()
        updateCache()
        selectionController.clear()
        tableView.reloadData()
        startBackgroundPrewarm()
    }

    private func reloadAfterRowMutationWithValueFilter() {
        guard let tableView else { return }
        recomputeValueFilteredIDs()
        updateCache()
        visualIndex.rebuild(from: changeManager, displayIDs: displayIDs)
        tableView.reloadData()
        startBackgroundPrewarm()
    }

    /// Selects and reveals the row a navigation asked this grid to land on.
    ///
    /// Pushed in when the rows land rather than polled from the update pass, the way
    /// `applyFindMatch(_:)` is. A miss is silent and final: the row may have been deleted, moved to
    /// another page, or hidden by a value filter, and none of those is worth telling the reader
    /// about when the view they asked for is otherwise back.
    func selectRow(matchingKey key: [String: String]) {
        guard let tableView else { return }
        let tableRows = tableRowsProvider()

        let keyColumns = key.compactMap { name, value in
            tableRows.columns.firstIndex(of: name).map { (column: $0, value: value) }
        }
        guard keyColumns.count == key.count else { return }

        guard let match = tableRows.rows.first(where: { row in
            keyColumns.allSatisfy { row[$0.column].asText == $0.value }
        }) else { return }

        guard let displayIndex = DisplayRowMapping.displayIndex(
            forRowID: match.id,
            displayIDs: displayIDs,
            in: tableRows
        ), displayIndex < tableView.numberOfRows else { return }

        selectRowsProgrammatically(IndexSet(integer: displayIndex), in: tableView)
        tableView.scrollRowToVisible(displayIndex)
    }

    /// A selection the app made, not the reader. The flag is what keeps the selection delegate from
    /// reading it back as a gesture.
    func selectRowsProgrammatically(_ indexes: IndexSet, in tableView: NSTableView) {
        isApplyingProgrammaticRowSelection = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        isApplyingProgrammaticRowSelection = false
    }

    func displayRow(at displayIndex: Int) -> Row? {
        displayRow(at: displayIndex, in: tableRowsProvider())
    }

    func displayRow(at displayIndex: Int, in tableRows: TableRows) -> Row? {
        DisplayRowMapping.row(forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows)
    }

    func tableRowsIndex(forDisplayRow displayIndex: Int) -> Int? {
        DisplayRowMapping.rowIndex(forDisplay: displayIndex, displayIDs: displayIDs, in: tableRowsProvider())
    }

    func displayValue(forID id: RowID, column: Int, rawValue: PluginCellValue, columnType: ColumnType?) -> String? {
        if let box = displayCache.box(forID: id),
           column >= 0, column < box.values.count,
           let cached = box.values[column] {
            return cached
        }
        let format = column >= 0 && column < columnDisplayFormats.count ? columnDisplayFormats[column] : nil
        let formatted = CellDisplayFormatter.format(
            rawValue,
            columnType: columnType,
            displayFormat: format,
            databaseType: databaseType
        ) ?? rawValue.asText

        let neededCount = max(column + 1, columnDisplayFormats.count, cachedColumnCount)
        let box: RowDisplayBox
        if let existing = displayCache.box(forID: id) {
            box = existing
            if box.values.count < neededCount {
                box.values.reserveCapacity(neededCount)
                for _ in box.values.count..<neededCount { box.values.append(nil) }
            }
        } else {
            var values = ContiguousArray<String?>()
            values.reserveCapacity(neededCount)
            for _ in 0..<neededCount { values.append(nil) }
            box = RowDisplayBox(values)
        }
        if column >= 0, column < box.values.count {
            box.values[column] = formatted
        }
        displayCache.setBox(box, forID: id)
        return formatted
    }

    func invalidateDisplayCache() {
        displayCache.removeAll()
    }

    func invalidateAllDisplayCaches() {
        displayCache.removeAll()
        visualIndex.rebuild(from: changeManager, displayIDs: displayIDs)
    }

    @discardableResult
    func updateDisplayFormats(_ formats: [ValueDisplayFormat?]) -> Bool {
        applyDisplayFormats(formats)
    }

    @discardableResult
    func syncDisplayFormats(_ formats: [ValueDisplayFormat?]) -> Bool {
        guard formats != columnDisplayFormats else { return false }
        return applyDisplayFormats(formats)
    }

    private func applyDisplayFormats(_ formats: [ValueDisplayFormat?]) -> Bool {
        let remappedValueFilters = remapValueFilters(from: columnDisplayFormats, to: formats)
        columnDisplayFormats = formats
        displayState.displayFormats = formats
        displayCache.removeAll()
        delegate?.dataGridDisplayFormatChanged()
        return remappedValueFilters
    }

    private func remapValueFilters(
        from oldFormats: [ValueDisplayFormat?],
        to newFormats: [ValueDisplayFormat?]
    ) -> Bool {
        let tableRows = tableRowsProvider()
        var didRemap = valueFilterState.prune(againstColumns: tableRows.columns)

        for column in valueFilterState.activeColumns {
            let oldFormat = oldFormats.indices.contains(column) ? oldFormats[column] : nil
            let newFormat = newFormats.indices.contains(column) ? newFormats[column] : nil
            guard oldFormat != newFormat,
                  let existing = valueFilterState.filter(forColumn: column),
                  tableRows.columns.indices.contains(column) else { continue }

            let columnType = tableRows.columnTypes.indices.contains(column)
                ? tableRows.columnTypes[column]
                : nil
            var oldValuesToRemove = Set<String>()
            var newValuesToInsert = Set<String>()
            for row in tableRows.rows where row.values.indices.contains(column) {
                let rawValue = row.values[column]
                guard rawValue != .null else { continue }
                let oldValue = filterValue(
                    rawValue,
                    columnType: columnType,
                    displayFormat: oldFormat
                )
                guard existing.selectedValues.contains(oldValue) else { continue }
                let newValue = filterValue(
                    rawValue,
                    columnType: columnType,
                    displayFormat: newFormat
                )
                if oldValue != newValue {
                    oldValuesToRemove.insert(oldValue)
                    newValuesToInsert.insert(newValue)
                }
            }

            var selectedValues = existing.selectedValues
            selectedValues.subtract(oldValuesToRemove)
            selectedValues.formUnion(newValuesToInsert)
            guard selectedValues != existing.selectedValues else { continue }

            valueFilterState.set(
                ColumnValueFilter(selectedValues: selectedValues, includesNull: existing.includesNull),
                columnName: tableRows.columns[column],
                forColumn: column
            )
            didRemap = true
        }
        return didRemap
    }

    private func filterValue(
        _ rawValue: PluginCellValue,
        columnType: ColumnType?,
        displayFormat: ValueDisplayFormat?
    ) -> String {
        CellDisplayFormatter.format(
            rawValue,
            columnType: columnType,
            displayFormat: displayFormat,
            databaseType: databaseType
        ) ?? rawValue.asText ?? ""
    }

    func reloadAfterDisplayFormatChange() {
        guard let tableView else { return }
        tableView.reloadData()
        startBackgroundPrewarm()
    }

    func cacheDisplayRow(at displayIndex: Int, in tableRows: TableRows) {
        guard let row = displayRow(at: displayIndex, in: tableRows) else { return }
        guard displayCache.box(forID: row.id) == nil else { return }

        let columnCount = tableRows.columns.count
        var values = ContiguousArray<String?>()
        values.reserveCapacity(columnCount)
        for _ in 0..<columnCount { values.append(nil) }
        for col in 0..<min(row.values.count, columnCount) {
            let columnType = col < tableRows.columnTypes.count ? tableRows.columnTypes[col] : nil
            let format = col < columnDisplayFormats.count ? columnDisplayFormats[col] : nil
            values[col] = CellDisplayFormatter.format(
                row.values[col],
                columnType: columnType,
                displayFormat: format,
                databaseType: databaseType
            ) ?? row.values[col].asText
        }
        let box = RowDisplayBox(values)
        displayCache.setBox(box, forID: row.id)
    }

    private func invalidateDisplayCache(forDisplayRow displayIndex: Int) {
        guard let row = displayRow(at: displayIndex) else { return }
        displayCache.clearValues(forID: row.id)
    }

    private func invalidateDisplayCache(forDisplayRow displayIndex: Int, column: Int) {
        guard let row = displayRow(at: displayIndex) else { return }
        guard let box = displayCache.box(forID: row.id),
              column >= 0, column < box.values.count else { return }
        box.values[column] = nil
        displayCache.setBox(box, forID: row.id)
    }

    func applyDelta(_ delta: Delta) {
        switch delta {
        case .cellChanged(let row, let column):
            guard let tableView,
                  let tableColumn = tableColumnIndex(for: column)
            else { return }
            guard row >= 0, row < tableView.numberOfRows else { return }
            invalidateDisplayCache(forDisplayRow: row, column: column)
            visualIndex.updateRow(row, from: changeManager, displayIDs: displayIDs)
            redrawCells(rows: IndexSet(integer: row), tableColumnIndexes: IndexSet(integer: tableColumn))
        case .cellsChanged(let positions):
            guard !positions.isEmpty, let tableView else { return }
            var rowSet = IndexSet()
            var colSet = IndexSet()
            for position in positions {
                if position.row >= 0, position.row < tableView.numberOfRows {
                    rowSet.insert(position.row)
                }
                if let tableColumn = tableColumnIndex(for: position.column) {
                    colSet.insert(tableColumn)
                }
                invalidateDisplayCache(forDisplayRow: position.row, column: position.column)
            }
            guard !rowSet.isEmpty, !colSet.isEmpty else { return }
            for row in rowSet {
                visualIndex.updateRow(row, from: changeManager, displayIDs: displayIDs)
            }
            redrawCells(rows: rowSet, tableColumnIndexes: colSet)
        case .rowsInserted(let indices):
            guard !indices.isEmpty else { return }
            overlayEditor?.dismiss(commit: false)
            overlayViewer?.dismiss()
            dismissPopoversBoundToDisplayPositions()
            applyInsertedRows(indices)
        case .rowsRemoved(let indices):
            guard !indices.isEmpty else { return }
            overlayEditor?.dismiss(commit: false)
            overlayViewer?.dismiss()
            dismissPopoversBoundToDisplayPositions()
            applyRemovedRows(indices)
        case .columnsReplaced, .fullReplace:
            overlayEditor?.dismiss(commit: false)
            overlayViewer?.dismiss()
            applyFullReplace()
        }
    }

    func invalidateCachesForUndoRedo() {
        invalidateAllDisplayCaches()
        updateCache()
        reloadVisibleRowsAndStates()
    }

    /// Repaints visible rows in the two layers a row needs: `repaintRows` covers the row-number
    /// column and the drawn cells, and `refreshVisibleRowVisualStates` then visits each live
    /// `NSTableRowView` so `applyVisualState` can carry the per-row decoration (deleted or inserted
    /// tint, deleted-row context menu state) without recreating a view. Both delegates call this
    /// after a model mutation that leaves the row count alone.
    func reloadVisibleRowsAndStates() {
        guard let tableView else { return }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        invalidateDisplayCache()
        repaintRows(IndexSet(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)))
        refreshVisibleRowVisualStates()
        startBackgroundPrewarm()
    }

    /// Single-row equivalent of `reloadVisibleRowsAndStates` for cases where
    /// only one row's content + visual state changed (cell edit, single-row
    /// undo delete).
    func reloadRowAndState(at row: Int) {
        guard let tableView, row >= 0, row < tableView.numberOfRows else { return }
        invalidateDisplayCache(forDisplayRow: row)
        repaintRows(IndexSet(integer: row))
        refreshRowVisualState(at: row)
    }

    func refreshVisibleRowVisualStates() {
        guard let tableView else { return }
        tableView.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self, let dataRowView = rowView as? DataGridRowView else { return }
            dataRowView.applyVisualState(self.visualState(for: row))
        }
    }

    func refreshRowVisualState(at row: Int) {
        guard let tableView,
              let dataRowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView
        else { return }
        dataRowView.applyVisualState(visualState(for: row))
    }

    func commitActiveCellEdit() {
        overlayEditor?.dismiss(commit: true)
        overlayViewer?.dismiss()
        guard let tableView, let window = tableView.window else { return }
        if let firstResponder = window.firstResponder as? NSView,
           firstResponder.isDescendant(of: tableView) {
            window.makeFirstResponder(tableView)
        }
    }

    @discardableResult
    internal func focusGrid() -> Bool {
        guard let tableView, let window = tableView.window else { return false }
        window.makeFirstResponder(tableView)
        return true
    }

    var selectedDisplayRow: Int? {
        guard let tableView, tableView.selectedRow >= 0 else { return nil }
        return tableView.selectedRow
    }

    func runFind(term: String) -> [FindMatch] {
        let tableRows = tableRowsProvider()
        let displayCount = displayIDs?.count ?? tableRows.count
        let columnTypes = tableRows.columnTypes
        let visible = visibleColumnDataIndices().map(Set.init)

        return FindMatcher.matches(
            term: term,
            displayRowCount: displayCount,
            columnCount: tableRows.columns.count,
            isColumnSearchable: { column in
                guard visible?.contains(column) ?? true else { return false }
                guard column < columnTypes.count else { return true }
                return FindMatcher.isSearchable(
                    columnTypes[column],
                    displayFormat: column < columnDisplayFormats.count ? columnDisplayFormats[column] : nil
                )
            },
            cellText: { [weak self] displayIndex, column in
                guard let self,
                      let row = displayRow(at: displayIndex, in: tableRows),
                      column < row.values.count
                else { return nil }
                let rawValue = row.values[column]
                let columnType = column < columnTypes.count ? columnTypes[column] : nil
                guard findSearches(rawValue, column: column, columnType: columnType) else { return nil }
                return displayValue(
                    forID: row.id,
                    column: column,
                    rawValue: rawValue,
                    columnType: columnType
                )
            }
        )
    }

    /// A binary cell is searched only where its column's format actually turned those bytes into
    /// characters. The format is chosen per column and the fallback to hex happens per value, so a
    /// column of readable text can still hold one cell whose hex Find must not match.
    private func findSearches(_ value: PluginCellValue, column: Int, columnType: ColumnType?) -> Bool {
        switch value {
        case .null:
            return false
        case .text:
            return true
        case .bytes(let data):
            guard let format = column < columnDisplayFormats.count ? columnDisplayFormats[column] : nil,
                  format.isApplicable(to: columnType, databaseType: databaseType) else { return false }
            return ValueDisplayFormatService.applyFormat(data, format: format, columnType: columnType) != nil
        }
    }

    func applyFindMatch(_ match: FindMatch?) {
        let previous = currentFindMatch
        guard previous != match else { return }
        currentFindMatch = match

        guard let tableView else { return }
        let affected = IndexSet([previous?.displayRow, match?.displayRow]
            .compactMap(\.self)
            .filter { $0 >= 0 && $0 < tableView.numberOfRows })
        repaintRows(affected)

        guard let match, match.displayRow >= 0, match.displayRow < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(match.displayRow)
        if let displayColumn = tableColumnIndex(for: match.columnIndex) {
            scrollColumnToVisible(tableColumnIndex: displayColumn)
        }
        tableView.selectRowIndexes(IndexSet(integer: match.displayRow), byExtendingSelection: false)
    }

    func beginEditing(displayRow: Int, column: Int) {
        guard let tableView,
              let displayCol = tableColumnIndex(for: column)
        else { return }
        guard displayRow >= 0, displayRow < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(displayRow)
        tableView.selectRowIndexes(IndexSet(integer: displayRow), byExtendingSelection: false)
        scrollColumnToVisible(tableColumnIndex: displayCol)
        beginCellEdit(row: displayRow, tableColumnIndex: displayCol)
    }

    /// Where the caret goes on a row the user just made. Column 0 is where the row starts, not
    /// necessarily where it can be typed into: a table whose first column the server owns, such as
    /// an identity or a stored generated column, refuses the edit and opens nothing at all, which
    /// reads as Add Row having done nothing. Falls back to column 0 so a row with no editable
    /// column at all is still selected and scrolled to.
    func beginEditingFirstEditableColumn(displayRow: Int) {
        let columnCount = tableRowsProvider().columns.count
        let column = (0..<columnCount).first { canStartInlineEdit(row: displayRow, columnIndex: $0) } ?? 0
        beginEditing(displayRow: displayRow, column: column)
    }

    func refreshCellPresentations() {
        guard let tableView else { return }
        guard overlayEditor?.isActive != true, overlayViewer?.isActive != true else {
            pendingCellPresentationRefresh = true
            return
        }
        pendingCellPresentationRefresh = false
        let tableRows = tableRowsProvider()
        rebuildKindSets(from: tableRows)
        let presentationChanges = updateColumnPresentations(from: tableRows)
        guard !presentationChanges.isEmpty else { return }

        applyAccessoryWidthChanges(presentationChanges, tableRows: tableRows)

        let changedTableColumnIndices = IndexSet(presentationChanges.indices.compactMap { dataIndex in
            guard let identifier = identitySchema.identifier(for: dataIndex) else { return nil }
            let tableColumnIndex = tableView.column(withIdentifier: identifier)
            return tableColumnIndex >= 0 ? tableColumnIndex : nil
        })
        guard !changedTableColumnIndices.isEmpty else { return }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        let visibleRows = IndexSet(
            integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)
        )
        redrawCells(rows: visibleRows, tableColumnIndexes: changedTableColumnIndices)
    }

    /// Repaints a set of drawn cells.
    ///
    /// `reloadData(forRowIndexes:columnIndexes:)` rebuilt a cell view per pair, which is how a
    /// mounted cell was refreshed. A data cell has no view now, so that call reaches nothing and the
    /// change never appears; the rows that draw the cells are asked instead.
    func redrawCells(rows: IndexSet, tableColumnIndexes: IndexSet) {
        guard let tableView else { return }
        for row in rows {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView else {
                continue
            }
            for tableColumnIndex in tableColumnIndexes {
                rowView.redrawCell(atTableColumnIndex: tableColumnIndex)
            }
        }
    }

    func flushPendingCellPresentationRefresh() {
        guard pendingCellPresentationRefresh else { return }
        refreshCellPresentations()
    }

    func scrollToTop() {
        guard let tableView, tableView.numberOfRows > 0 else { return }
        tableView.scrollRowToVisible(0)
    }

    @discardableResult
    func rebuildColumnMetadataCache(from tableRows: TableRows) -> Bool {
        let columns = tableRows.columns
        let nextSchema = ColumnIdentitySchema(columns: columns)
        let schemaChanged = nextSchema != identitySchema

        rebuildKindSets(from: tableRows)

        guard schemaChanged else { return false }
        identitySchema = nextSchema
        displayState.identitySchema = nextSchema
        displayCache.removeAll()
        invalidateColumnIndexCache()
        return true
    }

    func columnPresentation(
        for columnIndex: Int,
        in tableRows: TableRows
    ) -> DataGridColumnPresentation {
        let columnType = columnIndex < tableRows.columnTypes.count
            ? tableRows.columnTypes[columnIndex]
            : nil
        return DataGridColumnPresentation.resolve(
            columnType: columnType,
            isForeignKey: fkColumns.contains(columnIndex),
            isDropdown: dropdownColumns?.contains(columnIndex) == true,
            isTypePicker: typePickerColumns?.contains(columnIndex) == true,
            isEnumOrSet: enumOrSetColumns.contains(columnIndex),
            isEditable: isEditable
        )
    }

    @discardableResult
    func updateColumnPresentations(from tableRows: TableRows) -> DataGridColumnPresentationChanges {
        var next: [DataGridColumnPresentationIdentity: DataGridColumnPresentation] = [:]
        next.reserveCapacity(tableRows.columns.count)
        var changes = DataGridColumnPresentationChanges()
        var occurrences: [String: Int] = [:]

        for (index, name) in tableRows.columns.enumerated() {
            let occurrence = occurrences[name, default: 0]
            occurrences[name] = occurrence + 1
            let identity = DataGridColumnPresentationIdentity(name: name, occurrence: occurrence)
            let presentation = columnPresentation(for: index, in: tableRows)
            next[identity] = presentation
            if columnPresentations[identity] != presentation {
                changes.indices.insert(index)
            }
        }

        columnPresentations = next
        return changes
    }

    private func rebuildKindSets(from tableRows: TableRows) {
        var enumSet = Set<Int>()
        var fkSet = Set<Int>()
        let columns = tableRows.columns
        let types = tableRows.columnTypes
        let enumValues = tableRows.columnEnumValues
        let fkKeys = tableRows.columnForeignKeys

        for i in 0..<columns.count {
            let name = columns[i]
            let columnType = i < types.count ? types[i] : nil
            if columnType?.supportsElementEditing == true {
                enumSet.insert(i)
            } else if let values = enumValues[name], !values.isEmpty {
                let isExcluded = columnType?.isJsonType == true
                    || columnType?.isBlobType == true
                    || columnType?.isBooleanType == true
                if !isExcluded {
                    enumSet.insert(i)
                }
            }
            if fkKeys[name] != nil {
                fkSet.insert(i)
            }
        }
        enumOrSetColumns = enumSet
        if fkSet != fkColumns {
            fkTraceLogger.info(
                "[fk] grid columns=\(columns.count) fkColumns=\(fkSet.count) fkMeta=\(fkKeys.count)"
            )
        }
        fkColumns = fkSet
    }

    // MARK: - Row Visual State

    func visualState(for row: Int) -> RowVisualState {
        if let delegateState = delegate?.dataGridVisualState(forRow: row) {
            return delegateState
        }
        return visualIndex.visualState(for: row)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayIDs?.count ?? cachedRowCount
    }
}

// MARK: - DataGridCellAccessoryDelegate

extension TableViewCoordinator: DataGridCellAccessoryDelegate {
    func dataGridCellDidClickFKArrow(row: Int, columnIndex: Int, openInNewTab: Bool) {
        handleFKArrowAction(row: row, columnIndex: columnIndex, openInNewTab: openInNewTab)
    }

    func dataGridCellDidClickChevron(row: Int, columnIndex: Int) {
        handleChevronAction(row: row, columnIndex: columnIndex)
    }

    func dataGridCellDidDoubleClick(row: Int, columnIndex: Int) {
        guard row >= 0, columnIndex >= 0, let tableView else { return }
        guard let tableColumn = tableColumnIndex(for: columnIndex) else { return }
        handleCellInteraction(row: row, tableColumn: tableColumn, columnIndex: columnIndex, tableView: tableView)
    }
}
