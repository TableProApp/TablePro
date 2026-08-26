//
//  QueryTabManager.swift
//  TablePro
//

import Combine
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
            publishAnchorChange(oldTabs: oldValue, newTabs: tabs)
            syncTabSessionRegistry(oldTabs: oldValue, newTabs: tabs)
        }
    }

    var selectedTabId: UUID?

    var tabStructureVersion: Int = 0

    @ObservationIgnored var pendingFocusTabId: UUID?

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

    /// Closing a tab used to mean closing its window, because a tab was a window. Selection
    /// lands on the tab that took its place so the pane never blanks while others are open.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTab?.id == id
        tabs.remove(at: index)
        guard wasSelected else { return }
        selectedTabId = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
    }

    /// Reorders the strip. A pure permutation: the same tabs, a different order, and the selection
    /// stays on whichever tab it was on rather than on the position that tab vacated.
    ///
    /// The array is rebuilt and assigned once rather than mutated twice, because `tabs.didSet`
    /// bumps `tabStructureVersion` and republishes the workspace anchors on every write, and the
    /// state between a `remove` and an `insert` is a tab list the user never had.
    func moveTab(id: UUID, to destination: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(destination, 0), tabs.count - 1)
        guard clamped != source else { return }

        var reordered = tabs
        reordered.insert(reordered.remove(at: source), at: clamped)
        tabs = reordered
    }

    /// Whether `tab` can move one place in `offset`'s direction, so a menu item can dim instead of
    /// being offered and doing nothing.
    func canMoveTab(id: UUID, by offset: Int) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return tabs.indices.contains(index + offset)
    }

    func moveTab(id: UUID, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        moveTab(id: id, to: index + offset)
    }

    /// Keeps a preview tab, so the next table opened from the sidebar lands in a tab of its own
    /// instead of replacing this one. The single mutator of `isPreview`: every promotion path,
    /// the sidebar's, the editor's and the tab strip's, comes through here.
    ///
    /// Promotion never reorders. A tab that moves as it is kept would be a different feature,
    /// which is what pinning is in the editors that offer both.
    ///
    /// One way, deliberately. Nothing turns a kept tab back into a preview, so a tab the user
    /// asked to hold on to cannot be thrown away by a later click.
    func promotePreviewTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPreview else { return }
        mutate(at: index) { $0.isPreview = false }
    }

    /// Whether keeping this tab would change anything, so a menu item can dim rather than be
    /// offered and do nothing.
    func canPromotePreviewTab(id: UUID) -> Bool {
        tabs.first { $0.id == id }?.isPreview ?? false
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabId = tabs[index].id
    }

    func selectTab(offsetBy offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = selectedTab.flatMap { tab in tabs.firstIndex { $0.id == tab.id } } ?? 0
        let count = tabs.count
        selectedTabId = tabs[((current + offset) % count + count) % count].id
    }

    func bindTabSessionRegistry(_ registry: TabSessionRegistry) {
        tabSessionRegistry = registry
        for tab in tabs where registry.session(for: tab.id) == nil {
            registry.register(TabSession(id: tab.id))
        }
    }

    /// The workspace rail lists a container while a tab holds it open, so it reloads when
    /// that set can have changed. Every other tab mutation, a keystroke above all, leaves
    /// the anchors identical and publishes nothing.
    private func publishAnchorChange(oldTabs: [QueryTab], newTabs: [QueryTab]) {
        guard WorkspaceAnchoring.anchors(in: oldTabs) != WorkspaceAnchoring.anchors(in: newTabs) else {
            return
        }
        AppEvents.shared.workspaceTabsChanged.send()
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
                registry.register(TabSession(id: addedTab.id))
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

    func addTab(initialQuery: String? = nil, title: String? = nil, databaseName: String = "", sourceFileURL: URL? = nil, claimFocus: Bool = false) {
        if let sourceFileURL,
           let existingIndex = tabs.firstIndex(where: { $0.content.sourceFileURL == sourceFileURL }) {
            if let query = initialQuery {
                adoptReopenedFile(at: existingIndex, content: query, url: sourceFileURL)
            }
            selectedTabId = tabs[existingIndex].id
            return
        }

        let tabTitle: String
        if let title {
            tabTitle = title
        } else if let sourceFileURL {
            tabTitle = QueryTab.fileDisplayTitle(for: sourceFileURL)
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
            newTab.content.loadMtime = FileTextLoader.modificationDate(of: sourceFileURL)
        }
        tabs.append(newTab)
        selectedTabId = newTab.id
        if claimFocus {
            pendingFocusTabId = newTab.id
        }
    }

    /// A file that is already open is shown, not reloaded over.
    ///
    /// Opening it again is a request to look at it, so the buffer is replaced only when there is
    /// nothing of the user's in it. A tab with unsaved edits keeps them: `setText` on the editor
    /// resets its storage, so the replacement was not undoable and nothing asked first. The one
    /// path that does replace a dirty buffer is the file-changed-on-disk banner, which asks.
    ///
    /// The baseline moves with the buffer. Writing the text without it left the tab reading as
    /// dirty against content it had just loaded, and armed the same banner for a change it had
    /// already taken.
    private func adoptReopenedFile(at index: Int, content: String, url: URL) {
        /// An unknown baseline is not a licence to replace what the tab holds. `isFileDirty` reads a
        /// missing one as clean, so without this a tab that never learned what its file said would
        /// be overwritten by the very check meant to protect it.
        guard tabs[index].content.savedFileContent != nil, !tabs[index].content.isFileDirty else { return }
        tabs[index].content.query = content
        tabs[index].content.savedFileContent = content
        tabs[index].content.loadMtime = FileTextLoader.modificationDate(of: url)
        tabs[index].content.externalModificationDetected = false
    }

    /// Take an already-built tab, such as one rebuilt from the recently closed history, rather than
    /// minting a fresh one. Selecting it drives the window title, toolbar, and persistence through
    /// the usual `selectedTabId` observation.
    func adoptTab(_ tab: QueryTab, claimFocus: Bool = false) {
        tabs.append(tab)
        selectedTabId = tab.id
        if claimFocus {
            pendingFocusTabId = tab.id
        }
    }

    var onTableOpened: ((_ tableName: String, _ schemaName: String?, _ databaseName: String, _ isView: Bool, _ isPreview: Bool) -> Void)?

    /// Fired the instant a tab stops being about the table it was about. Whoever owns execution
    /// listens here rather than at the navigation call sites, because a retarget that forgets to
    /// invalidate is exactly how a finished query paints its rows into a tab showing something else.
    var onTabRetargeted: ((UUID) -> Void)?

    private func notifyTableOpened(
        tableName: String, schemaName: String?, databaseName: String, isView: Bool, isPreview: Bool
    ) {
        onTableOpened?(tableName, schemaName, databaseName, isView, isPreview)
    }

    /// The tab already showing this table, preferring the selected one.
    ///
    /// A table can legitimately hold more than one tab now, so plain array order would send a
    /// sidebar click on the table you are already looking at to the other copy of it.
    func tabShowingTable(
        named tableName: String, databaseName: String, schemaName: String?
    ) -> QueryTab? {
        func matches(_ tab: QueryTab) -> Bool {
            tab.tabType == .table
                && tab.tableContext.tableName == tableName
                && tab.tableContext.databaseName == databaseName
                && tab.tableContext.schemaName == schemaName
        }
        if let selected = selectedTab, matches(selected) { return selected }
        return tabs.first(where: matches)
    }

    /// - Parameter allowsDuplicate: `true` when the caller asked for a tab of its own, so a table
    ///   that is already open gets a second one instead of the existing tab being reselected.
    ///   "Open in New Tab" means what it says only if this reaches here.
    /// - Returns: `true` when a tab was created, `false` when an existing one was reselected.
    ///   Callers that carry per-tab payload state must not write it onto a tab they did not create.
    @discardableResult
    func addTableTab(
        tableName: String,
        databaseType: DatabaseType = .mysql,
        databaseName: String = "",
        schemaName: String? = nil,
        isView: Bool = false,
        isPreview: Bool = false,
        allowsDuplicate: Bool = false,
        quoteIdentifier: ((String) -> String)? = nil
    ) throws -> Bool {
        if !allowsDuplicate, let existingTab = tabShowingTable(
            named: tableName, databaseName: databaseName, schemaName: schemaName
        ) {
            selectedTabId = existingTab.id
            notifyTableOpened(
                tableName: tableName, schemaName: schemaName, databaseName: databaseName,
                isView: isView, isPreview: isPreview
            )
            return false
        }

        let pageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        let query = try QueryTab.buildBaseTableQuery(
            tableName: tableName,
            databaseType: databaseType,
            schemaName: schemaName,
            quoteIdentifier: quoteIdentifier
        )
        var newTab = QueryTab(
            title: Self.tabTitle(name: tableName, schema: schemaName, databaseType: databaseType),
            query: query,
            tabType: .table,
            tableName: tableName
        )
        newTab.pagination = PaginationState(pageSize: pageSize)
        newTab.tableContext.databaseName = databaseName
        newTab.tableContext.schemaName = schemaName
        newTab.isPreview = isPreview
        tabs.append(newTab)
        selectedTabId = newTab.id
        notifyTableOpened(
            tableName: tableName, schemaName: schemaName, databaseName: databaseName,
            isView: isView, isPreview: isPreview
        )
        return true
    }

    static func tabTitle(name: String, schema: String?, databaseType: DatabaseType) -> String {
        guard let schema, !schema.isEmpty else { return name }
        let defaultSchema = PluginMetadataRegistry.shared
            .snapshot(for: databaseType)?
            .schema.defaultSchemaName ?? ""
        return schema == defaultSchema ? name : "\(schema).\(name)"
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

    func addQueryInsightsTab() {
        if let existing = tabs.first(where: { $0.tabType == .insights }) {
            selectedTabId = existing.id
            return
        }
        let tabTitle = String(localized: "Query Insights")
        var newTab = QueryTab(title: tabTitle, tabType: .insights)
        newTab.tableContext.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    /// One tab per object, so opening the same routine twice returns to the tab already showing
    /// it, the way opening the same table does.
    func addObjectSourceTab(objectRef: DatabaseObjectRef) {
        if let existing = tabs.first(where: { $0.tabType == .objectSource && $0.display.objectRef == objectRef }) {
            selectedTabId = existing.id
            return
        }
        var newTab = QueryTab(title: Self.objectSourceTitle(for: objectRef), tabType: .objectSource)
        newTab.tableContext.isEditable = false
        newTab.tableContext.databaseName = objectRef.database
        newTab.tableContext.schemaName = objectRef.schema
        newTab.display.objectRef = objectRef
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    static func objectSourceTitle(for objectRef: DatabaseObjectRef) -> String {
        let format: String
        switch objectRef.kind {
        case .procedure: format = String(localized: "Procedure: %@")
        case .function:  format = String(localized: "Function: %@")
        case .trigger:   format = String(localized: "Trigger: %@")
        }
        return String(format: format, objectRef.displayIdentity)
    }

    func addUsersRolesTab() {
        if let existing = tabs.first(where: { $0.tabType == .usersRoles }) {
            selectedTabId = existing.id
            return
        }
        let tabTitle = String(localized: "Users & Roles")
        var newTab = QueryTab(title: tabTitle, tabType: .usersRoles)
        newTab.tableContext.isEditable = false
        newTab.hasUserInteraction = true
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

        onTabRetargeted?(selectedId)

        var tab = tabs[selectedIndex]
        tab.tabType = .table
        tab.title = Self.tabTitle(name: tableName, schema: schemaName, databaseType: databaseType)
        tab.tableContext.tableName = tableName
        tab.content.query = query
        tab.schemaVersion += 1
        tab.execution.executionTime = nil
        tab.execution.statusMessage = nil
        tab.execution.errorMessage = nil
        tab.execution.lastExecutedAt = nil
        tab.display.resultsViewMode = .data
        tab.display.resultSets = []
        tab.display.activeResultSetId = nil
        tab.sortState = SortState()
        tab.selectedRowIndices = []
        tab.pendingChanges = TabChangeSnapshot()
        tab.hasUserInteraction = false
        tab.tableContext.isView = isView
        tab.tableContext.isEditable = !isView
        tab.filterState = TabFilterState()
        tab.columnLayout = ColumnLayoutState()
        tab.pagination = PaginationState(pageSize: pageSize)
        // Retargeting points the tab at a different table, so a restore that has not been consumed
        // yet describes rows this tab no longer shows. Left behind, it is persisted against the new
        // table and applied to it on the next launch.
        tab.pendingRestoredSort = nil
        tab.restoredPage = nil
        tab.restoredPageSize = nil
        tab.tableContext.databaseName = databaseName
        tab.tableContext.schemaName = schemaName
        tab.isPreview = isPreview
        tabs[selectedIndex] = tab
        tabStructureVersion += 1
        notifyTableOpened(
            tableName: tableName, schemaName: schemaName, databaseName: databaseName,
            isView: isView, isPreview: isPreview
        )
        return true
    }

    func updateTab(_ tab: QueryTab) {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index] = tab
        }
    }

    @discardableResult
    func mutate(tabId: UUID, _ block: (inout QueryTab) -> Void) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else {
            return false
        }
        block(&tabs[index])
        return true
    }

    @discardableResult
    func mutate(at index: Int, _ block: (inout QueryTab) -> Void) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        block(&tabs[index])
        return true
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
