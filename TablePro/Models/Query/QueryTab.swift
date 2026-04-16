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
    var primaryKeyColumns: [String] = []  // Detected PKs from schema (set by Phase 2 metadata)
    /// First PK column, for UI contexts that need a single column (filters, ORDER BY)
    var primaryKeyColumn: String? { primaryKeyColumns.first }
    var isEditable: Bool
    var isView: Bool  // True for database views (read-only)
    var databaseName: String  // Database this tab was opened in (for multi-database restore)
    var schemaName: String?  // Schema this tab was opened in (for multi-schema restore, e.g. PostgreSQL)
    var showStructure: Bool  // Toggle to show structure view instead of data
    var erDiagramSchemaKey: String?
    var explainText: String?
    var explainExecutionTime: TimeInterval?
    var explainPlan: QueryPlan?

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

    // Whether this tab is pinned (cannot be closed, always at left)
    var isPinned: Bool

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

    /// Composite version for NSHostingView rootView rebuild decisions.
    /// Includes all state that affects visual content.
    var contentVersion: Int {
        // Use prime multipliers to avoid hash collisions between states.
        // Previous formula used simple addition, causing collisions like:
        // isExecuting(+2) == resultVersion(1) + metadataVersion(1)
        var v = resultVersion &* 97 &+ metadataVersion &* 31 &+ paginationVersion &* 13
        if errorMessage != nil { v = v &+ 7 }
        if isExecuting { v = v &+ 3 }
        return v
    }

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
        self.primaryKeyColumns = []
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
        self.isPinned = false
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
        self.primaryKeyColumns = []

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
        self.erDiagramSchemaKey = persisted.erDiagramSchemaKey
        self.pendingChanges = TabPendingChanges()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.hasUserInteraction = false
        self.pagination = PaginationState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.isPreview = false
        self.isPinned = persisted.isPinned
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
            sourceFileURL: sourceFileURL,
            erDiagramSchemaKey: erDiagramSchemaKey
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
