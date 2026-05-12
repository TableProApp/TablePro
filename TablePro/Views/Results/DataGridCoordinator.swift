import AppKit
import Combine
import SwiftUI
import TableProPluginKit

// MARK: - Coordinator

@MainActor
final class TableViewCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
                                  NSMenuDelegate
{
    var tableRowsProvider: @MainActor () -> TableRows = { TableRows() }
    var tableRowsMutator: @MainActor (@MainActor (inout TableRows) -> Void) -> Void = { _ in }
    var changeManager: AnyChangeManager
    var isEditable: Bool
    var sortedIDs: [RowID]?
    private(set) var columnDisplayFormats: [ValueDisplayFormat?] = []
    private let displayCache = RowDisplayCache()
    weak var delegate: (any DataGridViewDelegate)?
    weak var activeFKPreviewPopover: NSPopover?
    var activeFKPreviewModel: FKPreviewModel?
    var activeFKPreviewColumnIndex: Int?
    var dropdownColumns: Set<Int>?
    var typePickerColumns: Set<Int>?
    var customDropdownOptions: [Int: [String]]?
    var connectionId: UUID?
    var databaseType: DatabaseType?
    var tableName: String?
    var primaryKeyColumns: [String] = []
    var primaryKeyColumn: String? { primaryKeyColumns.first }
    var tabType: TabType?
    var layoutPersister: any ColumnLayoutPersisting
    var onColumnLayoutDidChange: ((ColumnLayoutState) -> Void)?
    private(set) var identitySchema: ColumnIdentitySchema = .empty
    var currentSortState = SortState()

    func columnIdentifier(for dataIndex: Int) -> NSUserInterfaceItemIdentifier? {
        identitySchema.identifier(for: dataIndex)
    }

    func dataColumnIndex(from identifier: NSUserInterfaceItemIdentifier) -> Int? {
        identitySchema.dataIndex(from: identifier)
    }

    func savedColumnLayout(binding: ColumnLayoutState) -> ColumnLayoutState? {
        if tabType == .table,
           let connectionId,
           let tableName,
           !tableName.isEmpty,
           let stored = layoutPersister.load(for: tableName, connectionId: connectionId) {
            return stored
        }
        if binding.columnWidths.isEmpty && binding.columnOrder == nil {
            return nil
        }
        return binding
    }

    func captureColumnLayout() -> ColumnLayoutState? {
        guard let tableView else { return nil }
        let tableRows = tableRowsProvider()
        guard !tableRows.columns.isEmpty else { return nil }

        var widths: [String: CGFloat] = [:]
        var order: [String] = []
        for column in tableView.tableColumns
        where column.identifier != ColumnIdentitySchema.rowNumberIdentifier {
            guard let colIndex = dataColumnIndex(from: column.identifier),
                  colIndex < tableRows.columns.count else { continue }
            let name = tableRows.columns[colIndex]
            widths[name] = column.width
            order.append(name)
        }

        guard !widths.isEmpty else { return nil }
        var layout = ColumnLayoutState()
        layout.columnWidths = widths
        layout.columnOrder = order
        return layout
    }

    func persistColumnLayoutToStorage() {
        guard let layout = captureColumnLayout() else { return }
        onColumnLayoutDidChange?(layout)

        if tabType == .table, let connectionId, let tableName, !tableName.isEmpty {
            layoutPersister.save(layout, for: tableName, connectionId: connectionId)
        }
    }

    weak var tableView: NSTableView?
    let cellFactory = DataGridCellFactory()
    let cellRegistry: DataGridCellRegistry
    let columnPool = DataGridColumnPool()
    let tableRowsController = TableRowsController()
    var overlayEditor: CellOverlayEditor?

    var settingsCancellable: AnyCancellable?
    var themeCancellable: AnyCancellable?
    private var lastDataGridSettings: DataGridSettings

    @Binding var selectedRowIndices: Set<Int>

    private(set) var cachedRowCount: Int = 0
    private(set) var cachedColumnCount: Int = 0
    private(set) var enumOrSetColumns: Set<Int> = []
    private(set) var fkColumns: Set<Int> = []
    var isSyncingSelection = false
    var isRebuildingColumns: Bool = false
    var isEscapeCancelling = false
    var isCommittingCellEdit = false
    var layoutPersistTask: Task<Void, Never>?
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
                guard let self, let tableView = self.tableView else { return }
                let settings = AppSettingsManager.shared.dataGrid
                let prev = self.lastDataGridSettings
                self.lastDataGridSettings = settings

                let newRowHeight = CGFloat(settings.rowHeight.rawValue)
                if tableView.rowHeight != newRowHeight {
                    tableView.rowHeight = newRowHeight
                    tableView.tile()
                }

                let dataChanged = prev.dateFormat != settings.dateFormat
                    || prev.nullDisplay != settings.nullDisplay
                    || prev.enableSmartValueDetection != settings.enableSmartValueDetection

                if prev.enableSmartValueDetection != settings.enableSmartValueDetection
                    && !settings.enableSmartValueDetection {
                    self.updateDisplayFormats([])
                }

                if dataChanged {
                    self.invalidateDisplayCache()
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
        overlayEditor?.dismiss(commit: false)
        settingsCancellable?.cancel()
        settingsCancellable = nil
        themeCancellable?.cancel()
        themeCancellable = nil
        visualIndex.clear()
        displayCache.removeAll()
        columnDisplayFormats = []
        cachedRowCount = 0
        cachedColumnCount = 0
        sortedIDs = nil
        lastUpdateSnapshot = nil
        columnPool.detachFromTableView()
        if let tableView {
            while let col = tableView.tableColumns.last {
                tableView.removeTableColumn(col)
            }
            tableView.reloadData()
        }
        tableRowsController.detach()
        delegate = nil
        activeFKPreviewPopover?.close()
        clearFKPreviewState()
    }

    func updateCache() {
        let tableRows = tableRowsProvider()
        cachedRowCount = sortedIDs?.count ?? tableRows.count
        cachedColumnCount = tableRows.columns.count
    }

    func applyInsertedRows(_ indices: IndexSet) {
        guard let tableView else { return }
        visualIndex.rebuild(from: changeManager, sortedIDs: sortedIDs)
        updateCache()
        tableView.insertRows(at: indices, withAnimation: .slideDown)
    }

    func applyRemovedRows(_ indices: IndexSet) {
        guard let tableView else { return }
        visualIndex.rebuild(from: changeManager, sortedIDs: sortedIDs)
        updateCache()
        tableView.removeRows(at: indices, withAnimation: .slideUp)
    }

    func applyFullReplace() {
        guard let tableView else { return }
        invalidateAllDisplayCaches()
        updateCache()
        tableView.reloadData()
        startBackgroundPrewarm()
    }

    func displayRow(at displayIndex: Int) -> Row? {
        displayRow(at: displayIndex, in: tableRowsProvider())
    }

    func displayRow(at displayIndex: Int, in tableRows: TableRows) -> Row? {
        if let sorted = sortedIDs {
            guard displayIndex >= 0, displayIndex < sorted.count else { return nil }
            return tableRows.row(withID: sorted[displayIndex])
        }
        guard displayIndex >= 0, displayIndex < tableRows.count else { return nil }
        return tableRows.rows[displayIndex]
    }

    func tableRowsIndex(forDisplayRow displayIndex: Int) -> Int? {
        if let sorted = sortedIDs {
            guard displayIndex >= 0, displayIndex < sorted.count else { return nil }
            return tableRowsProvider().index(of: sorted[displayIndex])
        }
        let count = tableRowsProvider().count
        guard displayIndex >= 0, displayIndex < count else { return nil }
        return displayIndex
    }

    func displayValue(forID id: RowID, column: Int, rawValue: PluginCellValue, columnType: ColumnType?) -> String? {
        if let box = displayCache.box(forID: id),
           column >= 0, column < box.values.count,
           let cached = box.values[column] {
            return cached
        }
        let format = column >= 0 && column < columnDisplayFormats.count ? columnDisplayFormats[column] : nil
        let formatted = CellDisplayFormatter.format(rawValue, columnType: columnType, displayFormat: format) ?? rawValue.asText

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
        visualIndex.rebuild(from: changeManager, sortedIDs: sortedIDs)
    }

    func updateDisplayFormats(_ formats: [ValueDisplayFormat?]) {
        columnDisplayFormats = formats
        displayCache.removeAll()
    }

    func syncDisplayFormats(_ formats: [ValueDisplayFormat?]) {
        guard formats != columnDisplayFormats else { return }
        columnDisplayFormats = formats
        displayCache.removeAll()
    }

    func preWarmDisplayCache(upTo rowCount: Int) {
        let tableRows = tableRowsProvider()
        let displayCount = sortedIDs?.count ?? tableRows.count
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
        scrollObservers = [start, end]
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
            let displayCount = sortedIDs?.count ?? tableRows.count
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
                displayFormat: format
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
                  let tableColumn = DataGridView.tableColumnIndex(for: column, in: tableView, schema: identitySchema)
            else { return }
            guard row >= 0, row < tableView.numberOfRows else { return }
            invalidateDisplayCache(forDisplayRow: row, column: column)
            visualIndex.updateRow(row, from: changeManager, sortedIDs: sortedIDs)
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
                if let tableColumn = DataGridView.tableColumnIndex(
                    for: position.column,
                    in: tableView,
                    schema: identitySchema
                ) {
                    colSet.insert(tableColumn)
                }
                invalidateDisplayCache(forDisplayRow: position.row, column: position.column)
            }
            guard !rowSet.isEmpty, !colSet.isEmpty else { return }
            for row in rowSet {
                visualIndex.updateRow(row, from: changeManager, sortedIDs: sortedIDs)
            }
            tableView.reloadData(forRowIndexes: rowSet, columnIndexes: colSet)
        case .rowsInserted(let indices):
            guard !indices.isEmpty else { return }
            overlayEditor?.dismiss(commit: false)
            dismissFKPreviewOnColumnChange()
            appendInsertedIDsToSortedIDs(at: indices)
            applyInsertedRows(indices)
        case .rowsRemoved(let indices):
            guard !indices.isEmpty else { return }
            overlayEditor?.dismiss(commit: false)
            dismissFKPreviewOnColumnChange()
            removeMissingIDsFromSortedIDs()
            applyRemovedRows(indices)
        case .columnsReplaced, .fullReplace:
            overlayEditor?.dismiss(commit: false)
            dismissFKPreviewOnColumnChange()
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
        guard let tableView, let window = tableView.window else { return }
        if let firstResponder = window.firstResponder as? NSView,
           firstResponder.isDescendant(of: tableView) {
            window.makeFirstResponder(tableView)
        }
    }

    func beginEditing(displayRow: Int, column: Int) {
        guard let tableView,
              let displayCol = DataGridView.tableColumnIndex(for: column, in: tableView, schema: identitySchema)
        else { return }
        guard displayRow >= 0, displayRow < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(displayRow)
        tableView.selectRowIndexes(IndexSet(integer: displayRow), byExtendingSelection: false)
        beginCellEdit(row: displayRow, tableColumnIndex: displayCol)
    }

    func refreshForeignKeyColumns() {
        guard let tableView else { return }
        let tableRows = tableRowsProvider()
        let fkColumnIndices = IndexSet(
            tableView.tableColumns.enumerated().compactMap { displayIndex, tableColumn in
                guard tableColumn.identifier != ColumnIdentitySchema.rowNumberIdentifier,
                      let modelIndex = dataColumnIndex(from: tableColumn.identifier),
                      modelIndex < tableRows.columns.count else { return nil }
                let columnName = tableRows.columns[modelIndex]
                return tableRows.columnForeignKeys[columnName] != nil ? displayIndex : nil
            }
        )
        guard !fkColumnIndices.isEmpty else { return }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        let visibleRows = IndexSet(
            integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)
        )
        tableView.reloadData(forRowIndexes: visibleRows, columnIndexes: fkColumnIndices)
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
        return true
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
            if i < types.count {
                let ct = types[i]
                if (ct.isEnumType || ct.isSetType) && enumValues[name]?.isEmpty == false {
                    enumSet.insert(i)
                }
            }
            if fkKeys[name] != nil {
                fkSet.insert(i)
            }
        }
        enumOrSetColumns = enumSet
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
        sortedIDs?.count ?? tableRowsProvider().count
    }
}

// MARK: - DataGridCellAccessoryDelegate

extension TableViewCoordinator: DataGridCellAccessoryDelegate {
    func dataGridCellDidClickFKArrow(row: Int, columnIndex: Int) {
        handleFKArrowAction(row: row, columnIndex: columnIndex)
    }

    func dataGridCellDidClickChevron(row: Int, columnIndex: Int) {
        handleChevronAction(row: row, columnIndex: columnIndex)
    }
}
