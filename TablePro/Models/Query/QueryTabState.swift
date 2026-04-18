//
//  QueryTabState.swift
//  TablePro
//

import Foundation

/// Type of tab
enum TabType: Equatable, Codable, Hashable {
    case query            // SQL editor tab
    case table            // Direct table view tab
    case createTable      // Create new table tab
    case erDiagram        // ER diagram tab
    case serverDashboard  // Server dashboard tab
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
}

/// Stores pending changes for a tab (used to preserve state when switching tabs)
struct TabPendingChanges: Equatable {
    var changes: [RowChange]
    var deletedRowIndices: Set<Int>
    var insertedRowIndices: Set<Int>
    var modifiedCells: [Int: Set<Int>]
    var insertedRowData: [Int: [String?]]  // Lazy storage for inserted row values
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

    // Progressive loading state (query tabs)
    var hasMoreRows: Bool = false
    var loadMoreOffset: Int = 0
    var isLoadingMore: Bool = false
    var baseQueryForMore: String?

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

    /// Reset progressive loading state
    mutating func resetLoadMore() {
        hasMoreRows = false
        loadMoreOffset = 0
        isLoadingMore = false
        baseQueryForMore = nil
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
