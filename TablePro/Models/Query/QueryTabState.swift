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
    case usersRoles
    case insights
}

/// Minimal representation of a tab for persistence
struct PersistedTab: Codable {
    let id: UUID
    let title: String
    var query: String
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
    var restoredPageSize: Int?
    var cursorOffset: Int?
    var cursorLength: Int?
    var collapsedFoldRanges: [Int]?
    var columnWidths: [String: CGFloat]?
    var columnContentWidths: [String: CGFloat]?
    var windowGroupIndex: Int?

    /// Set when the query was too large for the tab-state JSON and lives in a sidecar file.
    var overflowFileName: String?

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
        restoredPageSize: Int? = nil,
        cursorOffset: Int? = nil,
        cursorLength: Int? = nil,
        collapsedFoldRanges: [Int]? = nil,
        columnWidths: [String: CGFloat]? = nil,
        columnContentWidths: [String: CGFloat]? = nil,
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
        self.restoredPageSize = restoredPageSize
        self.cursorOffset = cursorOffset
        self.cursorLength = cursorLength
        self.collapsedFoldRanges = collapsedFoldRanges
        self.columnWidths = columnWidths
        self.columnContentWidths = columnContentWidths
        self.windowGroupIndex = windowGroupIndex
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, query, tabType, tableName, isView, databaseName, schemaName
        case sourceFileURL, erDiagramSchemaKey, queryParameters
        case sortColumns, restoredPage, restoredPageSize, cursorOffset, cursorLength, collapsedFoldRanges
        case columnWidths, columnContentWidths, windowGroupIndex
        case overflowFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Query"
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
        restoredPageSize = try container.decodeIfPresent(Int.self, forKey: .restoredPageSize)
        cursorOffset = try container.decodeIfPresent(Int.self, forKey: .cursorOffset)
        cursorLength = try container.decodeIfPresent(Int.self, forKey: .cursorLength)
        collapsedFoldRanges = try container.decodeIfPresent([Int].self, forKey: .collapsedFoldRanges)
        columnWidths = try container.decodeIfPresent([String: CGFloat].self, forKey: .columnWidths)
        columnContentWidths = try container.decodeIfPresent([String: CGFloat].self, forKey: .columnContentWidths)
        windowGroupIndex = try container.decodeIfPresent(Int.self, forKey: .windowGroupIndex)
        overflowFileName = try container.decodeIfPresent(String.self, forKey: .overflowFileName)
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

    /// The sort in the name-keyed shape both persistence and navigation history store it in. A
    /// column with no name cannot be resolved back against a re-fetched result, so it is dropped.
    var persistedColumns: [PersistedSortColumn] {
        columns.compactMap { column in
            guard let name = column.columnName else { return nil }
            return PersistedSortColumn(columnName: name, direction: column.direction)
        }
    }

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
    /// A fetch is in flight for the rows this state describes.
    ///
    /// Raised synchronously by whatever discards the tab's rows, in the same block that discards
    /// them, and lowered when the rows land or the attempt fails. It cannot be derived from
    /// `TabExecutionRegistry.isExecuting`: retargeting a tab clears the row buffer synchronously
    /// but only *schedules* the load, so the claim arrives a main-actor turn later and the status
    /// bar can render an empty buffer that nothing has yet called a load.
    var isLoading: Bool = false
    var isApproximateRowCount: Bool = false  // True when totalRowCount is from fast estimate
    var isCountingExact: Bool = false        // True while a user-requested exact count is running
    /// An automatic row count is running, so the total on screen is not the one this page settles on.
    ///
    /// Separate from `isCountingExact`, which the user asked for and which owns the spinner. This
    /// one is silent: it exists so `Count Exactly` is not offered against a total that is about to
    /// be replaced anyway. The execution claim cannot answer this, because it settles the moment
    /// phase 1 applies, before the count is even dispatched.
    var isCountPending: Bool = false

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
    ///
    /// The ceiling is taken with `quotientAndRemainder` rather than `(total + pageSize - 1) / pageSize`
    /// because the custom rows-per-page field used to accept `Int.max`, and the addition then trapped
    /// on overflow the next time the status bar rendered.
    var totalPages: Int {
        guard let total = totalRowCount, total > 0, pageSize > 0 else { return 1 }
        let (quotient, remainder) = total.quotientAndRemainder(dividingBy: pageSize)
        return remainder == 0 ? quotient : quotient + 1
    }

    /// Any asynchronous work this state is still waiting on.
    var isBusy: Bool {
        isLoading || isLoadingMore || isCountingExact || isCountPending
    }

    /// Whether the total is a real count rather than a driver estimate.
    ///
    /// An estimate cannot bound navigation. MySQL's `TABLE_ROWS` under-reports InnoDB routinely, and
    /// an estimate kept as the total left every row past it unreachable behind a disabled Next.
    var hasExactRowCount: Bool {
        totalRowCount != nil && !isApproximateRowCount
    }

