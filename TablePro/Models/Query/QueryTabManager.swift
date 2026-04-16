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
        didSet { _tabIndexMapDirty = true }
    }

    var selectedTabId: UUID?

    @ObservationIgnored private var _tabIndexMap: [UUID: Int] = [:]
    @ObservationIgnored private var _tabIndexMapDirty = true

    // MARK: - Closed Tab History (Cmd+Shift+T reopen)

    /// Closed tab snapshots for reopen. Capped to limit memory.
    @ObservationIgnored private var closedTabHistory: [QueryTab] = []
    private static let maxClosedHistory = 20

    func pushClosedTab(_ tab: QueryTab) {
        closedTabHistory.append(tab)
        if closedTabHistory.count > Self.maxClosedHistory {
            closedTabHistory.removeFirst()
        }
    }

    func popClosedTab() -> QueryTab? {
        closedTabHistory.popLast()
    }

    var hasClosedTabs: Bool { !closedTabHistory.isEmpty }

    // MARK: - MRU Tab Activation Order

    /// Most-recently-used tab order for smart selection after close.
    @ObservationIgnored private(set) var tabActivationOrder: [UUID] = []

    func trackActivation(_ tabId: UUID) {
        tabActivationOrder.removeAll { $0 == tabId }
        tabActivationOrder.append(tabId)
        // Cap to prevent unbounded growth from open/close cycles
        if tabActivationOrder.count > 50 {
            tabActivationOrder.removeFirst(tabActivationOrder.count - 50)
        }
    }

    /// Returns the most recently active tab ID, excluding a given ID.
    func mruTabId(excluding id: UUID) -> UUID? {
        for candidateId in tabActivationOrder.reversed() {
            if candidateId != id, tabs.contains(where: { $0.id == candidateId }) {
                return candidateId
            }
        }
        return nil
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

    init() {
        // Start with no tabs - shows empty state
        tabs = []
        selectedTabId = nil
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

    // MARK: - Tab Management

    func addTab(initialQuery: String? = nil, title: String? = nil, databaseName: String = "", sourceFileURL: URL? = nil) {
        if let sourceFileURL,
           let existingIndex = tabs.firstIndex(where: { $0.sourceFileURL == sourceFileURL }) {
            if let query = initialQuery {
                tabs[existingIndex].query = query
            }
            selectedTabId = tabs[existingIndex].id
            return
        }

        let tabTitle = title ?? Self.nextQueryTitle(existingTabs: tabs)
        var newTab = QueryTab(title: tabTitle, tabType: .query)

        if let query = initialQuery {
            newTab.query = query
            newTab.hasUserInteraction = true
        }

        newTab.databaseName = databaseName
        newTab.sourceFileURL = sourceFileURL
        if sourceFileURL != nil {
            newTab.savedFileContent = newTab.query
        }
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addTableTab(
        tableName: String,
        databaseType: DatabaseType = .mysql,
        databaseName: String = "",
        quoteIdentifier: ((String) -> String)? = nil
    ) {
        // Check if table tab already exists (match on databaseName)
        if let existingTab = tabs.first(where: {
            $0.tabType == .table && $0.tableName == tableName && $0.databaseName == databaseName
        }) {
            selectedTabId = existingTab.id
            return
        }

        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let query = QueryTab.buildBaseTableQuery(
            tableName: tableName, databaseType: databaseType, quoteIdentifier: quoteIdentifier
        )
        var newTab = QueryTab(
            title: tableName,
            query: query,
            tabType: .table,
            tableName: tableName
        )
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.databaseName = databaseName
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addCreateTableTab(databaseName: String = "") {
        let tabTitle = String(localized: "Create Table")
        var newTab = QueryTab(title: tabTitle, tabType: .createTable)
        newTab.databaseName = databaseName
        newTab.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addERDiagramTab(schemaKey: String, databaseName: String = "") {
        let tabTitle = String(localized: "ER Diagram")
        var newTab = QueryTab(title: tabTitle, tabType: .erDiagram)
        newTab.databaseName = databaseName
        newTab.erDiagramSchemaKey = schemaKey
        newTab.isEditable = false
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
        newTab.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    func addPreviewTableTab(
        tableName: String,
        databaseType: DatabaseType = .mysql,
        databaseName: String = "",
        quoteIdentifier: ((String) -> String)? = nil
    ) {
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let query = QueryTab.buildBaseTableQuery(
            tableName: tableName, databaseType: databaseType, quoteIdentifier: quoteIdentifier
        )
        var newTab = QueryTab(
            title: tableName,
            query: query,
            tabType: .table,
            tableName: tableName
        )
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.databaseName = databaseName
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
    ) -> Bool {
        guard let selectedId = selectedTabId,
              let selectedIndex = tabs.firstIndex(where: { $0.id == selectedId })
        else {
            return false
        }

        let query = QueryTab.buildBaseTableQuery(
            tableName: tableName,
            databaseType: databaseType,
            schemaName: schemaName,
            quoteIdentifier: quoteIdentifier
        )
        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize

        // Build locally and write back once to avoid 14 CoW copies (UI-11).
        var tab = tabs[selectedIndex]
        tab.rowBuffer = RowBuffer()
        tab.tabType = .table
        tab.title = tableName
        tab.tableName = tableName
        tab.query = query
        tab.resultVersion += 1
        tab.executionTime = nil
        tab.statusMessage = nil
        tab.errorMessage = nil
        tab.lastExecutedAt = nil
        tab.showStructure = false
        tab.sortState = SortState()
        tab.selectedRowIndices = []
        tab.pendingChanges = TabPendingChanges()
        tab.hasUserInteraction = false
        tab.isView = isView
        tab.isEditable = !isView
        tab.filterState = TabFilterState()
        tab.columnLayout = ColumnLayoutState()
        tab.pagination = PaginationState(pageSize: pageSize)
        tab.databaseName = databaseName
        tab.schemaName = schemaName
        tab.isPreview = isPreview
        tabs[selectedIndex] = tab
        return true
    }

    func updateTab(_ tab: QueryTab) {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index] = tab
        }
    }

    deinit {
        #if DEBUG
        Logger(subsystem: "com.TablePro", category: "QueryTabManager")
            .debug("QueryTabManager deallocated")
        #endif
    }
}
