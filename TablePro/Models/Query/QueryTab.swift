import Foundation
import Observation
import os
import TableProPluginKit

enum ResultsViewMode: String, Equatable {
    case data
    case structure
    case json
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
    var columnLayout: ColumnLayoutState
    var pagination: PaginationState
    var hasUserInteraction: Bool
    var schemaVersion: Int
    var metadataVersion: Int
    var paginationVersion: Int
    var loadEpoch: Int = 0

    var pendingRestoredSort: [PersistedSortColumn]?
    var restoredPage: Int?
    var restoredCursorOffset: Int?

    private static func clampedCursorOffset(_ offset: Int?, in query: String) -> Int? {
        guard let offset, offset >= 0 else { return nil }
        return min(offset, (query as NSString).length)
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
        self.columnLayout = ColumnLayoutState()
        self.pagination = PaginationState()
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
        self.loadEpoch = 0
        self.pendingRestoredSort = nil
        self.restoredPage = nil
        self.restoredCursorOffset = nil
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
        self.columnLayout = ColumnLayoutState(columnWidths: persisted.columnWidths ?? [:])
        self.pagination = PaginationState(pageSize: defaultPageSize)
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
        self.loadEpoch = 0
        self.pendingRestoredSort = persisted.sortColumns
        self.restoredPage = persisted.restoredPage.map { max(1, $0) }
        self.restoredCursorOffset = Self.clampedCursorOffset(persisted.cursorOffset, in: persisted.query)
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

    func toPersistedTab(windowGroupIndex: Int? = nil) -> PersistedTab {
        let queryLength = (content.query as NSString).length
        let persistedQuery = queryLength > TabQueryContent.maxPersistableQuerySize ? "" : content.query

        let persistedSort: [PersistedSortColumn]? = {
            let resolved = sortState.columns.compactMap { column -> PersistedSortColumn? in
                guard let name = column.columnName else { return nil }
                return PersistedSortColumn(columnName: name, direction: column.direction)
            }
            return resolved.isEmpty ? nil : resolved
        }()

        let restoredPage = (tabType == .table && pagination.currentPage > 1) ? pagination.currentPage : nil
        let widths = columnLayout.columnWidths.isEmpty ? nil : columnLayout.columnWidths

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
            cursorOffset: Self.clampedCursorOffset(restoredCursorOffset, in: persistedQuery),
            columnWidths: widths,
            windowGroupIndex: windowGroupIndex
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
            && lhs.display == rhs.display
            && lhs.tableContext.isEditable == rhs.tableContext.isEditable
            && lhs.tableContext.isView == rhs.tableContext.isView
            && lhs.tabType == rhs.tabType
            && lhs.isPreview == rhs.isPreview
            && lhs.hasUserInteraction == rhs.hasUserInteraction
            && lhs.loadEpoch == rhs.loadEpoch
    }
}