    /// Whether any total is available, exact or estimated.
    var hasRowCountTotal: Bool {
        totalRowCount != nil
    }

    /// Whether there is a next page available
    var hasNextPage: Bool {
        currentPage < totalPages
    }

    var isLastPageKnown: Bool {
        hasExactRowCount
    }

    func canGoToNextPage(loadedRowCount: Int) -> Bool {
        if hasExactRowCount { return hasNextPage }
        return loadedRowCount >= pageSize
    }

    /// Whether there is a previous page available
    var hasPreviousPage: Bool {
        currentPage > 1
    }

    /// Starting row number for current page (1-based)
    var rangeStart: Int {
        currentOffset + 1
    }

    /// Ending row number for the current page, from the rows the page actually returned.
    ///
    /// Deriving it from `pageSize` fabricated a range the grid never showed: a table whose driver
    /// estimate said a million rows but which returned twelve reported "1-1000 of ~1,000,000 rows".
    /// The loaded count is the only number that describes what is on screen.
    func rangeEnd(loadedRowCount: Int) -> Int {
        currentOffset + max(loadedRowCount, 0)
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
        guard hasExactRowCount else { return }
        setPage(totalPages)
    }

    /// A page beyond the last is refused only when the last one is actually known. With an estimate
    /// there is no trustworthy upper bound, and refusing on one strands the rows past it.
    mutating func goToPage(_ page: Int) {
        guard page > 0, hasRowCountTotal else { return }
        guard !hasExactRowCount || page <= totalPages else { return }
        setPage(page)
    }

    /// Applies a total the app derived on its own, rather than one the user asked for.
    ///
    /// An estimate never replaces an exact count. The automatic count re-runs after every execution,
    /// including a page turn, and on a driver whose cheap count is an estimate that silently undid a
    /// `Count Exactly` and brought the button back on the next page. Retiring an exact count is a
    /// deliberate act, so it belongs to the paths that ask for fresh data, not to this one.
    /// A nil total blanks it, which is what a filter change asks for and is never an estimate.
    mutating func applyDerivedRowCount(_ total: Int?, isApproximate: Bool) {
        guard !isApproximate || !hasExactRowCount else { return }
        totalRowCount = total
        isApproximateRowCount = isApproximate
    }

    /// Drops the total so the next execution derives it again from scratch.
    ///
    /// For the paths that change the row set or ask for it fresh, where the count on screen is no
    /// longer describing the table. Clearing the number rather than flagging it approximate matters:
    /// `rowCountPlan` skips counting a table whose total already exceeds the count threshold, so a
    /// real count left in place and merely relabelled would keep its `~` forever, with `Last page`
    /// disabled and no `Count Exactly` to put it right. Cleared, the tab counts exactly the way a
    /// freshly opened one does.
    mutating func retireDerivedRowCount() {
        totalRowCount = nil
        isApproximateRowCount = false
    }

    /// Reset pagination to first page
    mutating func reset() {
        currentPage = 1
        currentOffset = 0
        isLoading = false
        /// A count belonging to the rows being replaced is not this tab's business any more. Left
        /// set, a superseded attempt's mark would suppress `Count Exactly` on the new table until
        /// something else happened to clear it.
        isCountPending = false
    }

    /// Reset result truncation state
    mutating func resetLoadMore() {
        hasMoreRows = false
        isLoadingMore = false
        baseQueryForMore = nil
        baseQueryParameterValues = nil
        sortExecutionOverride = nil
    }

    /// Update page size (limit), keeping the first visible row inside the new page.
    ///
    /// `setPage` is what re-derives the offset. Assigning `currentPage` alone left the old offset in
    /// place, so changing 20 to 100 on page 3 ran `LIMIT 100 OFFSET 40` while the indicator read
    /// "1 / N" and First and Previous went inert.
    mutating func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        pageSize = newSize
        setPage((currentOffset / pageSize) + 1)
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
    var columnContentWidths: [String: CGFloat]?
    var columnOrder: [String]?
    var hiddenColumns: Set<String> = []

