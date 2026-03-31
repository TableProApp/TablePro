//
//  DataGridCoordinator.swift
//  TablePro
//
//  Coordinator handling NSTableView delegate and data source for DataGridView.
//

import AppKit
import SwiftUI

// MARK: - Coordinator

/// Coordinator handling NSTableView delegate and data source
@MainActor
final class TableViewCoordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
                                  NSControlTextEditingDelegate, NSTextFieldDelegate, NSMenuDelegate
{
    var rowProvider: InMemoryRowProvider
    var changeManager: AnyChangeManager
    var isEditable: Bool
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
    var onHideColumn: ((String) -> Void)?
    var onMoveRow: ((Int, Int) -> Void)?
    var onNavigateFK: ((String, ForeignKeyInfo) -> Void)?
    var getVisualState: ((Int) -> RowVisualState)?
    var dropdownColumns: Set<Int>?
    var typePickerColumns: Set<Int>?
    var connectionId: UUID?
    var databaseType: DatabaseType?
    var tableName: String?
    var primaryKeyColumn: String?
    var tabType: TabType?

    /// Check if undo is available
    func canUndo() -> Bool {
        changeManager.hasChanges
    }

    /// Check if redo is available
    func canRedo() -> Bool {
        changeManager.canRedo
    }

    /// Capture current column widths and order from the live NSTableView
    /// and persist directly to ColumnLayoutStorage. Called from dismantleNSView
    /// to guarantee layout is saved even when the view is torn down without
    /// a SwiftUI render cycle (e.g., closing a tab).
    func persistColumnLayoutToStorage() {
        guard tabType == .table else { return }
        guard let tableView, let connectionId, let tableName, !tableName.isEmpty else { return }
        guard !rowProvider.columns.isEmpty else { return }

        var widths: [String: CGFloat] = [:]
        var order: [String] = []
        for column in tableView.tableColumns where column.identifier.rawValue != "__rowNumber__" {
            guard let colIndex = DataGridView.columnIndex(from: column.identifier),
                  colIndex < rowProvider.columns.count else { continue }
            let name = rowProvider.columns[colIndex]
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
    var overlayEditor: CellOverlayEditor?

    // Settings observer for real-time updates
    var settingsObserver: NSObjectProtocol?
    // Theme observer for font/color changes
    var themeObserver: NSObjectProtocol?
    /// Snapshot of last-seen data grid settings for change detection
    private var lastDataGridSettings: DataGridSettings

    @Binding var selectedRowIndices: Set<Int>

    var lastIdentity: DataGridIdentity?
    var lastReloadVersion: Int = 0
    var lastReapplyVersion: Int = -1
    private(set) var cachedRowCount: Int = 0
    private(set) var cachedColumnCount: Int = 0
    private(set) var enumOrSetColumns: Set<Int> = []
    private(set) var fkColumns: Set<Int> = []
    var isSyncingSortDescriptors: Bool = false
    /// Suppresses selection delegate callbacks during programmatic selection sync
    var isSyncingSelection = false
    var isRebuildingColumns: Bool = false
    var hasUserResizedColumns: Bool = false
    /// Guards against two-frame bounce when async column layout write-back triggers updateNSView
    var isWritingColumnLayout: Bool = false
    /// Debounced work item for persisting column layout after resize/reorder
    var layoutPersistWorkItem: DispatchWorkItem?

    private let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")
    static let rowViewIdentifier = NSUserInterfaceItemIdentifier("TableRowView")
    internal var pendingDropdownRow: Int = 0
    internal var pendingDropdownColumn: Int = 0
    private var rowVisualStateCache: [Int: RowVisualState] = [:]
    private var lastVisualStateCacheVersion: Int = 0
    private let largeDatasetThreshold = 5_000

    var isLargeDataset: Bool { cachedRowCount > largeDatasetThreshold }

    init(
        rowProvider: InMemoryRowProvider,
        changeManager: AnyChangeManager,
        isEditable: Bool,
        selectedRowIndices: Binding<Set<Int>>,
        onRefresh: (() -> Void)?,
        onCellEdit: ((Int, Int, String?) -> Void)?,
        onDeleteRows: ((Set<Int>) -> Void)?,
        onCopyRows: ((Set<Int>) -> Void)?,
        onPasteRows: (() -> Void)?,
        onUndo: (() -> Void)?,
        onRedo: (() -> Void)?
    ) {
        self.rowProvider = rowProvider
        self.changeManager = changeManager
        self.isEditable = isEditable
        self._selectedRowIndices = selectedRowIndices
        self.onRefresh = onRefresh
        self.onCellEdit = onCellEdit
        self.onDeleteRows = onDeleteRows
        self.onCopyRows = onCopyRows
        self.onPasteRows = onPasteRows
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.lastDataGridSettings = AppSettingsManager.shared.dataGrid
        super.init()
        updateCache()

        // Subscribe to theme changes for font/color updates
        observeThemeChanges()

        // Subscribe to settings changes for real-time updates
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

                // Font changes are handled by .themeDidChange observer.
                // Check for data format changes that need cell re-rendering.
                let dataChanged = prev.dateFormat != settings.dateFormat
                    || prev.nullDisplay != settings.nullDisplay

                if dataChanged {
                    self.rowProvider.invalidateDisplayCache()
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
            MainActor.assumeIsolated {
                guard let self, let tableView = self.tableView else { return }
                Self.updateVisibleCellFonts(tableView: tableView)
            }
        }
    }

    /// Subscribe to coordinator teardown to release NSTableView cell views.
    func observeTeardown(connectionId: UUID) {
        teardownObserver = NotificationCenter.default.addObserver(
            forName: MainContentCoordinator.teardownNotification,
            object: connectionId,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseData()
            }
        }
    }

    /// Release all data and cell views from the NSTableView.
    /// Called during coordinator teardown to free memory while SwiftUI holds the view.
    private func releaseData() {
        overlayEditor?.dismiss(commit: false)
        rowProvider = InMemoryRowProvider(rows: [], columns: [])
        rowVisualStateCache.removeAll()
        cachedRowCount = 0
        cachedColumnCount = 0
        // Remove columns and reload to release cell views
        if let tableView {
            while let col = tableView.tableColumns.last {
                tableView.removeTableColumn(col)
            }
            tableView.reloadData()
        }
        // Release closures
        onRefresh = nil
        onCellEdit = nil
        onDeleteRows = nil
        onCopyRows = nil
        onPasteRows = nil
        onUndo = nil
        onRedo = nil
        onSort = nil
        onAddRow = nil
        onUndoInsert = nil
        onFilterColumn = nil
        onHideColumn = nil
        onNavigateFK = nil
        getVisualState = nil
    }

    private var teardownObserver: NSObjectProtocol?

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
        cachedRowCount = rowProvider.totalRowCount
        cachedColumnCount = rowProvider.columns.count
    }

    func rebuildColumnMetadataCache() {
        var enumSet = Set<Int>()
        var fkSet = Set<Int>()
        let columns = rowProvider.columns
        let types = rowProvider.columnTypes
        let enumValues = rowProvider.columnEnumValues
        let fkKeys = rowProvider.columnForeignKeys

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

    /// Update fonts on existing visible cell views in-place.
    /// Uses `DataGridFontVariant` tags set during cell configuration
    /// to apply the correct font variant without inspecting cell content.
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

        // If custom getVisualState provided, don't build cache (use callback instead)
        if getVisualState != nil {
            return
        }

        // Always clear cache, then rebuild if there are changes
        // This ensures deleted state is cleared when changeManager.clearChanges() is called
        guard changeManager.hasChanges else {
            // No changes → cache is now empty (cleared above)
            return
        }

        for change in changeManager.changes {
            guard let rowChange = change as? RowChange else { continue }
            let rowIndex = rowChange.rowIndex
            let isDeleted = rowChange.type == .delete
            let isInserted = rowChange.type == .insert
            let modifiedColumns: Set<Int> = rowChange.type == .update
                ? Set(rowChange.cellChanges.map { $0.columnIndex })
                : []

            rowVisualStateCache[rowIndex] = RowVisualState(
                isDeleted: isDeleted,
                isInserted: isInserted,
                modifiedColumns: modifiedColumns
            )
        }
    }

    func visualState(for row: Int) -> RowVisualState {
        // If custom callback provided, use it
        if let callback = getVisualState {
            return callback(row)
        }
        // Otherwise use cache
        return rowVisualStateCache[row] ?? .empty
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        cachedRowCount
    }
}
