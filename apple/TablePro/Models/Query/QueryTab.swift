import Foundation
import Observation
import os
import TableProPluginKit

// CaseIterable feeds the View menu's Result View submenu; per-tab availability stays with ResultsModeAvailability.
enum ResultsViewMode: String, CaseIterable, Equatable {
    case data
    case structure
    case json
    case chart
    case map
    // Server output such as Oracle's DBMS_OUTPUT, offered only for a result that printed something.
    case output

    // Chart and map draw the grid's buffer, so they need its scope controls; Output is not drawn from the buffer.
    var showsResultScope: Bool {
        self != .structure && self != .output
    }

    var reportsExecution: Bool {
        self != .structure
    }

    var showsColumnControls: Bool {
        self == .data || self == .json
    }

    // Map is out on purpose: a Data-mode filter still narrows it, but the filter chrome belongs beside the grid.
    var showsRowFilters: Bool {
        self == .data || self == .json
    }

    // The find bar searches the mounted grid; JSON mode carries its own search inside the tree view.
    var showsFindBar: Bool {
        self == .data
    }

    // Not showsColumnControls: Map reads and writes the selection, so a count the bar hides is one the reader cannot see.
    var reportsRowSelection: Bool {
        self == .data || self == .json || self == .map
    }
}

struct QueryTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var tabType: TabType
    var isPreview: Bool
    var isPinned: Bool

    var content: TabQueryContent
    var execution: TabExecutionState
    var tableContext: TabTableContext
    var display: TabDisplayState

    var pendingChanges: TabChangeSnapshot
    // The grid's selection by row and column identity, carried when the tab moves to another window.
    var selectionSnapshot: GridSelectionSnapshot

    var sortState: SortState
    var filterState: TabFilterState
    var columnLayout: ColumnLayoutState
    // On the tab, not the grid: JSON mode, the inspector and the Edit menu's row commands read the order unmounted (#2251).
    var valueFilter: GridValueFilterState
    var sessionHighlightRules: [HighlightRule] = []
    var pagination: PaginationState
    var chartConfiguration: ResultChartConfiguration
    var mapConfiguration: ResultMapConfiguration
    var hasUserInteraction: Bool
    var schemaVersion: Int
    var metadataVersion: Int
    var paginationVersion: Int

    var pendingRestoredSort: [PersistedSortColumn]?
    // Held until the first load resolves the columns.
    var restoredSortSource: SortSource = .unset
    var restoredPage: Int?
    // A page index means nothing without its size: the offset is (page - 1) * pageSize.
    var restoredPageSize: Int?
    var restoredRowAnchor: [String: String]?
    var restoredCursorOffset: Int?
    var restoredCursorLength: Int?

    // Not restoredCursorOffset, which the editor refuses once mounted; an anchor because the tab's binding can lag the editor.
    var pendingStatementJump: StatementAnchor?

    // The editor is a view onto this, not its owner.
    var collapsedFoldRanges: [Range<Int>]?

    // Bounds checked first: a persisted file can hold an inverted pair, and 30..<10 traps instead of forming an empty range.
    private static func foldRange(lower: Int, upper: Int, limit: Int) -> Range<Int>? {
        guard lower >= 0, upper > lower, upper <= limit else { return nil }
        return lower..<upper
    }

    // A pair that no longer fits the query is dropped, not replayed onto text that changed while the tab was closed.
    private static func clampedFoldRanges(_ bounds: [Int]?, in query: String) -> [Range<Int>]? {
        guard let bounds, bounds.count >= 2 else { return nil }
        let limit = (query as NSString).length
        let ranges = stride(from: 0, to: bounds.count - 1, by: 2).compactMap {
            foldRange(lower: bounds[$0], upper: bounds[$0 + 1], limit: limit)
        }
        return ranges.isEmpty ? nil : ranges
    }

    private static func foldBounds(_ ranges: [Range<Int>]?, in query: String) -> [Int]? {
        guard let ranges else { return nil }
        let limit = (query as NSString).length
        let bounds = ranges
            .compactMap { foldRange(lower: $0.lowerBound, upper: $0.upperBound, limit: limit) }
            .flatMap { [$0.lowerBound, $0.upperBound] }
        return bounds.isEmpty ? nil : bounds
    }

    private static func clampedCursorOffset(_ offset: Int?, in query: String) -> Int? {
        guard let offset, offset >= 0 else { return nil }
        return min(offset, (query as NSString).length)
    }

    private static func clampedCursorLength(_ length: Int?, from offset: Int?, in query: String) -> Int? {
        guard let length, length > 0, let start = clampedCursorOffset(offset, in: query) else { return nil }
        let available = (query as NSString).length - start
        guard available > 0 else { return nil }
        return min(length, available)
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
        self.tabType = tabType
        self.isPreview = false
        self.isPinned = false
        self.content = TabQueryContent(query: query)
        self.execution = TabExecutionState()
        self.tableContext = TabTableContext(tableName: tableName, isEditable: tabType == .table)
        self.display = TabDisplayState()
        self.pendingChanges = TabChangeSnapshot()
        self.selectionSnapshot = .empty
        self.sortState = SortState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.valueFilter = GridValueFilterState()
        self.pagination = PaginationState()
        self.chartConfiguration = ResultChartConfiguration()
        self.mapConfiguration = ResultMapConfiguration()
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
        self.pendingRestoredSort = nil
        self.restoredSortSource = .unset
        self.restoredPage = nil
        self.restoredPageSize = nil
        self.restoredCursorOffset = nil
        self.restoredCursorLength = nil
    }

    init(from persisted: PersistedTab, defaultPageSize: Int) {
        self.id = persisted.id
        self.title = persisted.title
        self.tabType = persisted.tabType
        self.isPreview = false
        self.isPinned = persisted.isPinned
        self.content = TabQueryContent(
            query: persisted.query,
            queryParameters: persisted.queryParameters ?? [],
            sourceFileURL: persisted.sourceFileURL,
            sourceFileEncoding: persisted.sourceFileEncoding
        )
        self.execution = TabExecutionState()
        self.tableContext = TabTableContext(
            tableName: persisted.tableName,
            databaseName: persisted.databaseName,
            schemaName: persisted.schemaName,
            isEditable: persisted.tabType == .table && !persisted.isView,
            isView: persisted.isView,
            objectType: persisted.objectTypeRawValue.flatMap(TableInfo.TableType.init(rawValue:)),
            isTemporary: persisted.isTemporary
        )
        self.display = TabDisplayState(
            erDiagramSchemaKey: persisted.erDiagramSchemaKey,
            objectRef: persisted.objectRef,
            versionHistorySubject: persisted.versionHistorySubject
        )
        self.pendingChanges = TabChangeSnapshot()
        self.selectionSnapshot = .empty
        // Seeding the source carries a saved empty sort (the user's Don't Sort) past wantsDefaultSort on the first load.
        self.sortState = (persisted.sortColumns?.isEmpty ?? true) && persisted.sortSource == .user
            ? SortState(columns: [], source: .user)
            : SortState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState(
            columnWidths: persisted.columnWidths ?? [:],
            columnContentWidths: persisted.columnContentWidths
        )
        self.valueFilter = GridValueFilterState()
        self.pagination = PaginationState(pageSize: defaultPageSize)
        self.chartConfiguration = ResultChartConfiguration()
        self.mapConfiguration = ResultMapConfiguration()
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
        self.pendingRestoredSort = persisted.sortColumns
        // A file from before sortSource decodes to its old behaviour: saved columns were the user's, none meant undecided.
        self.restoredSortSource = persisted.sortSource
            ?? ((persisted.sortColumns?.isEmpty == false) ? .user : .unset)
        let clampedPageSize = persisted.restoredPageSize
            .map { $0.clamped(to: SettingsValidationRules.defaultPageSizeRange) }
        self.restoredPageSize = clampedPageSize
        self.restoredPage = Self.restoredPage(
            persisted.restoredPage,
            savedPageSize: persisted.restoredPageSize,
            appliedPageSize: clampedPageSize
        )
        self.restoredCursorOffset = Self.clampedCursorOffset(persisted.cursorOffset, in: persisted.query)
        self.restoredCursorLength = Self.clampedCursorLength(
            persisted.cursorLength,
            from: persisted.cursorOffset,
            in: persisted.query
        )
        self.collapsedFoldRanges = Self.clampedFoldRanges(persisted.collapsedFoldRanges, in: persisted.query)
    }

    // Rescale to the page holding the same first row, as PaginationState.updatePageSize does, or the tab lands rows short.
    private static func restoredPage(
        _ page: Int?,
        savedPageSize: Int?,
        appliedPageSize: Int?
    ) -> Int? {
        guard let page else { return nil }
        let requested = max(1, page)
        guard let savedPageSize, let appliedPageSize,
              savedPageSize != appliedPageSize,
              savedPageSize > 0, appliedPageSize > 0 else { return requested }

        // Both numbers come off disk, so an overflowing product falls back to the start of the table.
        let (offset, overflowed) = (requested - 1).multipliedReportingOverflow(by: savedPageSize)
        guard !overflowed else { return 1 }
        return offset / appliedPageSize + 1
    }

    @MainActor static func buildBaseTableQuery(
        tableName: String,
        databaseType: DatabaseType,
        schemaName: String? = nil,
        quoteIdentifier: ((String) -> String)? = nil
    ) throws -> String {
        let pagination = PluginManager.shared.paginationCapability(for: databaseType)
        let pageSize = pagination.clampedRowCount(AppSettingsManager.shared.dataGrid.defaultPageSize)

        if let pluginDriver = PluginManager.shared.queryBuildingDriver(for: databaseType),
           let pluginQuery = pluginDriver.buildBrowseQuery(
               table: tableName, schema: schemaName, sortColumns: [], columns: [], limit: pageSize, offset: 0
           ) {
            return pluginQuery
        }

        // Keyed by engine: Elasticsearch, Typesense, Weaviate and etcd reach the dialect without their plugin, which throws.
        switch databaseType {
        case .mongodb:
            return "\(MongoCollectionAccessor.expression(for: tableName)).find({}).limit(\(pageSize))"
        case .redis:
            return "SCAN 0 MATCH * COUNT \(pageSize)"
        default:
            let dialect = try resolveSQLDialect(for: databaseType)
            let builder = TableQueryBuilder(
                databaseType: databaseType,
                pluginDriver: nil,
                dialect: dialect,
                pagination: pagination,
                dialectQuote: quoteIdentifier ?? quoteIdentifierFromDialect(dialect)
            )
            return builder.buildBaseQuery(
                tableName: tableName,
                schemaName: schemaName,
                limit: pageSize,
                offset: 0
            )
        }
    }

    static func fileDisplayTitle(for url: URL) -> String {
        FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }

    var hasUserActiveSort: Bool {
        sortState.isSorting && sortState.source == .user
    }

    func toPersistedTab() -> PersistedTab {
        let persistedQuery = content.query

        // Only the selected tab consumes the pending sort and page, so saves re-emit them until it has run; then live state wins.
        let carriesPendingState = tabType == .table && execution.lastExecutedAt == nil

        let persistedSort: [PersistedSortColumn]? = {
            let resolved = sortState.persistedColumns
            guard resolved.isEmpty else { return resolved }
            return carriesPendingState ? pendingRestoredSort : nil
        }()
        // Written whatever the columns, since .user with no columns is the user's Don't Sort.
        let persistedSortSource: SortSource = {
            if sortState.source != .unset { return sortState.source }
            return carriesPendingState ? restoredSortSource : .unset
        }()

        let restoredPage: Int?
        let restoredPageSize: Int?
        if tabType == .table, pagination.currentPage > 1 {
            restoredPage = pagination.currentPage
            restoredPageSize = pagination.pageSize
        } else if carriesPendingState, let pending = self.restoredPage {
            restoredPage = pending
            restoredPageSize = self.restoredPageSize
        } else {
            restoredPage = nil
            restoredPageSize = nil
        }
        let widths = columnLayout.columnWidths.isEmpty ? nil : columnLayout.columnWidths
        let contentWidths = columnLayout.columnContentWidths?.isEmpty == false
            ? columnLayout.columnContentWidths
            : nil

        return PersistedTab(
            id: id,
            title: title,
            query: persistedQuery,
            tabType: tabType,
            tableName: tableContext.tableName,
            isView: tableContext.isView,
            objectTypeRawValue: tableContext.objectType?.rawValue,
            databaseName: tableContext.databaseName,
            schemaName: tableContext.schemaName,
            sourceFileURL: content.sourceFileURL,
            sourceFileEncoding: content.sourceFileEncoding,
            erDiagramSchemaKey: display.erDiagramSchemaKey,
            objectRef: display.objectRef,
            versionHistorySubject: display.versionHistorySubject,
            queryParameters: content.queryParameters.isEmpty ? nil : content.queryParameters,
            sortColumns: persistedSort,
            sortSource: persistedSortSource,
            restoredPage: restoredPage,
            restoredPageSize: restoredPageSize,
            cursorOffset: Self.clampedCursorOffset(restoredCursorOffset, in: persistedQuery),
            cursorLength: Self.clampedCursorLength(
                restoredCursorLength,
                from: restoredCursorOffset,
                in: persistedQuery
            ),
            collapsedFoldRanges: Self.foldBounds(collapsedFoldRanges, in: persistedQuery),
            columnWidths: widths,
            columnContentWidths: contentWidths,
            isPinned: isPinned,
            isTemporary: tableContext.isTemporary
        )
    }

    static func == (lhs: QueryTab, rhs: QueryTab) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.execution == rhs.execution
            && lhs.schemaVersion == rhs.schemaVersion
            && lhs.paginationVersion == rhs.paginationVersion
            && lhs.pagination == rhs.pagination
            && lhs.sortState == rhs.sortState
            && lhs.valueFilter == rhs.valueFilter
            && lhs.sessionHighlightRules == rhs.sessionHighlightRules
            && lhs.chartConfiguration == rhs.chartConfiguration
            && lhs.mapConfiguration == rhs.mapConfiguration
            && lhs.display == rhs.display
            && lhs.tableContext.isEditable == rhs.tableContext.isEditable
            && lhs.tableContext.isView == rhs.tableContext.isView
            && lhs.tableContext.objectType == rhs.tableContext.objectType
            && lhs.tableContext.isTemporary == rhs.tableContext.isTemporary
            && lhs.tabType == rhs.tabType
            && lhs.isPreview == rhs.isPreview
            && lhs.isPinned == rhs.isPinned
            && lhs.hasUserInteraction == rhs.hasUserInteraction
    }
}