    /// Splices a captured order into the stored one, keeping names the capture never saw.
    ///
    /// A capture only lists the columns the query returned, and hiding a column takes it out of
    /// that projection. Overwriting with the capture therefore drops the hidden column's position,
    /// and showing it again appends it at the end, which reorders a grid the user never touched.
    /// Names the capture does cover take its order; the rest hold their slots.
    static func mergedColumnOrder(current: [String]?, incoming: [String]?) -> [String]? {
        guard let incoming else { return current }
        guard let current, !current.isEmpty else { return incoming }

        let incomingSet = Set(incoming)
        // Only a narrowing of the same column set is a partial capture worth splicing. Anything
        // else is a different result, and merging there would accumulate names from a table the
        // layout no longer describes.
        guard incomingSet.isSubset(of: Set(current)) else { return incoming }
        var remaining = incoming.makeIterator()
        var merged: [String] = []
        merged.reserveCapacity(max(current.count, incoming.count))

        for name in current {
            if incomingSet.contains(name) {
                guard let next = remaining.next() else { continue }
                merged.append(next)
            } else {
                merged.append(name)
            }
        }

        let placed = Set(merged)
        merged.append(contentsOf: incoming.filter { !placed.contains($0) })
        return merged
    }

    mutating func applyGeometry(from other: ColumnLayoutState) {
        columnWidths = other.columnWidths
        columnContentWidths = other.columnContentWidths
        columnOrder = Self.mergedColumnOrder(current: columnOrder, incoming: other.columnOrder)
    }

    /// Drops the geometry outright. Reset is not a capture, so it must not go through the merge,
    /// which deliberately keeps a stored order when a capture carries none.
    mutating func resetGeometry() {
        columnWidths = [:]
        columnContentWidths = nil
        columnOrder = nil
    }

    func mergingWidths(_ liveWidths: [String: CGFloat]) -> ColumnLayoutState {
        var result = self
        result.columnWidths.merge(liveWidths) { _, live in live }
        return result
    }
}

/// Deliberately has no `isExecuting`. Busy state is derived from `TabExecutionRegistry`, because a
/// stored flag could not be reset by a tab retarget and so kept a retargeted tab busy forever,
/// silently swallowing every later navigation.
struct TabExecutionState: Equatable {
    var executionTime: TimeInterval?
    var statusMessage: String?
    var errorMessage: String?
    var errorQuery: String?
    var rowsAffected: Int = 0
    var lastExecutedAt: Date?

    /// Set when work on this tab finished somewhere the user could not see it, cleared when they
    /// select the tab. This is the channel that survives a missed banner, a denied notification
    /// permission and a Focus mode, none of which the app can do anything about.
    var finishedUnseenAt: Date?

    /// Hand-written, and every field the UI draws from has to be in it. `finishedUnseenAt` drives
    /// a dot in the tab strip, so leaving it out here would mean the dot never appeared: SwiftUI
    /// compares the tab and sees no change.
    static func == (lhs: TabExecutionState, rhs: TabExecutionState) -> Bool {
        lhs.executionTime == rhs.executionTime
            && lhs.statusMessage == rhs.statusMessage
            && lhs.errorMessage == rhs.errorMessage
            && lhs.rowsAffected == rhs.rowsAffected
            && lhs.finishedUnseenAt == rhs.finishedUnseenAt
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

    /// A tab opened without an explicit database carries an empty name and follows the window's
    /// browse cursor, so comparing the stored value against a real database name never matches.
    func resolvedDatabaseName(browsing browseDatabaseName: String) -> String {
        databaseName.isEmpty ? browseDatabaseName : databaseName
    }
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
    var isResultsCollapsed: Bool = false
    var resultSets: [ResultSet] = []
    var activeResultSetId: UUID?

    var activeResultSet: ResultSet? {
        guard let id = activeResultSetId else { return resultSets.last }
        return resultSets.first { $0.id == id }
    }

    @MainActor
    var hasPinnedResults: Bool {
        resultSets.contains { $0.isPinned }
    }

    @MainActor
    mutating func replaceUnpinnedResults(with newResults: [ResultSet]) {
        resultSets = resultSets.filter { $0.isPinned } + newResults
        activeResultSetId = newResults.last?.id ?? resultSets.last?.id
    }

    @MainActor
    mutating func removeUnpinnedResults() {
        resultSets = resultSets.filter { $0.isPinned }
        activeResultSetId = resultSets.last?.id
    }

    @MainActor
    var activeExplainResult: ResultSet? {
        guard let activeResultSet, activeResultSet.isExplainResult else { return nil }
        return activeResultSet
    }

    @MainActor
    mutating func togglePin(resultSetId: UUID) {
        guard let target = resultSets.first(where: { $0.id == resultSetId }) else { return }
        target.isPinned.toggle()
        resultSets = resultSets.filter(\.isPinned) + resultSets.filter { !$0.isPinned }
    }

    static func == (lhs: TabDisplayState, rhs: TabDisplayState) -> Bool {
        lhs.resultsViewMode == rhs.resultsViewMode
            && lhs.isResultsCollapsed == rhs.isResultsCollapsed
            && lhs.resultSets.map(\.id) == rhs.resultSets.map(\.id)
            && lhs.activeResultSetId == rhs.activeResultSetId
    }
}
