//
//  QueryTabManager.swift
//  TablePro
//

import Foundation
import Observation
import os

/// Manager for query tabs
@MainActor @Observable
final class QueryTabManager {
    var tabs: [QueryTab] = [] {
        didSet {
            _tabIndexMapDirty = true
            if oldValue.map(\.id) != tabs.map(\.id) {
                tabStructureVersion += 1
            }
            syncTabSessionRegistry(oldTabs: oldValue, newTabs: tabs)
        }
    }

    var selectedTabId: UUID?

    var tabStructureVersion: Int = 0

    @ObservationIgnored private var _tabIndexMap: [UUID: Int] = [:]
    @ObservationIgnored private var _tabIndexMapDirty = true

    @ObservationIgnored private let globalTabsProvider: () -> [QueryTab]
    @ObservationIgnored private weak var tabSessionRegistry: TabSessionRegistry?

    init(
        globalTabsProvider: @escaping () -> [QueryTab] = { [] },
        tabSessionRegistry: TabSessionRegistry? = nil
    ) {
        self.globalTabsProvider = globalTabsProvider
        self.tabSessionRegistry = tabSessionRegistry
    }

    func bindTabSessionRegistry(_ registry: TabSessionRegistry) {
        tabSessionRegistry = registry
        for tab in tabs where registry.session(for: tab.id) == nil {
            registry.register(TabSession(queryTab: tab))
        }
    }

    private func syncTabSessionRegistry(oldTabs: [QueryTab], newTabs: [QueryTab]) {
        guard let registry = tabSessionRegistry else { return }
        let oldIds = Set(oldTabs.map(\.id))
        let newIds = Set(newTabs.map(\.id))
        for removedId in oldIds.subtracting(newIds) {
            registry.unregister(id: removedId)
        }
        for addedTab in newTabs where !oldIds.contains(addedTab.id) {
            if registry.session(for: addedTab.id) == nil {
                registry.register(TabSession(queryTab: addedTab))
            }
        }
    }

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

    var selectedTabAndIndex: (tab: QueryTab, index: Int)? {
        guard let index = selectedTabIndex, index < tabs.count else { return nil }
        return (tabs[index], index)
    }

    // MARK: - Tab Naming

    /// Next "Query N" title based on existing tabs across all windows.
    static func nextQueryTitle(existingTabs: [QueryTab]) -> String {
        let maxNumber = existingTabs
            .filter { $0.tabType == .query }
            .compactMap { tab -> Int? in
                guard tab.title.hasPrefix("Query ") else { return nil }
                return Int(tab.title.dropFirst(6))
            }
            .max() ?? 0
        return "Query \(maxNumber + 1)"
    }

    private func nextTitle() -> String {
        Self.nextQueryTitle(existingTabs: globalTabsProvider() + tabs)
    }

    // MARK: - Tab Management

