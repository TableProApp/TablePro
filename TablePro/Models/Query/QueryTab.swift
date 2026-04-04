//
//  QueryTab.swift
//  TablePro
//
//  Model for query tabs
//

import Foundation
import Observation
import os
import TableProPluginKit

/// Type of tab
enum TabType: Equatable, Codable, Hashable {
    case query       // SQL editor tab
    case table       // Direct table view tab
    case createTable // Create new table tab
}

/// Minimal representation of a tab for persistence
struct PersistedTab: Codable {
    let id: UUID
    let title: String
    let query: String
    let tabType: TabType
    let tableName: String?
    var isView: Bool = false
    var databaseName: String = ""
    var schemaName: String?
    var sourceFileURL: URL?
}

/// Stores pending changes for a tab (used to preserve state when switching tabs)
struct TabPendingChanges: Equatable {
    var changes: [RowChange]
    var deletedRowIndices: Set<Int>
    var insertedRowIndices: Set<Int>
    var modifiedCells: [Int: Set<Int>]
    var insertedRowData: [Int: [String?]]  // Lazy storage for inserted row values
    var primaryKeyColumn: String?
    var columns: [String]

    init() {
        self.changes = []
        self.deletedRowIndices = []
        self.insertedRowIndices = []
        self.modifiedCells = [:]
        self.insertedRowData = [:]
        self.primaryKeyColumn = nil
        self.columns = []
    }

    var hasChanges: Bool {
        !changes.isEmpty || !insertedRowIndices.isEmpty || !deletedRowIndices.isEmpty
    }
}

/// Sort direction for column sorting
enum SortDirection: Equatable {
    case ascending
    case descending

    var indicator: String {
        switch self {
        case .ascending: return "▲"
        case .descending: return "▼"
        }
    }

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

/// A single column in a multi-column sort
struct SortColumn: Equatable {
    var columnIndex: Int
    var direction: SortDirection
}

/// Tracks sorting state for a table (supports multi-column sort)
struct SortState: Equatable {
    var columns: [SortColumn] = []

    init() {}

    var isSorting: Bool { !columns.isEmpty }

    // Backward-compatible computed properties for single-column access
    var columnIndex: Int? { columns.first?.columnIndex }
    var direction: SortDirection { columns.first?.direction ?? .ascending }
}

/// Tracks pagination state for navigating large datasets
struct PaginationState: Equatable {
    var totalRowCount: Int?         // Total rows in table (from COUNT(*))
    var pageSize: Int               // Rows per page (passed from manager/coordinator)
    var currentPage: Int = 1         // Current page number (1-based)
    var currentOffset: Int = 0       // Current OFFSET for SQL query
    var isLoading: Bool = false      // Loading indicator
    var isApproximateRowCount: Bool = false  // True when totalRowCount is from fast estimate

    /// Default page size constant (used when no explicit value is provided)
    /// Note: For new tabs, callers should pass AppSettingsManager.shared.dataGrid.defaultPageSize
    static let defaultPageSize = 1_000

    init(
        totalRowCount: Int? = nil,
        pageSize: Int = PaginationState.defaultPageSize,
        currentPage: Int = 1,
        currentOffset: Int = 0,
        isLoading: Bool = false
    ) {
        self.totalRowCount = totalRowCount
        self.pageSize = pageSize
        self.currentPage = currentPage
        self.currentOffset = currentOffset
        self.isLoading = isLoading
    }

    // MARK: - Computed Properties

    /// Total number of pages
    var totalPages: Int {
        guard let total = totalRowCount, total > 0 else { return 1 }
        return (total + pageSize - 1) / pageSize  // Ceiling division
    }

    /// Whether there is a next page available
    var hasNextPage: Bool {
        currentPage < totalPages
    }

    /// Whether there is a previous page available
    var hasPreviousPage: Bool {
        currentPage > 1
    }

    /// Starting row number for current page (1-based)
    var rangeStart: Int {
        currentOffset + 1
    }

    /// Ending row number for current page (1-based)
    var rangeEnd: Int {
        guard let total = totalRowCount else {
            return currentOffset + pageSize
        }
        return min(currentOffset + pageSize, total)
    }

    // MARK: - Navigation Methods

    /// Navigate to next page
    mutating func goToNextPage() {
        guard hasNextPage else { return }
        currentPage += 1
        currentOffset = (currentPage - 1) * pageSize
    }

    /// Navigate to previous page
    mutating func goToPreviousPage() {
        guard hasPreviousPage else { return }
        currentPage -= 1
        currentOffset = (currentPage - 1) * pageSize
    }

