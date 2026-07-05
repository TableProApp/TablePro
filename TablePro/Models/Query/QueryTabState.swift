//
//  QueryTabState.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor @Observable
final class GridSelectionState {
    var indices: Set<Int> = []
}

/// Type of tab
enum TabType: Equatable, Codable, Hashable {
    case query
    case table
    case createTable
    case erDiagram
    case serverDashboard
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
    var erDiagramSchemaKey: String?
    var queryParameters: [QueryParameter]?
    var sortColumns: [PersistedSortColumn]?
    var restoredPage: Int?
    var cursorOffset: Int?
    var columnWidths: [String: CGFloat]?
    var windowGroupIndex: Int?

    init(
        id: UUID,
        title: String,
        query: String,
        tabType: TabType,
        tableName: String?,
        isView: Bool = false,
        databaseName: String = "",
        schemaName: String? = nil,
        sourceFileURL: URL? = nil,
        erDiagramSchemaKey: String? = nil,
        queryParameters: [QueryParameter]? = nil,
        sortColumns: [PersistedSortColumn]? = nil,
        restoredPage: Int? = nil,
        cursorOffset: Int? = nil,
        columnWidths: [String: CGFloat]? = nil,
        windowGroupIndex: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.query = query
        self.tabType = tabType
        self.tableName = tableName
        self.isView = isView
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.sourceFileURL = sourceFileURL
        self.erDiagramSchemaKey = erDiagramSchemaKey
        self.queryParameters = queryParameters
        self.sortColumns = sortColumns
        self.restoredPage = restoredPage
        self.cursorOffset = cursorOffset
        self.columnWidths = columnWidths
        self.windowGroupIndex = windowGroupIndex
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, query, tabType, tableName, isView, databaseName, schemaName
        case sourceFileURL, erDiagramSchemaKey, queryParameters
        case sortColumns, restoredPage, cursorOffset, columnWidths, windowGroupIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        tabType = try container.decode(TabType.self, forKey: .tabType)
        tableName = try container.decodeIfPresent(String.self, forKey: .tableName)
        isView = try container.decodeIfPresent(Bool.self, forKey: .isView) ?? false
        databaseName = try container.decodeIfPresent(String.self, forKey: .databaseName) ?? ""
        schemaName = try container.decodeIfPresent(String.self, forKey: .schemaName)
        sourceFileURL = try container.decodeIfPresent(URL.self, forKey: .sourceFileURL)
        erDiagramSchemaKey = try container.decodeIfPresent(String.self, forKey: .erDiagramSchemaKey)
        queryParameters = try container.decodeIfPresent([QueryParameter].self, forKey: .queryParameters)
        sortColumns = try container.decodeIfPresent([PersistedSortColumn].self, forKey: .sortColumns)
        restoredPage = try container.decodeIfPresent(Int.self, forKey: .restoredPage)
        cursorOffset = try container.decodeIfPresent(Int.self, forKey: .cursorOffset)
        columnWidths = try container.decodeIfPresent([String: CGFloat].self, forKey: .columnWidths)
        windowGroupIndex = try container.decodeIfPresent(Int.self, forKey: .windowGroupIndex)
    }
}

struct TabChangeSnapshot: Equatable {
    var changes: [RowChange]
    var deletedRowIndices: Set<Int>
    var insertedRowIndices: Set<Int>
    var modifiedCells: [Int: Set<Int>]
    var insertedRowData: [Int: [PluginCellValue]]
    var primaryKeyColumns: [String]
    var columns: [String]

    init() {
        self.changes = []
        self.deletedRowIndices = []
        self.insertedRowIndices = []
        self.modifiedCells = [:]
        self.insertedRowData = [:]
        self.primaryKeyColumns = []
        self.columns = []
    }

    var hasChanges: Bool {
        !changes.isEmpty || !insertedRowIndices.isEmpty || !deletedRowIndices.isEmpty
    }
}

enum SortDirection: String, Equatable, Codable {
    case ascending
    case descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

/// A single column in a multi-column sort
struct SortColumn: Equatable {
    var columnIndex: Int
    var direction: SortDirection
    var columnName: String?

    init(columnIndex: Int, direction: SortDirection, columnName: String? = nil) {
        self.columnIndex = columnIndex
        self.direction = direction
        self.columnName = columnName
    }
}

/// A sort column captured for cross-launch persistence, keyed by name so it survives column reordering
struct PersistedSortColumn: Codable, Equatable {
    let columnName: String
    let direction: SortDirection
}

enum SortSource: Equatable {
    case user
    case defaultSort
}

/// Tracks sorting state for a table (supports multi-column sort)
struct SortState: Equatable {
    var columns: [SortColumn] = []
    var source: SortSource = .user

    init(columns: [SortColumn] = [], source: SortSource = .user) {
        self.columns = columns
        self.source = source
    }

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
    var isLoading: Bool = false
    var isApproximateRowCount: Bool = false  // True when totalRowCount is from fast estimate

    // Result truncation state (query tabs)
    var hasMoreRows: Bool = false
    var isLoadingMore: Bool = false
    var baseQueryForMore: String?
    var baseQueryParameterValues: [String?]?
    var sortExecutionOverride: String?  // Derived ORDER BY query run for a grid sort; never written back to the editor

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

    var isLastPageKnown: Bool {
        totalRowCount != nil
    }

