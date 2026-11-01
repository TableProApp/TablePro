//
//  QueryTabState.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit
import TableProUtilities

enum TabType: Equatable, Codable, Hashable {
    case query
    case table
    case createTable
    case erDiagram
    case serverDashboard
    case usersRoles
    case insights
    case tableHealth
    case objectSource
    case versionHistory
    // Read-only grid of one database's or schema's tables, rebuilt from the catalog on each load, never from saved SQL.
    case tableListing
    case routineDebug
}

extension TabType {
    // A live debug session cannot be restored, and the debugger is a module, so its tab never reaches disk or an outside client.
    var isTransient: Bool {
        self == .routineDebug
    }
}

struct PersistedTab: Codable {
    let id: UUID
    let title: String
    var query: String
    let tabType: TabType
    let tableName: String?
    var isView: Bool = false
    // Optional raw String so old files and kinds a newer build invents decode to nil instead of failing the whole tab set.
    var objectTypeRawValue: String?
    var databaseName: String = ""
    var schemaName: String?
    var sourceFileURL: URL?
    var sourceFileEncoding: FileTextEncoding?
    var erDiagramSchemaKey: String?
    var objectRef: DatabaseObjectRef?
    var versionHistorySubject: VersionHistorySubject?
    var queryParameters: [QueryParameter]?
    var sortColumns: [PersistedSortColumn]?
    // Nil in files written before this existed: decodes to .user when columns were saved, .unset when none were.
    var sortSource: SortSource?
    var restoredPage: Int?
    var restoredPageSize: Int?
    var cursorOffset: Int?
    var cursorLength: Int?
    var collapsedFoldRanges: [Int]?
    var columnWidths: [String: CGFloat]?
    var columnContentWidths: [String: CGFloat]?
    var windowGroupIndex: Int?
    var isPinned: Bool = false
    var isTemporary: Bool = false

    // Set when the query was too large for the tab-state JSON and lives in a sidecar file.
    var overflowFileName: String?

