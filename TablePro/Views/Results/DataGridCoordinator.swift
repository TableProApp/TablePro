import AppKit
import SwiftUI

// MARK: - Coordinator

@MainActor
final class TableViewCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
                                  NSControlTextEditingDelegate, NSTextFieldDelegate, NSMenuDelegate
{
    var tableRowsProvider: @MainActor () -> TableRows = { TableRows() }
    var tableRowsMutator: @MainActor (@MainActor (inout TableRows) -> Void) -> Void = { _ in }
    var changeManager: AnyChangeManager
    var isEditable: Bool
    var sortedIDs: [RowID]?
    private(set) var columnDisplayFormats: [ValueDisplayFormat?] = []
    private var displayCache: [RowID: [String?]] = [:]
    weak var delegate: (any DataGridViewDelegate)?
    weak var activeFKPreviewPopover: NSPopover?
    var dropdownColumns: Set<Int>?
    var typePickerColumns: Set<Int>?
    var customDropdownOptions: [Int: [String]]?
    var connectionId: UUID?
    var databaseType: DatabaseType?
    var tableName: String?
    var primaryKeyColumns: [String] = []
    var primaryKeyColumn: String? { primaryKeyColumns.first }
    var tabType: TabType?

    func persistColumnLayoutToStorage() {
        guard tabType == .table else { return }
        guard let tableView, let connectionId, let tableName, !tableName.isEmpty else { return }
        let tableRows = tableRowsProvider()
        guard !tableRows.columns.isEmpty else { return }

        var widths: [String: CGFloat] = [:]
        var order: [String] = []
        for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
            guard let colIndex = DataGridView.dataColumnIndex(from: column.identifier),
                  colIndex < tableRows.columns.count else { continue }
            let name = tableRows.columns[colIndex]
            widths[name] = column.width
            order.append(name)
        }

        guard !widths.isEmpty else { return }
        var layout = ColumnLayoutState()
        layout.columnWidths = widths
        layout.columnOrder = order
        ColumnLayoutStorage.shared.save(layout, for: tableName, connectionId: connectionId)
    }

    weak var tableView: NSTableView?
    let cellFactory = DataGridCellFactory()
    let tableRowsController = TableRowsController()
    var overlayEditor: CellOverlayEditor?

    var settingsObserver: NSObjectProtocol?
    var themeObserver: NSObjectProtocol?
    private var lastDataGridSettings: DataGridSettings

    @Binding var selectedRowIndices: Set<Int>

    var lastIdentity: DataGridIdentity?
    private(set) var cachedRowCount: Int = 0
    private(set) var cachedColumnCount: Int = 0
    private(set) var enumOrSetColumns: Set<Int> = []
    private(set) var fkColumns: Set<Int> = []
    var isSyncingSortDescriptors: Bool = false
    var isSyncingSelection = false
    var isRebuildingColumns: Bool = false
    var hasUserResizedColumns: Bool = false
    var isWritingColumnLayout: Bool = false
    var isEscapeCancelling = false
    var isCommittingCellEdit = false
    var layoutPersistTask: Task<Void, Never>?

    static let rowViewIdentifier = NSUserInterfaceItemIdentifier("TableRowView")
    internal var pendingDropdownRow: Int = 0
    internal var pendingDropdownColumn: Int = 0
    internal weak var pendingDropdownTableView: NSTableView?
    private var rowVisualStateCache: [Int: RowVisualState] = [:]
    private var lastVisualStateCacheVersion: Int = 0
    private let largeDatasetThreshold = 5_000

    var isLargeDataset: Bool { cachedRowCount > largeDatasetThreshold }

    init(
        changeManager: AnyChangeManager,
        isEditable: Bool,
        selectedRowIndices: Binding<Set<Int>>,
        delegate: (any DataGridViewDelegate)?
    ) {
        self.changeManager = changeManager
        self.isEditable = isEditable
        self._selectedRowIndices = selectedRowIndices
        self.delegate = delegate
        self.lastDataGridSettings = AppSettingsManager.shared.dataGrid
        super.init()
        updateCache()

        observeThemeChanges()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .dataGridSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor [weak self] in
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
    }

    func observeThemeChanges() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: .themeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                guard let self, let tableView = self.tableView else { return }
                Self.updateVisibleCellFonts(tableView: tableView)
            }
        }
    }

    func observeTeardown(connectionId: UUID) {
        teardownObserver = NotificationCenter.default.addObserver(
            forName: MainContentCoordinator.teardownNotification,
            object: connectionId,
            queue: .main
        ) { [weak self] _ in
            Task {
                self?.releaseData()
            }
        }
    }

    private func releaseData() {
        overlayEditor?.dismiss(commit: false)
        rowVisualStateCache.removeAll()
        displayCache.removeAll()
        columnDisplayFormats = []
        cachedRowCount = 0
        cachedColumnCount = 0
        sortedIDs = nil
        if let tableView {
            while let col = tableView.tableColumns.last {
                tableView.removeTableColumn(col)
            }
            tableView.reloadData()
        }
        tableRowsController.detach()
        delegate = nil
        activeFKPreviewPopover?.close()
        activeFKPreviewPopover = nil
    }

    private(set) var teardownObserver: NSObjectProtocol?

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = teardownObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func updateCache() {
        let tableRows = tableRowsProvider()
        cachedRowCount = sortedIDs?.count ?? tableRows.count
        cachedColumnCount = tableRows.columns.count
    }

    func applyInsertedRows(_ indices: IndexSet) {
        guard let tableView else { return }
        rebuildVisualStateCache()
        updateCache()
        tableView.insertRows(at: indices, withAnimation: .slideDown)
        lastIdentity = nil
    }

    func applyRemovedRows(_ indices: IndexSet) {
        guard let tableView else { return }
        rebuildVisualStateCache()
        updateCache()
        tableView.removeRows(at: indices, withAnimation: .slideUp)
        lastIdentity = nil
    }

    func applyFullReplace() {
        guard let tableView else { return }
        displayCache.removeAll()
        rebuildVisualStateCache()
        updateCache()
        tableView.reloadData()
        lastIdentity = nil
    }

    func displayRow(at displayIndex: Int) -> Row? {
        let tableRows = tableRowsProvider()
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

    func displayValue(forID id: RowID, column: Int, rawValue: String?, columnType: ColumnType?) -> String? {
        if let cachedRow = displayCache[id], column >= 0, column < cachedRow.count, let cached = cachedRow[column] {
            return cached
        }
        let format = column >= 0 && column < columnDisplayFormats.count ? columnDisplayFormats[column] : nil
        let formatted = CellDisplayFormatter.format(rawValue, columnType: columnType, displayFormat: format) ?? rawValue

        var rowCache = displayCache[id] ?? []
        let neededCount = max(column + 1, columnDisplayFormats.count)
        if rowCache.count < neededCount {
            rowCache.append(contentsOf: Array(repeating: nil, count: neededCount - rowCache.count))
        }
        if column >= 0, column < rowCache.count {
            rowCache[column] = formatted
        }
        displayCache[id] = rowCache
        return formatted
    }

    func invalidateDisplayCache() {
        displayCache.removeAll()
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
            guard let row = displayRow(at: displayIndex) else { continue }
            let id = row.id
            guard displayCache[id] == nil else { continue }
            let columnCount = tableRows.columns.count
            var rowCache = [String?](repeating: nil, count: columnCount)
            for col in 0..<min(row.values.count, columnCount) {
                let columnType = col < tableRows.columnTypes.count ? tableRows.columnTypes[col] : nil
                let format = col < columnDisplayFormats.count ? columnDisplayFormats[col] : nil
                rowCache[col] = CellDisplayFormatter.format(
                    row.values[col],
                    columnType: columnType,
                    displayFormat: format
                ) ?? row.values[col]
            }
            displayCache[id] = rowCache
        }
    }

    private func pruneDisplayCacheToAliveIDs() {
        guard !displayCache.isEmpty else { return }
        let tableRows = tableRowsProvider()
        var aliveIDs = Set<RowID>()
        aliveIDs.reserveCapacity(tableRows.count)
        for row in tableRows.rows {
            aliveIDs.insert(row.id)
        }
        displayCache = displayCache.filter { aliveIDs.contains($0.key) }
    }

    private func invalidateDisplayCache(forDisplayRow displayIndex: Int, column: Int) {
        guard let row = displayRow(at: displayIndex) else { return }
        guard var rowCache = displayCache[row.id], column >= 0, column < rowCache.count else { return }
        rowCache[column] = nil
        displayCache[row.id] = rowCache
    }

    func applyDelta(_ delta: Delta) {
        switch delta {
        case .cellChanged(let row, let column):
            guard let tableView else { return }
            let tableColumn = DataGridView.tableColumnIndex(for: column)
            guard row >= 0, row < tableView.numberOfRows else { return }
            guard tableColumn >= 0, tableColumn < tableView.numberOfColumns else { return }
            invalidateDisplayCache(forDisplayRow: row, column: column)
            rebuildVisualStateCache()
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
                let tableColumn = DataGridView.tableColumnIndex(for: position.column)
                if tableColumn >= 0, tableColumn < tableView.numberOfColumns {
                    colSet.insert(tableColumn)
                }
                invalidateDisplayCache(forDisplayRow: position.row, column: position.column)
            }
            guard !rowSet.isEmpty, !colSet.isEmpty else { return }
            rebuildVisualStateCache()
            tableView.reloadData(forRowIndexes: rowSet, columnIndexes: colSet)
        case .rowsInserted(let indices):
            guard !indices.isEmpty else { return }
            appendInsertedIDsToSortedIDs(at: indices)
            applyInsertedRows(indices)
        case .rowsRemoved(let indices):
            guard !indices.isEmpty else { return }
            removeMissingIDsFromSortedIDs()
            pruneDisplayCacheToAliveIDs()
            applyRemovedRows(indices)
        case .columnsReplaced, .fullReplace:
            sortedIDs = nil
            displayCache.removeAll()
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
        displayCache.removeAll()
        rebuildVisualStateCache()
        updateCache()
    }

    func commitActiveCellEdit() {
        guard let tableView, let window = tableView.window else { return }
        if tableView.editedRow >= 0 {
            window.makeFirstResponder(tableView)
            return
        }
        if let firstResponder = window.firstResponder as? NSView,
           firstResponder.isDescendant(of: tableView) {
            window.makeFirstResponder(tableView)
        }
    }

    func beginEditing(displayRow: Int, column: Int) {
        guard let tableView else { return }
        let displayCol = DataGridView.tableColumnIndex(for: column)
        guard displayRow >= 0, displayRow < tableView.numberOfRows,
              displayCol >= 0, displayCol < tableView.numberOfColumns else { return }
        tableView.scrollRowToVisible(displayRow)
        tableView.selectRowIndexes(IndexSet(integer: displayRow), byExtendingSelection: false)
        tableView.editColumn(displayCol, row: displayRow, with: nil, select: true)
    }

    func rebuildColumnMetadataCache(from tableRows: TableRows) {
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

    // MARK: - Font Updates

    @MainActor
    static func updateVisibleCellFonts(tableView: NSTableView) {
        let visibleRect = tableView.visibleRect
        let visibleRange = tableView.rows(in: visibleRect)
        guard visibleRange.length > 0 else { return }

        let columnCount = tableView.numberOfColumns
        for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
            for col in 0..<columnCount {
                guard let cellView = tableView.view(atColumn: col, row: row, makeIfNecessary: false) as? NSTableCellView,
                      let textField = cellView.textField else { continue }

                switch textField.tag {
                case DataGridFontVariant.rowNumber:
                    textField.font = ThemeEngine.shared.dataGridFonts.rowNumber
                case DataGridFontVariant.italic:
                    textField.font = ThemeEngine.shared.dataGridFonts.italic
                case DataGridFontVariant.medium:
                    textField.font = ThemeEngine.shared.dataGridFonts.medium
                default:
                    textField.font = ThemeEngine.shared.dataGridFonts.regular
                }
            }
        }
    }

    // MARK: - Row Visual State Cache

    @MainActor
    func rebuildVisualStateCache() {
        let currentVersion = changeManager.reloadVersion
        guard currentVersion != lastVisualStateCacheVersion else { return }
        lastVisualStateCacheVersion = currentVersion

        rowVisualStateCache.removeAll(keepingCapacity: true)

        var insertedRowIndices: Set<Int>
        if let sorted = sortedIDs {
            insertedRowIndices = Set()
            for (displayIndex, id) in sorted.enumerated() where id.isInserted {
                insertedRowIndices.insert(displayIndex)
            }
        } else {
            insertedRowIndices = changeManager.insertedRowIndices
        }

        if !changeManager.hasChanges && insertedRowIndices.isEmpty {
            return
        }

        for rowChange in changeManager.rowChanges {
            let rowIndex = rowChange.rowIndex
            let isDeleted = rowChange.type == .delete
            let isInserted = insertedRowIndices.contains(rowIndex) || rowChange.type == .insert
            let modifiedColumns: Set<Int> = rowChange.type == .update
                ? Set(rowChange.cellChanges.map { $0.columnIndex })
                : []

            rowVisualStateCache[rowIndex] = RowVisualState(
                isDeleted: isDeleted,
                isInserted: isInserted,
                modifiedColumns: modifiedColumns
            )
        }

        for rowIndex in insertedRowIndices where rowVisualStateCache[rowIndex] == nil {
            rowVisualStateCache[rowIndex] = RowVisualState(
                isDeleted: false,
                isInserted: true,
                modifiedColumns: []
            )
        }
    }

    func visualState(for row: Int) -> RowVisualState {
        if let delegateState = delegate?.dataGridVisualState(forRow: row) {
            return delegateState
        }
        return rowVisualStateCache[row] ?? .empty
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedIDs?.count ?? tableRowsProvider().count
    }
}