    func canGoToNextPage(loadedRowCount: Int) -> Bool {
        if hasNextPage { return true }
        return totalRowCount == nil && loadedRowCount >= pageSize
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

    private mutating func setPage(_ page: Int) {
        currentPage = page
        currentOffset = (page - 1) * pageSize
    }

    mutating func goToNextPage() {
        guard hasNextPage else { return }
        setPage(currentPage + 1)
    }

    mutating func goToNextPage(loadedRowCount: Int) {
        guard canGoToNextPage(loadedRowCount: loadedRowCount) else { return }
        setPage(currentPage + 1)
    }

    mutating func goToPreviousPage() {
        guard hasPreviousPage else { return }
        setPage(currentPage - 1)
    }

    mutating func goToFirstPage() {
        setPage(1)
    }

    mutating func goToLastPage() {
        setPage(totalPages)
    }

    mutating func goToPage(_ page: Int) {
        guard page > 0 && page <= totalPages else { return }
        setPage(page)
    }

    /// Reset pagination to first page
    mutating func reset() {
        currentPage = 1
        currentOffset = 0
        isLoading = false
    }

    /// Reset result truncation state
    mutating func resetLoadMore() {
        hasMoreRows = false
        isLoadingMore = false
        baseQueryForMore = nil
        baseQueryParameterValues = nil
        sortExecutionOverride = nil
    }

    /// Update page size (limit)
    mutating func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        pageSize = newSize
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

struct TabExecutionState: Equatable {
    var isExecuting: Bool = false
    var executionTime: TimeInterval?
    var statusMessage: String?
    var errorMessage: String?
    var rowsAffected: Int = 0
    var lastExecutedAt: Date?

    static func == (lhs: TabExecutionState, rhs: TabExecutionState) -> Bool {
        lhs.isExecuting == rhs.isExecuting
            && lhs.executionTime == rhs.executionTime
            && lhs.statusMessage == rhs.statusMessage
            && lhs.errorMessage == rhs.errorMessage
            && lhs.rowsAffected == rhs.rowsAffected
    }
}

struct TabTableContext: Equatable {
    var tableName: String?
    var databaseName: String = ""
    var schemaName: String?
    var primaryKeyColumns: [String] = []
    var isEditable: Bool = false
    var isView: Bool = false

    var primaryKeyColumn: String? { primaryKeyColumns.first }
}

struct TabQueryContent: Equatable {
    /// Holds the query text behind a reference. SwiftUI's attribute-graph diff compares a value by walking its memory
    /// layout, so a stored `String` field made it normalize the whole multi-megabyte query (NFC) on every view update.
    /// Storing the text in a class makes that walk compare an 8-byte pointer instead. Value semantics are preserved
    /// because the setter replaces the box.
    private final class QueryStorage: Sendable {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private var queryStorage: QueryStorage

    var query: String {
        get { queryStorage.text }
        set { queryStorage = QueryStorage(newValue) }
    }
    var queryParameters: [QueryParameter] = []
    var isParameterPanelVisible: Bool = false
    var sourceFileURL: URL?
    var savedFileContent: String?
    var loadMtime: Date?
    var externalModificationDetected: Bool = false

    static let maxPersistableQuerySize = 500_000

    init(
        query: String = "",
        queryParameters: [QueryParameter] = [],
        isParameterPanelVisible: Bool = false,
        sourceFileURL: URL? = nil,
        savedFileContent: String? = nil,
        loadMtime: Date? = nil,
        externalModificationDetected: Bool = false
    ) {
        self.queryStorage = QueryStorage(query)
        self.queryParameters = queryParameters
        self.isParameterPanelVisible = isParameterPanelVisible
        self.sourceFileURL = sourceFileURL
        self.savedFileContent = savedFileContent
        self.loadMtime = loadMtime
        self.externalModificationDetected = externalModificationDetected
    }

    var isFileDirty: Bool {
        guard sourceFileURL != nil, let saved = savedFileContent else { return false }
        let queryNS = query as NSString
        let savedNS = saved as NSString
        if queryNS.length != savedNS.length { return true }
        return queryNS != savedNS
    }

    static func == (lhs: TabQueryContent, rhs: TabQueryContent) -> Bool {
        // Cheap scalar fields short-circuit first. The query and saved-file text can be multiple megabytes and are
        // bridged from NSTextStorage, so they are compared last and with `sameText` to avoid Swift's canonical Unicode
        // comparison (O(n) on the bridged text); the same-box identity check makes an unchanged query O(1).
        lhs.isParameterPanelVisible == rhs.isParameterPanelVisible
            && lhs.externalModificationDetected == rhs.externalModificationDetected
            && lhs.sourceFileURL == rhs.sourceFileURL
            && lhs.loadMtime == rhs.loadMtime
            && lhs.queryParameters == rhs.queryParameters
            && (lhs.queryStorage === rhs.queryStorage || sameText(lhs.query, rhs.query))
            && sameText(lhs.savedFileContent, rhs.savedFileContent)
    }

    /// Literal text equality that skips Swift's canonical Unicode comparison, returning in O(1) when the lengths differ.
    private static func sameText(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return (lhs as NSString).isEqual(to: rhs)
        default:
            return false
        }
    }
}

struct TabDisplayState: Equatable {
    var resultsViewMode: ResultsViewMode = .data
    var erDiagramSchemaKey: String?
    var explainText: String?
    var explainExecutionTime: TimeInterval?
    var explainPlan: QueryPlan?
    var isResultsCollapsed: Bool = false
    var resultSets: [ResultSet] = []
    var activeResultSetId: UUID?

    var activeResultSet: ResultSet? {
        guard let id = activeResultSetId else { return resultSets.last }
        return resultSets.first { $0.id == id }
    }

    static func == (lhs: TabDisplayState, rhs: TabDisplayState) -> Bool {
        lhs.resultsViewMode == rhs.resultsViewMode
            && lhs.isResultsCollapsed == rhs.isResultsCollapsed
            && lhs.resultSets.map(\.id) == rhs.resultSets.map(\.id)
            && lhs.activeResultSetId == rhs.activeResultSetId
    }
}