    init(
        id: UUID,
        title: String,
        query: String,
        tabType: TabType,
        tableName: String?,
        isView: Bool = false,
        objectTypeRawValue: String? = nil,
        databaseName: String = "",
        schemaName: String? = nil,
        sourceFileURL: URL? = nil,
        sourceFileEncoding: FileTextEncoding? = nil,
        erDiagramSchemaKey: String? = nil,
        objectRef: DatabaseObjectRef? = nil,
        versionHistorySubject: VersionHistorySubject? = nil,
        queryParameters: [QueryParameter]? = nil,
        sortColumns: [PersistedSortColumn]? = nil,
        sortSource: SortSource? = nil,
        restoredPage: Int? = nil,
        restoredPageSize: Int? = nil,
        cursorOffset: Int? = nil,
        cursorLength: Int? = nil,
        collapsedFoldRanges: [Int]? = nil,
        columnWidths: [String: CGFloat]? = nil,
        columnContentWidths: [String: CGFloat]? = nil,
        windowGroupIndex: Int? = nil,
        isPinned: Bool = false,
        isTemporary: Bool = false
    ) {
        self.id = id
        self.title = title
        self.query = query
        self.tabType = tabType
        self.tableName = tableName
        self.isView = isView
        self.objectTypeRawValue = objectTypeRawValue
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.sourceFileURL = sourceFileURL
        self.sourceFileEncoding = sourceFileEncoding
        self.erDiagramSchemaKey = erDiagramSchemaKey
        self.objectRef = objectRef
        self.versionHistorySubject = versionHistorySubject
        self.queryParameters = queryParameters
        self.sortColumns = sortColumns
        self.sortSource = sortSource
        self.restoredPage = restoredPage
        self.restoredPageSize = restoredPageSize
        self.cursorOffset = cursorOffset
        self.cursorLength = cursorLength
        self.collapsedFoldRanges = collapsedFoldRanges
        self.columnWidths = columnWidths
        self.columnContentWidths = columnContentWidths
        self.windowGroupIndex = windowGroupIndex
        self.isPinned = isPinned
        self.isTemporary = isTemporary
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, query, tabType, tableName, isView, objectTypeRawValue, databaseName, schemaName
        case sourceFileURL, sourceFileEncoding, erDiagramSchemaKey, objectRef, versionHistorySubject, queryParameters
        case sortColumns, sortSource, restoredPage, restoredPageSize, cursorOffset, cursorLength
        case collapsedFoldRanges
        case columnWidths, columnContentWidths, windowGroupIndex
        case isPinned
        case isTemporary
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
        objectTypeRawValue = try container.decodeIfPresent(String.self, forKey: .objectTypeRawValue)
        databaseName = try container.decodeIfPresent(String.self, forKey: .databaseName) ?? ""
        schemaName = try container.decodeIfPresent(String.self, forKey: .schemaName)
        sourceFileURL = try container.decodeIfPresent(URL.self, forKey: .sourceFileURL)
        sourceFileEncoding = try container.decodeIfPresent(FileTextEncoding.self, forKey: .sourceFileEncoding)
        erDiagramSchemaKey = try container.decodeIfPresent(String.self, forKey: .erDiagramSchemaKey)
        objectRef = try container.decodeIfPresent(DatabaseObjectRef.self, forKey: .objectRef)
        versionHistorySubject = try container.decodeIfPresent(VersionHistorySubject.self, forKey: .versionHistorySubject)
        queryParameters = try container.decodeIfPresent([QueryParameter].self, forKey: .queryParameters)
        sortColumns = try container.decodeIfPresent([PersistedSortColumn].self, forKey: .sortColumns)
        sortSource = try container.decodeIfPresent(SortSource.self, forKey: .sortSource)
        restoredPage = try container.decodeIfPresent(Int.self, forKey: .restoredPage)
        restoredPageSize = try container.decodeIfPresent(Int.self, forKey: .restoredPageSize)
        cursorOffset = try container.decodeIfPresent(Int.self, forKey: .cursorOffset)
        cursorLength = try container.decodeIfPresent(Int.self, forKey: .cursorLength)
        collapsedFoldRanges = try container.decodeIfPresent([Int].self, forKey: .collapsedFoldRanges)
        columnWidths = try container.decodeIfPresent([String: CGFloat].self, forKey: .columnWidths)
        columnContentWidths = try container.decodeIfPresent([String: CGFloat].self, forKey: .columnContentWidths)
        windowGroupIndex = try container.decodeIfPresent(Int.self, forKey: .windowGroupIndex)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isTemporary = try container.decodeIfPresent(Bool.self, forKey: .isTemporary) ?? false
        overflowFileName = try container.decodeIfPresent(String.self, forKey: .overflowFileName)
    }
}

struct TabChangeSnapshot: Equatable {
    var changes: [RowChange]
    var deletedRowIDs: Set<RowID>
    var insertedRowIDs: Set<RowID>
    var modifiedCells: [RowID: Set<Int>]
    var insertedRowData: [RowID: [PluginCellValue]]
    var primaryKeyColumns: [String]
    var columns: [String]

    init() {
        self.changes = []
        self.deletedRowIDs = []
        self.insertedRowIDs = []
        self.modifiedCells = [:]
        self.insertedRowData = [:]
        self.primaryKeyColumns = []
        self.columns = []
    }

    var hasChanges: Bool {
        !changes.isEmpty || !insertedRowIDs.isEmpty || !deletedRowIDs.isEmpty
    }

    mutating func adoptLoadedValues(_ values: [RowID: [Int: PluginCellValue]]) {
        RowChange.adoptLoadedValues(values, into: &changes)
    }
}

enum SortDirection: String, Equatable, Codable, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ascending: return String(localized: "Ascending")
        case .descending: return String(localized: "Descending")
        }
    }

    var opposite: SortDirection {
        self == .ascending ? .descending : .ascending
    }

    mutating func toggle() {
        self = opposite
    }
}

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

// Keyed by name so it survives column reordering across launches.
struct PersistedSortColumn: Codable, Equatable {
    let columnName: String
    let direction: SortDirection
}

// .unset vs .user with no columns tells "nothing decided yet" from "user turned sorting off", so Don't Sort sticks.
enum SortSource: String, Equatable, Codable {
    case unset
    case user
    case defaultSort
}

struct SortState: Equatable {
    var columns: [SortColumn] = []
    var source: SortSource = .unset

    init(columns: [SortColumn] = [], source: SortSource = .unset) {
        self.columns = columns
        self.source = source
    }

    var isSorting: Bool { !columns.isEmpty }

