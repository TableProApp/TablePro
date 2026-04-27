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

    var pendingChanges: TabPendingChanges
    var selectedRowIndices: Set<Int>
    var sortState: SortState
    var filterState: TabFilterState
    var columnLayout: ColumnLayoutState
    var pagination: PaginationState
    var hasUserInteraction: Bool
    var schemaVersion: Int
    var metadataVersion: Int
    var paginationVersion: Int

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
        self.pendingChanges = TabPendingChanges()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.pagination = PaginationState()
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
    }

    init(from persisted: PersistedTab) {
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
        self.pendingChanges = TabPendingChanges()
        self.selectedRowIndices = []
        self.sortState = SortState()
        self.filterState = TabFilterState()
        self.columnLayout = ColumnLayoutState()
        self.pagination = PaginationState()
        self.hasUserInteraction = false
        self.schemaVersion = 0
        self.metadataVersion = 0
        self.paginationVersion = 0
    }

    @MainActor static func buildBaseTableQuery(
        tableName: String,
        databaseType: DatabaseType,
        schemaName: String? = nil,
        quoteIdentifier: ((String) -> String)? = nil
    ) -> String {
        let quote = quoteIdentifier ?? quoteIdentifierFromDialect(PluginManager.shared.sqlDialect(for: databaseType))
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize

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

    func toPersistedTab() -> PersistedTab {
        let persistedQuery: String
        if (content.query as NSString).length > TabQueryContent.maxPersistableQuerySize {
            persistedQuery = ""
        } else {
            persistedQuery = content.query
        }

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
            queryParameters: content.queryParameters.isEmpty ? nil : content.queryParameters
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
    }
}