    /// Navigate to first page
    mutating func goToFirstPage() {
        currentPage = 1
        currentOffset = 0
    }

    /// Navigate to last page
    mutating func goToLastPage() {
        currentPage = totalPages
        currentOffset = (totalPages - 1) * pageSize
    }

    /// Navigate to specific page
    mutating func goToPage(_ page: Int) {
        guard page > 0 && page <= totalPages else { return }
        currentPage = page
        currentOffset = (page - 1) * pageSize
    }

    /// Reset pagination to first page
    mutating func reset() {
        currentPage = 1
        currentOffset = 0
        isLoading = false
    }

    /// Update page size (limit)
    mutating func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        pageSize = newSize
        // Recalculate current page based on current offset
        currentPage = (currentOffset / pageSize) + 1
    }

    /// Update offset directly and recalculate page
    mutating func updateOffset(_ newOffset: Int) {
        guard newOffset >= 0 else { return }
        currentOffset = newOffset
        currentPage = (currentOffset / pageSize) + 1
    }
}

/// Stores column layout (widths and order) within a tab session
struct ColumnLayoutState: Equatable {
    var columnWidths: [String: CGFloat] = [:]
    var columnOrder: [String]?
    var hiddenColumns: Set<String> = []
}

/// Reference-type wrapper for large result data.
/// When QueryTab (a struct) is copied via CoW, only this 8-byte reference is copied
/// instead of duplicating potentially large result arrays.
final class RowBuffer {
    var rows: [[String?]]
    var columns: [String]
    var columnTypes: [ColumnType]
    var columnDefaults: [String: String?]
    var columnForeignKeys: [String: ForeignKeyInfo]
    var columnEnumValues: [String: [String]]
    var columnNullable: [String: Bool]

    init(
        rows: [[String?]] = [],
        columns: [String] = [],
        columnTypes: [ColumnType] = [],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:]
    ) {
        self.rows = rows
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnDefaults = columnDefaults
        self.columnForeignKeys = columnForeignKeys
        self.columnEnumValues = columnEnumValues
        self.columnNullable = columnNullable
    }

    /// Create a deep copy of this buffer (used when explicit data duplication is needed)
    func copy() -> RowBuffer {
        RowBuffer(
            rows: rows,
            columns: columns,
            columnTypes: columnTypes,
            columnDefaults: columnDefaults,
            columnForeignKeys: columnForeignKeys,
            columnEnumValues: columnEnumValues,
            columnNullable: columnNullable
        )
    }

    /// Whether this buffer's row data has been evicted to save memory
    private(set) var isEvicted: Bool = false

    /// Evict row data to free memory. Column metadata is preserved.
    func evict() {
        guard !isEvicted else { return }
        rows = []
        isEvicted = true
    }

    /// Restore row data after eviction
    func restore(rows newRows: [[String?]]) {
        self.rows = newRows
        isEvicted = false
    }

    deinit {
        #if DEBUG
        Logger(subsystem: "com.TablePro", category: "RowBuffer")
            .debug("RowBuffer deallocated — columns: \(self.columns.count), evicted: \(self.isEvicted)")
        #endif
    }
}