    // A column with no name cannot be resolved against a re-fetched result, so it is dropped.
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

struct PaginationState: Equatable {
    var totalRowCount: Int?
    var pageSize: Int
    var currentPage: Int = 1
    var currentOffset: Int = 0
    // Raised where rows are discarded; not derived from TabExecutionRegistry, whose claim lands a main-actor turn later.
    var isLoading: Bool = false
    var isApproximateRowCount: Bool = false
    var isCountingExact: Bool = false
    // From a failed Count Exactly, kept so a later successful count clears only this error.
    var exactCountError: String?
    // Silent automatic count in flight, so Count Exactly is not offered; the execution claim settles before it dispatches.
    var isCountPending: Bool = false

    // Result truncation state (query tabs)
    var hasMoreRows: Bool = false
    var isLoadingMore: Bool = false
    var baseQueryForMore: String?
    var baseQueryParameterValues: [String?]?

    // Set together: stale bindings sent with a placeholder-free query made Fetch All fail on the server.
    mutating func setBaseQueryForMore(_ sql: String?, parameterValues: [String?]?) {
        baseQueryForMore = sql
        baseQueryParameterValues = parameterValues
    }

    // Fallback only; new tabs pass AppSettingsManager.shared.dataGrid.defaultPageSize.
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

    // quotientAndRemainder, not (total + pageSize - 1): the rows-per-page field once accepted Int.max and overflowed.
    var totalPages: Int {
        guard let total = totalRowCount, total > 0, pageSize > 0 else { return 1 }
        let (quotient, remainder) = total.quotientAndRemainder(dividingBy: pageSize)
        return remainder == 0 ? quotient : quotient + 1
    }

    var isBusy: Bool {
        isLoading || isLoadingMore || isCountingExact || isCountPending
    }

    // An estimate cannot bound navigation: MySQL's TABLE_ROWS under-reports InnoDB and stranded rows behind a disabled Next.
    var hasExactRowCount: Bool {
        totalRowCount != nil && !isApproximateRowCount
    }

    var hasRowCountTotal: Bool {
        totalRowCount != nil
    }

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

    // A table tab pages through currentPage; hasMoreRows is a query result cut short.
    func hasUnloadedRows(loadedRowCount: Int) -> Bool {
        hasMoreRows || canGoToNextPage(loadedRowCount: loadedRowCount)
    }

    var hasPreviousPage: Bool {
        currentPage > 1
    }

    var rangeStart: Int {
        currentOffset + 1
    }

    // From loaded rows, not pageSize: an estimate of 1M that returned 12 rows showed "1-1000 of ~1,000,000 rows".
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

    // Pages past the last are refused only for an exact total; an estimate is no trustworthy upper bound.
    mutating func goToPage(_ page: Int) {
        guard page > 0, hasRowCountTotal else { return }
        guard !hasExactRowCount || page <= totalPages else { return }
        setPage(page)
    }

    // Never replaces an exact count: the auto count re-runs on every page turn and undid Count Exactly. Nil blanks it.
    mutating func applyDerivedRowCount(_ total: Int?, isApproximate: Bool) {
        guard !isApproximate || !hasExactRowCount else { return }
        totalRowCount = total
        isApproximateRowCount = isApproximate
    }

    // Cleared, not marked approximate: rowCountPlan skips counting a total above the threshold, so the ~ would stick.
    mutating func retireDerivedRowCount() {
        totalRowCount = nil
        isApproximateRowCount = false
    }

    mutating func reset() {
        currentPage = 1
        currentOffset = 0
        isLoading = false
        // A superseded count's mark would otherwise suppress Count Exactly on the new table.
        isCountPending = false
    }

    mutating func resetLoadMore() {
        hasMoreRows = false
        isLoadingMore = false
        baseQueryForMore = nil
        baseQueryParameterValues = nil
    }

    // Goes through setPage to re-derive the offset; setting currentPage alone ran LIMIT 100 OFFSET 40 shown as page 1.
    mutating func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        pageSize = newSize
        setPage((currentOffset / pageSize) + 1)
    }

    mutating func updateOffset(_ newOffset: Int) {
        guard newOffset >= 0 else { return }
        currentOffset = newOffset
        currentPage = (currentOffset / pageSize) + 1
    }
}

