import Foundation
import Observation
import os
import TableProPluginKit

enum ResultsViewMode: String, Equatable {
    case data
    case structure
    case json
    case chart

    /// How much of the loaded result the mode is showing, and how to load more. A chart draws the
    /// same buffer the grid does, so it needs the same scope controls: a warning that the chart is
    /// incomplete is only useful next to the control that completes it.
    var showsResultScope: Bool {
        self != .structure
    }

    var showsColumnControls: Bool {
        self == .data || self == .json
    }

    var showsRowFilters: Bool {
        self == .data || self == .json
    }

    /// The find bar reads the data grid's cells through the grid's own coordinator, which exists
    /// only while the grid is mounted, so it can find nothing in any other mode. JSON mode carries
    /// its own search inside the tree view.
    var showsFindBar: Bool {
        self == .data
    }
}

struct QueryTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var tabType: TabType
    var isPreview: Bool

    var content: TabQueryContent
    var execution: TabExecutionState
    var tableContext: TabTableContext
    var display: TabDisplayState

    var pendingChanges: TabChangeSnapshot
    var selectedRowIndices: Set<Int>
    var sortState: SortState
    var filterState: TabFilterState
    var findState: TabFindState
    var columnLayout: ColumnLayoutState
    /// The per-column value filter, which narrows the loaded rows without re-querying.
    ///
    /// It belongs to the tab rather than to the grid because it is the only thing that makes the
    /// displayed order differ from storage order, and every reader of that order has to work while
    /// the grid is unmounted: JSON mode, the row inspector, and the Edit menu's row commands all
    /// run with no `DataGridView` in the view tree. Living on the grid's SwiftUI coordinator meant
    /// switching result mode did not hide the order, it deleted it. (#2251)
    var valueFilter: GridValueFilterState
    var pagination: PaginationState
    var chartConfiguration: ResultChartConfiguration
    var hasUserInteraction: Bool
    var schemaVersion: Int
    var metadataVersion: Int
    var paginationVersion: Int
    var loadEpoch: Int = 0

    var pendingRestoredSort: [PersistedSortColumn]?
    var restoredPage: Int?
    /// The page size `restoredPage` was measured in. A page index means nothing without it: the
    /// offset is recomputed as `(page - 1) * pageSize`, so reading the index in a different size
    /// lands the tab on rows it was never showing.
    var restoredPageSize: Int?
    var restoredCursorOffset: Int?
    var restoredCursorLength: Int?

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
        self.content = TabQueryContent(query: query)
        self.execution = TabExecutionState()
        self.tableContext = TabTableContext(tableName: tableName, isEditable: tabType == .table)
        self.display = TabDisplayState()
        self.pendingChanges = TabChangeSnapshot()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.filterState = TabFilterState()
        self.findState = TabFindState()
        self.columnLayout = ColumnLayoutState()
        self.valueFilter = GridValueFilterState()
        self.pagination = PaginationState()
        self.chartConfiguration = ResultChartConfiguration()
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
        self.loadEpoch = 0
        self.pendingRestoredSort = nil
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
        self.content = TabQueryContent(
            query: persisted.query,
            queryParameters: persisted.queryParameters ?? [],
            sourceFileURL: persisted.sourceFileURL
        )
        self.execution = TabExecutionState()
        self.tableContext = TabTableContext(
            tableName: persisted.tableName,
            databaseName: persisted.databaseName,
            schemaName: persisted.schemaName,
            isEditable: persisted.tabType == .table && !persisted.isView,
            isView: persisted.isView
        )
        self.display = TabDisplayState(erDiagramSchemaKey: persisted.erDiagramSchemaKey)
        self.pendingChanges = TabChangeSnapshot()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.filterState = TabFilterState()
        self.findState = TabFindState()
        self.columnLayout = ColumnLayoutState(
            columnWidths: persisted.columnWidths ?? [:],
            columnContentWidths: persisted.columnContentWidths
        )
        self.valueFilter = GridValueFilterState()
        self.pagination = PaginationState(pageSize: defaultPageSize)
        self.chartConfiguration = ResultChartConfiguration()
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
        self.loadEpoch = 0
        self.pendingRestoredSort = persisted.sortColumns
        self.restoredPage = persisted.restoredPage.map { max(1, $0) }
        self.restoredPageSize = persisted.restoredPageSize
            .map { $0.clamped(to: SettingsValidationRules.defaultPageSizeRange) }
        self.restoredCursorOffset = Self.clampedCursorOffset(persisted.cursorOffset, in: persisted.query)
        self.restoredCursorLength = Self.clampedCursorLength(
            persisted.cursorLength,
            from: persisted.cursorOffset,
            in: persisted.query
        )
    }

    @MainActor static func buildBaseTableQuery(
        tableName: String,
        databaseType: DatabaseType,
        schemaName: String? = nil,
        quoteIdentifier: ((String) -> String)? = nil
    ) throws -> String {
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize

        if let pluginDriver = PluginManager.shared.queryBuildingDriver(for: databaseType),
           let pluginQuery = pluginDriver.buildBrowseQuery(
               table: tableName, schema: schemaName, sortColumns: [], columns: [], limit: pageSize, offset: 0
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
            let dialect = try resolveSQLDialect(for: databaseType)
            let builder = TableQueryBuilder(
                databaseType: databaseType,
                pluginDriver: nil,
                dialect: dialect,
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

        // A restored tab holds its saved sort and page in the pending fields until it is selected,
        // because only the selected tab runs the first load that consumes them. Every save maps
        // every tab through here, so re-emitting what has not been consumed yet is what keeps an
        // unactivated tab's view state alive. `cursorOffset` and `columnWidths` already do this.
        //
        // The fallback holds only until the tab has actually run. After that the live state is the
        // truth, and a pending value that outranked it would pin a page the user has since left
        // with no way to correct it.
        let carriesPendingState = tabType == .table && execution.lastExecutedAt == nil

        let persistedSort: [PersistedSortColumn]? = {
            let resolved = sortState.columns.compactMap { column -> PersistedSortColumn? in
                guard let name = column.columnName else { return nil }
                return PersistedSortColumn(columnName: name, direction: column.direction)
            }
            guard resolved.isEmpty else { return resolved }
            return carriesPendingState ? pendingRestoredSort : nil
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
            databaseName: tableContext.databaseName,
            schemaName: tableContext.schemaName,
            sourceFileURL: content.sourceFileURL,
            erDiagramSchemaKey: display.erDiagramSchemaKey,
            queryParameters: content.queryParameters.isEmpty ? nil : content.queryParameters,
            sortColumns: persistedSort,
            restoredPage: restoredPage,
            restoredPageSize: restoredPageSize,
            cursorOffset: Self.clampedCursorOffset(restoredCursorOffset, in: persistedQuery),
            cursorLength: Self.clampedCursorLength(
                restoredCursorLength,
                from: restoredCursorOffset,
                in: persistedQuery
            ),
            columnWidths: widths,
            columnContentWidths: contentWidths
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
            && lhs.chartConfiguration == rhs.chartConfiguration
            && lhs.display == rhs.display
            && lhs.tableContext.isEditable == rhs.tableContext.isEditable
            && lhs.tableContext.isView == rhs.tableContext.isView
            && lhs.tabType == rhs.tabType
            && lhs.isPreview == rhs.isPreview
            && lhs.hasUserInteraction == rhs.hasUserInteraction
            && lhs.loadEpoch == rhs.loadEpoch
    }
}