/// Represents a single tab (query or table)
struct QueryTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var query: String
    var lastExecutedAt: Date?
    var tabType: TabType

    // Results — stored in a reference-type buffer to avoid CoW duplication
    // of large data when the struct is mutated (MEM-1 fix)
    var rowBuffer: RowBuffer

    // Backward-compatible computed accessors for result data
    var resultColumns: [String] {
        get { rowBuffer.columns }
        set { rowBuffer.columns = newValue }
    }

    var columnTypes: [ColumnType] {
        get { rowBuffer.columnTypes }
        set { rowBuffer.columnTypes = newValue }
    }

    var columnDefaults: [String: String?] {
        get { rowBuffer.columnDefaults }
        set { rowBuffer.columnDefaults = newValue }
    }

    var columnForeignKeys: [String: ForeignKeyInfo] {
        get { rowBuffer.columnForeignKeys }
        set { rowBuffer.columnForeignKeys = newValue }
    }

    var columnEnumValues: [String: [String]] {
        get { rowBuffer.columnEnumValues }
        set { rowBuffer.columnEnumValues = newValue }
    }

    var columnNullable: [String: Bool] {
        get { rowBuffer.columnNullable }
        set { rowBuffer.columnNullable = newValue }
    }

    var resultRows: [[String?]] {
        get { rowBuffer.rows }
        set { rowBuffer.rows = newValue }
    }

    var executionTime: TimeInterval?
    var statusMessage: String?
    var rowsAffected: Int  // Number of rows affected by non-SELECT queries
    var errorMessage: String?
    var isExecuting: Bool

    // Editing support
    var tableName: String?
    var primaryKeyColumn: String?  // Detected PK from schema (set by Phase 2 metadata)
    var isEditable: Bool
    var isView: Bool  // True for database views (read-only)
    var databaseName: String  // Database this tab was opened in (for multi-database restore)
    var schemaName: String?  // Schema this tab was opened in (for multi-schema restore, e.g. PostgreSQL)
    var showStructure: Bool  // Toggle to show structure view instead of data
    var explainText: String?
    var explainExecutionTime: TimeInterval?

    // Per-tab change tracking (preserves changes when switching tabs)
    var pendingChanges: TabPendingChanges

    // Per-tab row selection (preserves selection when switching tabs)
    var selectedRowIndices: Set<Int>

    // Per-tab sort state (column sorting)
    var sortState: SortState

    // Track if user has interacted with this tab (sort, edit, select, etc)
    // Prevents tab from being replaced when opening new tables
    var hasUserInteraction: Bool

    // Pagination state for lazy loading (table tabs only)
    var pagination: PaginationState

    // Per-tab filter state (preserves filters when switching tabs)
    var filterState: TabFilterState

    // Per-tab column layout (widths/order persist across reloads within tab session)
    var columnLayout: ColumnLayoutState

    // Whether this tab is a preview (temporary) tab that gets replaced on next navigation
    var isPreview: Bool

    // Multi-result-set support (Phase 0: added alongside existing single-result properties)
    var resultSets: [ResultSet] = []
    var activeResultSetId: UUID?
    var isResultsCollapsed: Bool = false

    var activeResultSet: ResultSet? {
        guard let id = activeResultSetId else { return resultSets.last }
        return resultSets.first { $0.id == id }
    }

    // Source file URL for .sql files opened from disk (used for deduplication)
    var sourceFileURL: URL?

    // Snapshot of file content at last save/load (nil for non-file tabs).
    // Used to detect unsaved changes via isFileDirty.
    var savedFileContent: String?

    // Version counter incremented when resultRows changes (used for sort caching)
    var resultVersion: Int

    // Version counter incremented when FK/metadata arrives (Phase 2), used to invalidate caches
    var metadataVersion: Int

    // Version counter incremented on pagination changes, used to scroll grid to top
    var paginationVersion: Int

    /// Whether the editor content differs from the last saved/loaded file content.
    /// Returns false for tabs not backed by a file.
    /// Uses O(1) length pre-check to avoid O(n) string comparison on every keystroke.
    var isFileDirty: Bool {
        guard sourceFileURL != nil, let saved = savedFileContent else { return false }
        let queryNS = query as NSString
        let savedNS = saved as NSString
        if queryNS.length != savedNS.length { return true }
        return queryNS != savedNS
    }

    init(
        id: UUID = UUID(),
        title: String = "Query",
        query: String = "",
        tabType: TabType = .query,
        tableName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.query = query
        self.tabType = tabType
        self.lastExecutedAt = nil
        self.rowBuffer = RowBuffer()
        self.executionTime = nil
        self.statusMessage = nil
        self.rowsAffected = 0
        self.errorMessage = nil
        self.isExecuting = false
        self.tableName = tableName
        self.primaryKeyColumn = nil
        self.isEditable = tabType == .table
        self.isView = false
        self.databaseName = ""
        self.schemaName = nil
        self.showStructure = false
        self.pendingChanges = TabPendingChanges()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.hasUserInteraction = false
        self.pagination = PaginationState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.isPreview = false
        self.sourceFileURL = nil
        self.resultVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
    }

    /// Initialize from persisted tab state (used when restoring tabs)
    init(from persisted: PersistedTab) {
        self.id = persisted.id
        self.title = persisted.title
        self.query = persisted.query
        self.tabType = persisted.tabType
        self.tableName = persisted.tableName
        self.primaryKeyColumn = nil

        // Initialize runtime state with defaults
        self.lastExecutedAt = nil
        self.rowBuffer = RowBuffer()
        self.executionTime = nil
        self.statusMessage = nil
        self.rowsAffected = 0
        self.errorMessage = nil
        self.isExecuting = false
        self.isEditable = persisted.tabType == .table && !persisted.isView
        self.isView = persisted.isView
        self.databaseName = persisted.databaseName
        self.schemaName = persisted.schemaName
        self.showStructure = false
        self.pendingChanges = TabPendingChanges()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.hasUserInteraction = false
        self.pagination = PaginationState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.isPreview = false
        self.sourceFileURL = persisted.sourceFileURL
        self.resultVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
    }

    /// Build a clean base query for a table tab (no filters/sort).
    /// Used when restoring table tabs from persistence to avoid stale WHERE clauses.
    @MainActor static func buildBaseTableQuery(
        tableName: String,
        databaseType: DatabaseType,
        schemaName: String? = nil,
        quoteIdentifier: ((String) -> String)? = nil
    ) -> String {
        let quote = quoteIdentifier ?? quoteIdentifierFromDialect(PluginManager.shared.sqlDialect(for: databaseType))
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize

        // Use plugin's query builder when available (NoSQL drivers like etcd, Redis)
        if let pluginDriver = PluginManager.shared.queryBuildingDriver(for: databaseType),
           let pluginQuery = pluginDriver.buildBrowseQuery(
               table: tableName, sortColumns: [], columns: [], limit: pageSize, offset: 0
           ) {
            return pluginQuery
        }

        switch PluginManager.shared.editorLanguage(for: databaseType) {
        case .javascript:
            let escaped = tableName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "db[\"\(escaped)\"].find({}).limit(\(pageSize))"
        case .bash:
            return "SCAN 0 MATCH * COUNT \(pageSize)"
        default:
            let qualifiedName: String
            if let schema = schemaName, !schema.isEmpty {
                qualifiedName = "\(quote(schema)).\(quote(tableName))"
            } else {
                qualifiedName = quote(tableName)
            }
            switch PluginManager.shared.paginationStyle(for: databaseType) {
            case .offsetFetch:
                let orderBy = PluginManager.shared.offsetFetchOrderBy(for: databaseType)
                return "SELECT * FROM \(qualifiedName) \(orderBy) OFFSET 0 ROWS FETCH NEXT \(pageSize) ROWS ONLY;"
            case .limit:
                return "SELECT * FROM \(qualifiedName) LIMIT \(pageSize);"
            }
        }
    }

    /// Maximum query size to persist (500KB). Queries larger than this are typically
    /// imported SQL dumps — serializing them to JSON blocks the main thread.
    static let maxPersistableQuerySize = 500_000

    /// Convert tab to persisted format for storage
    func toPersistedTab() -> PersistedTab {
        // Truncate very large queries to prevent JSON encoding from blocking main thread
        let persistedQuery: String
        if (query as NSString).length > Self.maxPersistableQuerySize {
            persistedQuery = ""
        } else {
            persistedQuery = query
        }

        return PersistedTab(
            id: id,
            title: title,
            query: persistedQuery,
            tabType: tabType,
            tableName: tableName,
            isView: isView,
            databaseName: databaseName,
            schemaName: schemaName,
            sourceFileURL: sourceFileURL
        )
    }

    static func == (lhs: QueryTab, rhs: QueryTab) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isExecuting == rhs.isExecuting
            && lhs.errorMessage == rhs.errorMessage
            && lhs.executionTime == rhs.executionTime
            && lhs.resultVersion == rhs.resultVersion
            && lhs.paginationVersion == rhs.paginationVersion
            && lhs.pagination == rhs.pagination
            && lhs.sortState == rhs.sortState
            && lhs.showStructure == rhs.showStructure
            && lhs.isEditable == rhs.isEditable
            && lhs.isView == rhs.isView
            && lhs.tabType == rhs.tabType
            && lhs.rowsAffected == rhs.rowsAffected
            && lhs.isPreview == rhs.isPreview
            && lhs.hasUserInteraction == rhs.hasUserInteraction
            && lhs.isResultsCollapsed == rhs.isResultsCollapsed
            && lhs.resultSets.map(\.id) == rhs.resultSets.map(\.id)
            && lhs.activeResultSetId == rhs.activeResultSetId
    }
}