struct ColumnLayoutState: Equatable {
    var columnWidths: [String: CGFloat] = [:]
    var columnContentWidths: [String: CGFloat]?
    var columnOrder: [String]?
    var hiddenColumns: Set<String> = []
    // Leading columns in display order, a count so a result that repeats a name stays unambiguous.
    var frozenColumnCount: Int = 0

    // A capture omits hidden columns, so names it doesn't cover keep their slots instead of jumping to the end when shown.
    static func mergedColumnOrder(current: [String]?, incoming: [String]?) -> [String]? {
        guard let incoming else { return current }
        guard let current, !current.isEmpty else { return incoming }

        let incomingSet = Set(incoming)
        // Only a narrowing of the same column set is a partial capture; anything else is a different result.
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
        frozenColumnCount = other.frozenColumnCount
    }

    // Reset is not a capture, so it skips the merge, which keeps a stored order when a capture carries none.
    mutating func resetGeometry() {
        columnWidths = [:]
        columnContentWidths = nil
        columnOrder = nil
        frozenColumnCount = 0
    }

    func mergingWidths(_ liveWidths: [String: CGFloat]) -> ColumnLayoutState {
        var result = self
        result.columnWidths.merge(liveWidths) { _, live in live }
        return result
    }
}

// No isExecuting on purpose: busy comes from TabExecutionRegistry, as a stored flag kept retargeted tabs busy forever.
struct TabExecutionState: Equatable {
    var executionTime: TimeInterval?
    var statusMessage: String?
    var errorMessage: String?
    var errorQuery: String?
    var rowsAffected: Int = 0
    var lastExecutedAt: Date?

    // Set when work finished out of sight, cleared on select; survives missed banners, denied notifications and Focus.
    var finishedUnseenAt: Date?

    // Hand-written: every field the UI draws must be compared, or SwiftUI sees no change (finishedUnseenAt drives a dot).
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

    // Beside isView, which can't tell seven kinds apart; only the kind says which structure edits the object accepts (#2726).
    var objectType: TableInfo.TableType?

    // Browse only: a staged row edit would land on whatever table the name reaches once the temporary one is dropped.
    var isTemporary = false

    // Nil until the driver answers, and on an engine that never does.
    var viewRowEditing: PluginViewRowEditing?

    func resolvedObjectKind() -> TableInfo.TableType {
        objectType ?? (isView ? .view : .table)
    }

    var allowsRowEditing: Bool {
        guard !isTemporary else { return false }
        if resolvedObjectKind() == .view { return viewEditRefusal == nil }
        return !isView && resolvedObjectKind().allowsRowEditing
    }

    var viewEditRefusal: ResultEditRefusal? {
        guard resolvedObjectKind() == .view else { return nil }
        return ResultEditRefusal.forView(answer: viewRowEditing, keyedOn: primaryKeyColumns)
    }

    var viewWriteTarget: PluginViewWriteTarget? {
        guard resolvedObjectKind() == .view else { return nil }
        return viewRowEditing?.writeTarget(keyedOn: primaryKeyColumns)
    }

    // A query tab knows a view only from an earlier answer for the same relation; that keeps a failed check read-only.
    func knowsView(named name: String?) -> Bool {
        resolvedObjectKind() == .view || (viewRowEditing != nil && name == tableName)
    }

    // A driver answers only for a view, so a table tab opened without a kind (a deep link, a script) learns it here.
    mutating func adoptViewAnswer(_ answer: PluginViewRowEditing?, tabType: TabType) {
        viewRowEditing = answer
        guard answer != nil, tabType == .table, resolvedObjectKind() == .table else { return }
        objectType = .view
        isView = true
    }

    var primaryKeyColumn: String? { primaryKeyColumns.first }

    // An empty name means the tab follows the window's browse cursor.
    func resolvedDatabaseName(browsing browseDatabaseName: String) -> String {
        databaseName.isEmpty ? browseDatabaseName : databaseName
    }
}

struct TabQueryContent: Equatable {
    // Boxed: SwiftUI's graph diff walks a stored String, which NFC-normalized multi-MB queries on every view update.
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
    var savedFileStamp: FileStamp?
    var sourceFileEncoding: FileTextEncoding?
    var diskChange: SourceFileDiskChange?
    var dismissedDiskChange: SourceFileDiskChange?

    static let maxPersistableQuerySize = 500_000