    func addTab(initialQuery: String? = nil, title: String? = nil, databaseName: String = "", sourceFileURL: URL? = nil) {
        if let sourceFileURL,
           let existingIndex = tabs.firstIndex(where: { $0.content.sourceFileURL == sourceFileURL }) {
            if let query = initialQuery {
                tabs[existingIndex].content.query = query
            }
            selectedTabId = tabs[existingIndex].id
            return
        }

        let tabTitle: String
        if let title {
            tabTitle = title
        } else if let sourceFileURL {
            tabTitle = sourceFileURL.deletingPathExtension().lastPathComponent
        } else {
            tabTitle = nextTitle()
        }
        var newTab = QueryTab(title: tabTitle, tabType: .query)

        if let query = initialQuery {
            newTab.content.query = query
            newTab.hasUserInteraction = true
        }

        newTab.tableContext.databaseName = databaseName
        newTab.content.sourceFileURL = sourceFileURL
        if let sourceFileURL {
            newTab.content.savedFileContent = newTab.content.query
            newTab.content.loadMtime = (try? FileManager.default.attributesOfItem(atPath: sourceFileURL.path)[.modificationDate]) as? Date
        }
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addTableTab(
        tableName: String,
        databaseType: DatabaseType = .mysql,
        databaseName: String = "",
        quoteIdentifier: ((String) -> String)? = nil
    ) throws {
        if let existingTab = tabs.first(where: {
            $0.tabType == .table && $0.tableContext.tableName == tableName && $0.tableContext.databaseName == databaseName
        }) {
            selectedTabId = existingTab.id
            return
        }

        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let query = try QueryTab.buildBaseTableQuery(
            tableName: tableName, databaseType: databaseType, quoteIdentifier: quoteIdentifier
        )
        var newTab = QueryTab(
            title: tableName,
            query: query,
            tabType: .table,
            tableName: tableName
        )
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.tableContext.databaseName = databaseName
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addCreateTableTab(databaseName: String = "") {
        let tabTitle = String(localized: "Create Table")
        var newTab = QueryTab(title: tabTitle, tabType: .createTable)
        newTab.tableContext.databaseName = databaseName
        newTab.tableContext.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addERDiagramTab(schemaKey: String, databaseName: String = "") {
        let tabTitle = String(localized: "ER Diagram")
        var newTab = QueryTab(title: tabTitle, tabType: .erDiagram)
        newTab.tableContext.databaseName = databaseName
        newTab.display.erDiagramSchemaKey = schemaKey
        newTab.tableContext.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addServerDashboardTab() {
        if let existing = tabs.first(where: { $0.tabType == .serverDashboard }) {
            selectedTabId = existing.id
            return
        }
        let tabTitle = String(localized: "Server Dashboard")
        var newTab = QueryTab(title: tabTitle, tabType: .serverDashboard)
        newTab.tableContext.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addTerminalTab(databaseName: String = "") {
        if let existing = tabs.first(where: { $0.tabType == .terminal }) {
            selectedTabId = existing.id
            return
        }
        let tabTitle = String(localized: "Terminal")
        var newTab = QueryTab(title: tabTitle, tabType: .terminal)
        newTab.tableContext.databaseName = databaseName
        newTab.tableContext.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addPreviewTableTab(
        tableName: String,
        databaseType: DatabaseType = .mysql,
        databaseName: String = "",
        quoteIdentifier: ((String) -> String)? = nil
    ) throws {
        if let existing = tabs.first(where: {
            $0.tabType == .table && $0.tableContext.tableName == tableName && $0.tableContext.databaseName == databaseName
        }) {
            selectedTabId = existing.id
            return
        }

        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let query = try QueryTab.buildBaseTableQuery(
            tableName: tableName, databaseType: databaseType, quoteIdentifier: quoteIdentifier
        )
        var newTab = QueryTab(
            title: tableName,
            query: query,
            tabType: .table,
            tableName: tableName
        )
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.tableContext.databaseName = databaseName
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
    ) throws -> Bool {
        guard let selectedId = selectedTabId,
              let selectedIndex = tabs.firstIndex(where: { $0.id == selectedId })
        else {
            return false
        }

        let query = try QueryTab.buildBaseTableQuery(
            tableName: tableName,
            databaseType: databaseType,
            schemaName: schemaName,
            quoteIdentifier: quoteIdentifier
        )
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize

        var tab = tabs[selectedIndex]
        tab.tabType = .table
        tab.title = tableName
        tab.tableContext.tableName = tableName
        tab.content.query = query
        tab.schemaVersion += 1
        tab.execution.executionTime = nil
        tab.execution.statusMessage = nil
        tab.execution.errorMessage = nil
        tab.execution.lastExecutedAt = nil
        tab.display.resultsViewMode = .data
        tab.sortState = SortState()
        tab.selectedRowIndices = []
        tab.pendingChanges = TabChangeSnapshot()
        tab.hasUserInteraction = false
        tab.tableContext.isView = isView
        tab.tableContext.isEditable = !isView
        tab.filterState = TabFilterState()
        tab.columnLayout = ColumnLayoutState()
        tab.pagination = PaginationState(pageSize: pageSize)
        tab.tableContext.databaseName = databaseName
        tab.tableContext.schemaName = schemaName
        tab.isPreview = isPreview
        tabs[selectedIndex] = tab
        tabStructureVersion += 1
        return true
    }

    func updateTab(_ tab: QueryTab) {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index] = tab
        }
    }

    func markTabRenamed(_ tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        tabStructureVersion += 1
    }

    deinit {
        #if DEBUG
        Logger(subsystem: "com.TablePro", category: "QueryTabManager")
            .debug("QueryTabManager deallocated")
        #endif
    }
}