/// Manager for query tabs
@MainActor @Observable
final class QueryTabManager {
    var tabs: [QueryTab] = [] {
        didSet { _tabIndexMapDirty = true }
    }

    var selectedTabId: UUID?

    @ObservationIgnored private var _tabIndexMap: [UUID: Int] = [:]
    @ObservationIgnored private var _tabIndexMapDirty = true

    private func rebuildTabIndexMapIfNeeded() {
        guard _tabIndexMapDirty else { return }
        _tabIndexMap = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        _tabIndexMapDirty = false
    }

    var tabIds: [UUID] { tabs.map(\.id) }

    var selectedTab: QueryTab? {
        if let index = selectedTabIndex { return tabs[index] }
        return selectedTabId == nil ? tabs.first : nil
    }

    var selectedTabIndex: Int? {
        guard let id = selectedTabId else { return nil }
        rebuildTabIndexMapIfNeeded()
        return _tabIndexMap[id]
    }

    init() {
        // Start with no tabs - shows empty state
        tabs = []
        selectedTabId = nil
    }

    // MARK: - Tab Management

    func addTab(initialQuery: String? = nil, title: String? = nil, databaseName: String = "", sourceFileURL: URL? = nil) {
        if let sourceFileURL,
           let existingIndex = tabs.firstIndex(where: { $0.sourceFileURL == sourceFileURL }) {
            if let query = initialQuery {
                tabs[existingIndex].query = query
            }
            selectedTabId = tabs[existingIndex].id
            return
        }

        let queryCount = tabs.count(where: { $0.tabType == .query })
        let tabTitle = title ?? "Query \(queryCount + 1)"
        var newTab = QueryTab(title: tabTitle, tabType: .query)

        if let query = initialQuery {
            newTab.query = query
            newTab.hasUserInteraction = true
        }

        newTab.databaseName = databaseName
        newTab.sourceFileURL = sourceFileURL
        if sourceFileURL != nil {
            newTab.savedFileContent = newTab.query
        }
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addTableTab(
        tableName: String,
        databaseType: DatabaseType = .mysql,
        databaseName: String = "",
        quoteIdentifier: ((String) -> String)? = nil
    ) {
        // Check if table tab already exists (match on databaseName)
        if let existingTab = tabs.first(where: {
            $0.tabType == .table && $0.tableName == tableName && $0.databaseName == databaseName
        }) {
            selectedTabId = existingTab.id
            return
        }

        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let query = QueryTab.buildBaseTableQuery(
            tableName: tableName, databaseType: databaseType, quoteIdentifier: quoteIdentifier
        )
        var newTab = QueryTab(
            title: tableName,
            query: query,
            tabType: .table,
            tableName: tableName
        )
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.databaseName = databaseName
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addCreateTableTab(databaseName: String = "") {
        let tabTitle = String(localized: "Create Table")
        var newTab = QueryTab(title: tabTitle, tabType: .createTable)
        newTab.databaseName = databaseName
        newTab.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addPreviewTableTab(
        tableName: String,
        databaseType: DatabaseType = .mysql,
        databaseName: String = "",
        quoteIdentifier: ((String) -> String)? = nil
    ) {
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let query = QueryTab.buildBaseTableQuery(
            tableName: tableName, databaseType: databaseType, quoteIdentifier: quoteIdentifier
        )
        var newTab = QueryTab(
            title: tableName,
            query: query,
            tabType: .table,
            tableName: tableName
        )
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.databaseName = databaseName
        newTab.isPreview = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    /// Replace the currently selected tab's content with a new table.
    /// - Returns: `true` if the replacement happened (caller should run the query),
    ///   `false` if there is no selected tab.
    @discardableResult
    func replaceTabContent(
        tableName: String, databaseType: DatabaseType = .mysql,
        isView: Bool = false, databaseName: String = "",
        schemaName: String? = nil, isPreview: Bool = false,
        quoteIdentifier: ((String) -> String)? = nil
    ) -> Bool {
        guard let selectedId = selectedTabId,
              let selectedIndex = tabs.firstIndex(where: { $0.id == selectedId })
        else {
            return false
        }

        let query = QueryTab.buildBaseTableQuery(
            tableName: tableName,
            databaseType: databaseType,
            schemaName: schemaName,
            quoteIdentifier: quoteIdentifier
        )
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize

        // Build locally and write back once to avoid 14 CoW copies (UI-11).
        var tab = tabs[selectedIndex]
        tab.rowBuffer = RowBuffer()
        tab.title = tableName
        tab.tableName = tableName
        tab.query = query
        tab.resultVersion += 1
        tab.executionTime = nil
        tab.statusMessage = nil
        tab.errorMessage = nil
        tab.lastExecutedAt = nil
        tab.showStructure = false
        tab.sortState = SortState()
        tab.selectedRowIndices = []
        tab.pendingChanges = TabPendingChanges()
        tab.hasUserInteraction = false
        tab.isView = isView
        tab.isEditable = !isView
        tab.filterState = TabFilterState()
        tab.columnLayout = ColumnLayoutState()
        tab.pagination = PaginationState(pageSize: pageSize)
        tab.databaseName = databaseName
        tab.schemaName = schemaName
        tab.isPreview = isPreview
        tabs[selectedIndex] = tab
        return true
    }

    func updateTab(_ tab: QueryTab) {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index] = tab
        }
    }

    deinit {
        #if DEBUG
        Logger(subsystem: "com.TablePro", category: "QueryTabManager")
            .debug("QueryTabManager deallocated")
        #endif
    }
}