    init(
        query: String = "",
        queryParameters: [QueryParameter] = [],
        isParameterPanelVisible: Bool = false,
        sourceFileURL: URL? = nil,
        savedFileContent: String? = nil,
        savedFileStamp: FileStamp? = nil,
        sourceFileEncoding: FileTextEncoding? = nil,
        diskChange: SourceFileDiskChange? = nil,
        dismissedDiskChange: SourceFileDiskChange? = nil
    ) {
        self.queryStorage = QueryStorage(query)
        self.queryParameters = queryParameters
        self.isParameterPanelVisible = isParameterPanelVisible
        self.sourceFileURL = sourceFileURL
        self.savedFileContent = savedFileContent
        self.savedFileStamp = savedFileStamp
        self.sourceFileEncoding = sourceFileEncoding
        self.diskChange = diskChange
        self.dismissedDiskChange = dismissedDiskChange
    }

    var isFileDirty: Bool {
        guard sourceFileURL != nil, let saved = savedFileContent else { return false }
        let queryNS = query as NSString
        let savedNS = saved as NSString
        if queryNS.length != savedNS.length { return true }
        return queryNS != savedNS
    }

    static func == (lhs: TabQueryContent, rhs: TabQueryContent) -> Bool {
        // Cheap fields first; multi-MB text last, via box identity and sameText to skip canonical Unicode comparison.
        lhs.isParameterPanelVisible == rhs.isParameterPanelVisible
            && lhs.diskChange == rhs.diskChange
            && lhs.dismissedDiskChange == rhs.dismissedDiskChange
            && lhs.sourceFileURL == rhs.sourceFileURL
            && lhs.savedFileStamp == rhs.savedFileStamp
            && lhs.sourceFileEncoding == rhs.sourceFileEncoding
            && lhs.queryParameters == rhs.queryParameters
            && (lhs.queryStorage === rhs.queryStorage || sameText(lhs.query, rhs.query))
            && sameText(lhs.savedFileContent, rhs.savedFileContent)
    }

    // Literal comparison, skipping Swift's canonical Unicode equality; O(1) when the lengths differ.
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
    // Set once per result in installTableRows: detection samples values, and the status bar and View menu ask constantly.
    var spatialColumns: [SpatialColumn] = []
    var erDiagramSchemaKey: String?
    var objectRef: DatabaseObjectRef?
    var versionHistorySubject: VersionHistorySubject?
    var isResultsCollapsed: Bool = false
    var resultSets: [ResultSet] = []
    var activeResultSetId: UUID?
    var highlightRulesPresentationRequest: Int = 0

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
        leaveOutputModeWithoutOutput()
    }

    @MainActor
    mutating func replaceResult(_ outgoingId: UUID, with result: ResultSet) {
        guard let index = resultSets.firstIndex(where: { $0.id == outgoingId }) else { return }
        result.label = resultSets[index].label
        result.isPinned = resultSets[index].isPinned
        resultSets[index] = result
        activeResultSetId = result.id
        leaveOutputModeWithoutOutput()
    }

    // New results join after the pinned ones, so a counted name starts there and never repeats a pinned one.
    @MainActor
    var pinnedResultCount: Int {
        resultSets.filter(\.isPinned).count
    }

    @MainActor
    mutating func removeUnpinnedResults(keepingActive: Bool = false) {
        let activeId = activeResultSet?.id
        resultSets = resultSets.filter { $0.isPinned }
        activeResultSetId = keepingActive && resultSets.contains { $0.id == activeId } ? activeId : resultSets.last?.id
        leaveOutputModeWithoutOutput()
    }

    // Output mode can't outlive a silent result; checked here since row install reconciles modes before the result swap.
    @MainActor
    private mutating func leaveOutputModeWithoutOutput() {
        guard resultsViewMode == .output, activeResultSet?.serverOutput.isEmpty != false else { return }
        resultsViewMode = .data
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
            && lhs.spatialColumns == rhs.spatialColumns
            && lhs.isResultsCollapsed == rhs.isResultsCollapsed
            && lhs.resultSets.map(\.id) == rhs.resultSets.map(\.id)
            && lhs.activeResultSetId == rhs.activeResultSetId
            && lhs.highlightRulesPresentationRequest == rhs.highlightRulesPresentationRequest
    }
}
