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
    var sortedIDs: [RowID]? { didSet { bumpDisplayRevision() } }
    var valueFilteredIDs: [RowID]? { didSet { bumpDisplayRevision() } }
    /// Ticks whenever the displayed row order or the value filter changes.
    ///
    /// `displayIDs` reaches SwiftUI only through weak, observation-ignored hops, so a filter change
    /// produces no signal on its own. Views that render the same rows outside the grid key off this
    /// instead of comparing the id array, which is O(rows) on every body evaluation.
    private(set) var displayRevision: Int = 0
    var valueFilterState = GridValueFilterState()
    var displayIDs: [RowID]? { valueFilteredIDs ?? sortedIDs }
    private(set) var columnDisplayFormats: [ValueDisplayFormat?] = []
    private(set) var currentFindMatch: FindMatch?
    private let displayCache = RowDisplayCache()
    weak var delegate: (any DataGridViewDelegate)?
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

    func savedColumnLayout(binding: ColumnLayoutState) -> ColumnLayoutState? {
        guard tabType == .table else {
            guard !binding.columnWidths.isEmpty || binding.columnContentWidths?.isEmpty == false else { return nil }
            var layout = binding
            layout.columnOrder = nil
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

    /// A saved width is the width the column had, accessory or not. Nothing here re-derives it from
    /// the accessory, because the accessory no longer contributes to column width: a layout saved
    /// while the arrow was showing and restored before it is known has to come back the same size.
    func resolvedColumnLayout(
        binding: ColumnLayoutState,
        liveWidths: [String: CGFloat]
    ) -> ColumnLayoutState? {
        let saved = savedColumnLayout(binding: binding)
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
    let selectionController = GridSelectionController()
    var overlayEditor: CellOverlayEditor?
    var overlayViewer: CellOverlayViewer?

    var settingsCancellable: AnyCancellable?
    var themeCancellable: AnyCancellable?
    private var lastDataGridSettings: DataGridSettings

    @Binding var selectedRowIndices: Set<Int>

    private(set) var cachedRowCount: Int = 0
    private(set) var cachedColumnCount: Int = 0
    private(set) var enumOrSetColumns: Set<Int> = []
    private(set) var fkColumns: Set<Int> = []
    private(set) var columnPresentations: [DataGridColumnPresentationIdentity: DataGridColumnPresentation] = [:]
    private(set) var userSizedColumnNames: Set<String> = []
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
    private var prewarmTask: Task<Void, Never>?
    private var prewarmResumeTask: Task<Void, Never>?
    private var scrollObservers: [NSObjectProtocol] = []
    private static let prewarmFrameBudget: Duration = .milliseconds(2)
    private static let prewarmResumeDelay: Duration = .milliseconds(300)

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
                tableView.reloadData(
                    forRowIndexes: IndexSet(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)),
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
            }
        }
    }

    func observeThemeChanges() {
        themeCancellable = AppEvents.shared.themeChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadVisibleRowsAndStates()
            }
    }

    func releaseData() {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        detachScrollObservers()
        selectionController.clear()
        overlayEditor?.dismiss(commit: false)
        overlayViewer?.dismiss()
        settingsCancellable?.cancel()
        settingsCancellable = nil
        themeCancellable?.cancel()
        themeCancellable = nil
        visualIndex.clear()
        displayCache.removeAll()
        columnDisplayFormats = []
        cachedRowCount = 0
        cachedColumnCount = 0
        invalidateColumnIndexCache()
        sortedIDs = nil
        valueFilteredIDs = nil
        valueFilterState.clearAll()
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
        visualIndex.rebuild(from: changeManager, sortedIDs: displayIDs)
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
        visualIndex.rebuild(from: changeManager, sortedIDs: displayIDs)
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
        visualIndex.rebuild(from: changeManager, sortedIDs: displayIDs)
        tableView.reloadData()
        startBackgroundPrewarm()
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
        displayCache.setBox(box, forID: id, cost: displayCacheCost(box.values))
        return formatted
    }

    func invalidateDisplayCache() {
        displayCache.removeAll()
    }

    func invalidateAllDisplayCaches() {
        displayCache.removeAll()
        visualIndex.rebuild(from: changeManager, sortedIDs: displayIDs)
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

    func preWarmDisplayCache(upTo rowCount: Int) {
        let tableRows = tableRowsProvider()
        let displayCount = displayIDs?.count ?? tableRows.count
        let count = min(rowCount, displayCount)
        guard count > 0 else { return }
        for displayIndex in 0..<count {
            cacheDisplayRow(at: displayIndex, in: tableRows)
        }
    }

    /// Fills displayCache off the scroll hot path so viewFor:row: stays a cache hit.
    func startBackgroundPrewarm() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        prewarmTask?.cancel()
        prewarmTask = Task { @MainActor [weak self] in
            await self?.runBackgroundPrewarm()
        }
    }

    /// Pauses prewarm during live scroll; resumes after a debounce so rapid scrolls do not restart it repeatedly.
    func attachScrollObservers(scrollView: NSScrollView) {
        detachScrollObservers()
        let start = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pausePrewarmForScroll()
            }
        }
        let end = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedulePrewarmResume()
            }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        let bounds = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateColumnWindow()
            }
        }
        // A bounds change is scrolling; a frame change is the viewport resizing. Widening the
        // window exposes area the window never covered, and only this fires for that.
        scrollView.contentView.postsFrameChangedNotifications = true
        let frame = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateColumnWindow()
            }
        }
        scrollObservers = [start, end, bounds, frame]
    }

    /// Re-mounts the columns the viewport can now reach. The resolver keeps the range stable while
    /// the viewport stays inside its margin, so most scroll frames return without touching a column.
    func updateColumnWindow() {
        guard let tableView, !isRebuildingColumns else { return }
        columnPool.applyColumnWindow(in: tableView)
    }

    private func detachScrollObservers() {
        for observer in scrollObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        scrollObservers.removeAll()
    }

    private func pausePrewarmForScroll() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    private func schedulePrewarmResume() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.prewarmResumeDelay)
            guard !Task.isCancelled, let self else { return }
            self.startBackgroundPrewarm()
        }
    }

    private func runBackgroundPrewarm() async {
        var nextIndex = 0
        while !Task.isCancelled {
            let tableRows = tableRowsProvider()
            let displayCount = displayIDs?.count ?? tableRows.count
            guard nextIndex < displayCount else { return }

            let deadline = ContinuousClock.now.advanced(by: Self.prewarmFrameBudget)
            while nextIndex < displayCount {
                if Task.isCancelled { return }
                cacheDisplayRow(at: nextIndex, in: tableRows)
                nextIndex += 1
                if ContinuousClock.now >= deadline { break }
            }
            await Task.yield()
        }
    }

    private func cacheDisplayRow(at displayIndex: Int, in tableRows: TableRows) {
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
        displayCache.setBox(box, forID: row.id, cost: displayCacheCost(values))
    }

    private func displayCacheCost(_ values: ContiguousArray<String?>) -> Int {
        var total = 0
        for value in values {
            if let s = value { total &+= s.utf8.count }
        }
        return total
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
        displayCache.setBox(box, forID: row.id, cost: displayCacheCost(box.values))
    }

    func applyDelta(_ delta: Delta) {
        switch delta {
        case .cellChanged(let row, let column):
            guard let tableView,
                  let tableColumn = tableColumnIndex(for: column)
            else { return }
            guard row >= 0, row < tableView.numberOfRows else { return }
            invalidateDisplayCache(forDisplayRow: row, column: column)
            visualIndex.updateRow(row, from: changeManager, sortedIDs: displayIDs)
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: tableColumn)
            )
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
                visualIndex.updateRow(row, from: changeManager, sortedIDs: displayIDs)
            }
            tableView.reloadData(forRowIndexes: rowSet, columnIndexes: colSet)
        case .rowsInserted(let indices):
            guard !indices.isEmpty else { return }
            overlayEditor?.dismiss(commit: false)
            overlayViewer?.dismiss()
            dismissPopoversBoundToDisplayPositions()
            appendInsertedIDsToSortedIDs(at: indices)
            applyInsertedRows(indices)
        case .rowsRemoved(let indices):
            guard !indices.isEmpty else { return }
            overlayEditor?.dismiss(commit: false)
            overlayViewer?.dismiss()
            dismissPopoversBoundToDisplayPositions()
            removeMissingIDsFromSortedIDs()
            applyRemovedRows(indices)
        case .columnsReplaced, .fullReplace:
            overlayEditor?.dismiss(commit: false)
            overlayViewer?.dismiss()
            sortedIDs = nil
            applyFullReplace()
        }
    }

    private func appendInsertedIDsToSortedIDs(at indices: IndexSet) {
        guard sortedIDs != nil else { return }
        let tableRows = tableRowsProvider()
        for index in indices where index >= 0 && index < tableRows.count {
            sortedIDs?.append(tableRows.rows[index].id)
        }
    }

    private func removeMissingIDsFromSortedIDs() {
        guard sortedIDs != nil else { return }
        let tableRows = tableRowsProvider()
        var survivingIDs = Set<RowID>()
        survivingIDs.reserveCapacity(tableRows.count)
        for row in tableRows.rows {
            survivingIDs.insert(row.id)
        }
        sortedIDs?.removeAll { !survivingIDs.contains($0) }
    }

    func invalidateCachesForUndoRedo() {
        invalidateAllDisplayCaches()
        updateCache()
        reloadVisibleRowsAndStates()
    }

    /// Repaint visible rows in two layers Apple's NSTableView contract requires:
    /// `reloadData(forRowIndexes:columnIndexes:)` re-fetches cells via
    /// `tableView(_:viewFor:row:)` but does not touch row views, so per-row
    /// decoration (deleted/inserted tint, deleted-row context menu state) goes
    /// stale. `enumerateAvailableRowViews` then visits each live `NSTableRowView`
    /// so `applyVisualState` can mutate row-level state without recreating views.
    /// Both delegates call this after model mutations that don't change row count.
    func reloadVisibleRowsAndStates() {
        guard let tableView else { return }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        invalidateDisplayCache()
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
        refreshVisibleRowVisualStates()
    }

    /// Single-row equivalent of `reloadVisibleRowsAndStates` for cases where
    /// only one row's content + visual state changed (cell edit, single-row
    /// undo delete).
    func reloadRowAndState(at row: Int) {
        guard let tableView, row >= 0, row < tableView.numberOfRows else { return }
        invalidateDisplayCache(forDisplayRow: row)
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
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
                return FindMatcher.isSearchable(columnTypes[column])
            },
            cellText: { [weak self] displayIndex, column in
                guard let self,
                      let row = displayRow(at: displayIndex, in: tableRows),
                      column < row.values.count
                else { return nil }
                let rawValue = row.values[column]
                guard rawValue.asText != nil else { return nil }
                return displayValue(
                    forID: row.id,
                    column: column,
                    rawValue: rawValue,
                    columnType: column < columnTypes.count ? columnTypes[column] : nil
                )
            }
        )
    }

    func applyFindMatch(_ match: FindMatch?) {
        let previous = currentFindMatch
        guard previous != match else { return }
        currentFindMatch = match

        guard let tableView else { return }
        let affected = IndexSet([previous?.displayRow, match?.displayRow]
            .compactMap(\.self)
            .filter { $0 >= 0 && $0 < tableView.numberOfRows })
        if !affected.isEmpty {
            tableView.reloadData(
                forRowIndexes: affected,
                columnIndexes: IndexSet(integersIn: 0 ..< tableView.numberOfColumns)
            )
        }

        guard let match, match.displayRow >= 0, match.displayRow < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(match.displayRow)
        if let displayColumn = tableColumnIndex(for: match.columnIndex),
           displayColumn < tableView.numberOfColumns {
            tableView.scrollColumnToVisible(displayColumn)
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
        beginCellEdit(row: displayRow, tableColumnIndex: displayCol)
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
        tableView.reloadData(forRowIndexes: visibleRows, columnIndexes: changedTableColumnIndices)
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
