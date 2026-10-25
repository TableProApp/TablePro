//
//  QueryTabManager.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProUtilities

@MainActor
final class QueryTabManager: ObservableObject {
    @Published var tabs: [QueryTab] = [] {
        didSet {
            _tabIndexMapDirty = true
            _visibleTabs = nil
            if oldValue.map(\.id) != tabs.map(\.id) {
                tabStructureVersion += 1
                pruneActivations(keeping: tabs)
            }
            publishAnchorChange(oldTabs: oldValue, newTabs: tabs)
            syncTabSessionRegistry(oldTabs: oldValue, newTabs: tabs)
            reconcileVisibleContainer()
        }
    }

    // Every selection writer lands here; a view modifier can't, as a connection the window isn't showing has no views.
    @Published var selectedTabId: UUID? {
        didSet {
            guard selectedTabId != oldValue else { return }
            recordSelectedTabContainer()
            reconcileVisibleContainer()
            scheduleActivationRecord()
        }
    }

    // The database or schema, whichever the engine switches; nil when it switches neither and every tab shares one entry.
    let containerTarget: ContainerSwitchTarget?

    // The strip lists this container's tabs plus unbound ones (nil: all). Switching entries never closes a tab.
    @Published private(set) var visibleContainer: String?

    // Fired when a selection carried the window into another entry, so the connection browses it too.
    var onVisibleContainerReconciled: (() -> Void)?

    private(set) var containerTabHistory = ContainerTabHistory()
    private var _visibleTabs: [QueryTab]?

    // Only a frontmost selection is recorded: a background restore's tab would otherwise become the next Control-Tab target.
    var isFrontmost = false {
        didSet {
            guard isFrontmost != oldValue else { return }
            scheduleActivationRecord()
        }
    }

    @Published var tabStructureVersion: Int = 0

    var pendingFocusTabId: UUID?

    // A shared sequence, not a time: two selections in one turn still order, across every connection in the window.
    private(set) var activationSequence: [UUID: UInt64] = [:]
    private static var lastActivationSequence: UInt64 = 0
    private var activationRecordPending = false

    private var _tabIndexMap: [UUID: Int] = [:]
    private var _tabIndexMapDirty = true

    private let globalTabsProvider: () -> [QueryTab]
    private weak var tabSessionRegistry: TabSessionRegistry?

    init(
        containerTarget: ContainerSwitchTarget? = nil,
        visibleContainer: String? = nil,
        globalTabsProvider: @escaping () -> [QueryTab] = { [] },
        tabSessionRegistry: TabSessionRegistry? = nil
    ) {
        self.containerTarget = containerTarget
        self.visibleContainer = containerTarget == nil ? nil : visibleContainer.flatMap { $0.isEmpty ? nil : $0 }
        self.globalTabsProvider = globalTabsProvider
        self.tabSessionRegistry = tabSessionRegistry
    }

    // Selection lands on the tab that took its strip slot; an entry left empty shows its empty state, not another's tab.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTab?.id == id
        let stripIndex = visibleTabs.firstIndex { $0.id == id }
        tabs.remove(at: index)
        guard wasSelected else { return }
        let remaining = visibleTabs
        guard let stripIndex, remaining.indices.contains(stripIndex) else {
            selectedTabId = remaining.last?.id
            return
        }
        selectedTabId = remaining[stripIndex].id
    }

    // Built and assigned once: each tabs write bumps tabStructureVersion and republishes anchors for a list never shown.
    func moveTab(id: UUID, to destination: Int) {
        let strip = visibleTabs
        guard let source = strip.firstIndex(where: { $0.id == id }) else { return }
        let group = Self.group(containing: source, in: strip)
        let clamped = min(max(destination, group.lowerBound), group.upperBound)
        guard clamped != source else { return }

        let neighbourId = strip[clamped].id
        var reordered = tabs
        guard let flatSource = reordered.firstIndex(where: { $0.id == id }) else { return }
        let moving = reordered.remove(at: flatSource)
        guard let neighbour = reordered.firstIndex(where: { $0.id == neighbourId }) else { return }
        reordered.insert(moving, at: clamped > source ? neighbour + 1 : neighbour)
        tabs = reordered
    }

    func canMoveTab(id: UUID, by offset: Int) -> Bool {
        let strip = visibleTabs
        guard let index = strip.firstIndex(where: { $0.id == id }) else { return false }
        return Self.group(containing: index, in: strip).contains(index + offset)
    }

    // A tab never crosses the boundary between the pinned run and the rest.
    private static func group(containing index: Int, in strip: [QueryTab]) -> ClosedRange<Int> {
        let pinnedCount = strip.prefix { $0.isPinned }.count
        return strip[index].isPinned ? 0 ... pinnedCount - 1 : pinnedCount ... strip.count - 1
    }

    func moveTab(id: UUID, by offset: Int) {
        guard let index = visibleTabs.firstIndex(where: { $0.id == id }) else { return }
        moveTab(id: id, to: index + offset)
    }

    // Sole mutator of isPreview; one way on purpose, so a kept tab can't be thrown away by a later sidebar click.
    func promotePreviewTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPreview else { return }
        mutate(at: index) { $0.isPreview = false }
    }

    func canPromotePreviewTab(id: UUID) -> Bool {
        tabs.first { $0.id == id }?.isPreview ?? false
    }

    func isPinned(id: UUID) -> Bool {
        tabs.first { $0.id == id }?.isPinned ?? false
    }

    // A preview is kept first, so a sidebar click never retargets a pinned tab.
    func setPinned(_ pinned: Bool, id: UUID) {
        guard tabs.contains(where: { $0.id == id && $0.isPinned != pinned }) else { return }
        if pinned {
            promotePreviewTab(id: id)
        }
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let before = tabs.map(\.id)
        var tab = tabs[source]
        tab.isPinned = pinned
        var others = tabs
        others.remove(at: source)
        // Partitioned first, because an adopted or reopened pin can sit after unpinned tabs.
        let pins = others.filter { $0.isPinned }
        let rest = others.filter { !$0.isPinned }
        tabs = pins + [tab] + rest
        // The save follows `tabStructureVersion`, which only an id reorder bumps.
        if tabs.map(\.id) == before {
            tabStructureVersion += 1
        }
    }

    func selectTab(at index: Int) {
        guard let id = tabId(at: index) else { return }
        selectedTabId = id
    }

    func selectTab(offsetBy offset: Int) {
        guard let id = tabId(offsetBy: offset) else { return }
        selectedTabId = id
    }

    // On screen: the selected tab of the connection the key window shows.
    func isShowing(_ id: UUID) -> Bool {
        isFrontmost && selectedTabId == id
    }

    func tabId(at index: Int) -> UUID? {
        let strip = visibleTabs
        guard strip.indices.contains(index) else { return nil }
        return strip[index].id
    }

    func tabId(offsetBy offset: Int) -> UUID? {
        let strip = visibleTabs
        guard !strip.isEmpty else { return nil }
        let current = selectedTab.flatMap { tab in strip.firstIndex { $0.id == tab.id } } ?? 0
        let count = strip.count
        return strip[((current + offset) % count + count) % count].id
    }

    // MARK: - Recency

    // Recorded once the turn settles: opening into another connection selects twice in one turn, the first never drawn.
    private func scheduleActivationRecord() {
        guard isFrontmost, !activationRecordPending else { return }
        activationRecordPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.recordSettledActivation() }
        }
    }

    private func recordSettledActivation() {
        activationRecordPending = false
        guard isFrontmost, let id = selectedTab?.id else { return }
        recordActivation(of: id)
    }

    private func recordActivation(of id: UUID) {
        Self.lastActivationSequence += 1
        activationSequence[id] = Self.lastActivationSequence
    }

    private func pruneActivations(keeping tabs: [QueryTab]) {
        guard !activationSequence.isEmpty else { return }
        let openIds = Set(tabs.map(\.id))
        activationSequence = activationSequence.filter { openIds.contains($0.key) }
    }

    func bindTabSessionRegistry(_ registry: TabSessionRegistry) {
        tabSessionRegistry = registry
        for tab in tabs where registry.session(for: tab.id) == nil {
            registry.register(TabSession(id: tab.id))
        }
    }

    // Publishes only when the set of held-open containers can change; a keystroke leaves the anchors identical.
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
        return selectedTabId == nil ? visibleTabs.first : nil
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

    func addTab(
        initialQuery: String? = nil,
        title: String? = nil,
        databaseName: String = "",
        sourceFileURL: URL? = nil,
        sourceFileStamp: FileStamp? = nil,
        sourceFileEncoding: FileTextEncoding? = nil,
        claimFocus: Bool = false
    ) {
        if let sourceFileURL,
           let existingIndex = tabs.firstIndex(where: { $0.content.sourceFileURL == sourceFileURL }) {
            if let query = initialQuery {
                adoptReopenedFile(
                    at: existingIndex,
                    content: query,
                    stamp: sourceFileStamp,
                    encoding: sourceFileEncoding
                )
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
        bindToVisibleContainer(&newTab)
        newTab.content.sourceFileURL = sourceFileURL
        if sourceFileURL != nil {
            FileTabBaseline.adopt(
                text: newTab.content.query,
                stamp: sourceFileStamp,
                encoding: sourceFileEncoding,
                into: &newTab.content
            )
        }
        tabs.append(newTab)
        selectedTabId = newTab.id
        if claimFocus {
            pendingFocusTabId = newTab.id
        }
    }

    // Shown, not reloaded over: setText isn't undoable, so a dirty buffer is kept. The baseline moves with the text.
    private func adoptReopenedFile(at index: Int, content: String, stamp: FileStamp?, encoding: FileTextEncoding?) {
        // isFileDirty reads a missing baseline as clean, so an unknown baseline must not license overwriting the tab.
        guard tabs[index].content.savedFileContent != nil, !tabs[index].content.isFileDirty else { return }
        FileTabBaseline.adopt(text: content, stamp: stamp, encoding: encoding, into: &tabs[index].content)
    }

    func adoptTab(_ tab: QueryTab, claimFocus: Bool = false) {
        var tab = tab
        bindToVisibleContainer(&tab)
        tabs.append(tab)
        selectedTabId = tab.id
        if claimFocus {
            pendingFocusTabId = tab.id
        }
    }

    @Published var onTableOpened: ((
        _ tableName: String,
        _ schemaName: String?,
        _ databaseName: String,
        _ isView: Bool,
        _ objectType: TableInfo.TableType?,
        _ isPreview: Bool
    ) -> Void)?

    // Execution owners listen here, not at call sites: a retarget that skipped invalidation painted stale rows into the tab.
    @Published var onTabRetargeted: ((UUID) -> Void)?

    @Published var onTableSchemaResolved: ((_ tableName: String, _ databaseName: String, _ schemaName: String) -> Void)?

    // The recorder needs the kind: a MariaDB sequence recorded as "not a table" came back as a view offering Drop View.
    private func notifyTableOpened(
        tableName: String, schemaName: String?, databaseName: String,
        isView: Bool, objectType: TableInfo.TableType?, isPreview: Bool
    ) {
        onTableOpened?(tableName, schemaName, databaseName, isView, objectType, isPreview)
    }

    // The open was recorded before the schema was known; without this the record follows whichever schema is browsed.
    func adoptResolvedSchema(_ schemaName: String, at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].tableContext.schemaName = schemaName
        guard let tableName = tabs[index].tableContext.tableName else { return }
        onTableSchemaResolved?(tableName, tabs[index].tableContext.databaseName, schemaName)
    }

    // Prefers the selected tab: a table can hold several tabs, and array order sent a sidebar click to the other copy.
    func tabShowingTable(
        named tableName: String, databaseName: String, schemaName: String?, isTemporary: Bool = false
    ) -> QueryTab? {
        func matches(_ tab: QueryTab) -> Bool {
            tab.tabType == .table
                && tab.tableContext.tableName == tableName
                && tab.tableContext.databaseName == databaseName
                && tab.tableContext.schemaName == schemaName
                && tab.tableContext.isTemporary == isTemporary
        }
        if let selected = selectedTab, matches(selected) { return selected }
        return tabs.first(where: matches)
    }

    // Returns false when an existing tab was reselected: callers must not write per-tab payload onto a tab they didn't create.
    @discardableResult
    func addTableTab(
        tableName: String,
        databaseType: DatabaseType = .mysql,
        databaseName: String = "",
        schemaName: String? = nil,
        isView: Bool = false,
        objectType: TableInfo.TableType? = nil,
        isTemporary: Bool = false,
        isPreview: Bool = false,
        allowsDuplicate: Bool = false,
        quoteIdentifier: ((String) -> String)? = nil
    ) throws -> Bool {
        if !allowsDuplicate, let existingTab = tabShowingTable(
            named: tableName, databaseName: databaseName, schemaName: schemaName, isTemporary: isTemporary
        ) {
            selectedTabId = existingTab.id
            notifyTableOpened(
                tableName: tableName, schemaName: schemaName, databaseName: databaseName,
                isView: isView, objectType: objectType, isPreview: isPreview
            )
            return false
        }

        let pageSize = PluginManager.shared.paginationCapability(for: databaseType)
            .clampedRowCount(AppSettingsManager.shared.dataGrid.defaultPageSize)
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
        newTab.tableContext.objectType = objectType
        newTab.tableContext.isTemporary = isTemporary
        newTab.tableContext.schemaName = schemaName
        newTab.isPreview = isPreview
        tabs.append(newTab)
        selectedTabId = newTab.id
        notifyTableOpened(
            tableName: tableName, schemaName: schemaName, databaseName: databaseName,
            isView: isView, objectType: objectType, isPreview: isPreview
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

    func addCreateTableTab(databaseName: String = "", schemaName: String? = nil) {
        let tabTitle = String(localized: "Create Table")
        var newTab = QueryTab(title: tabTitle, tabType: .createTable)
        newTab.tableContext.databaseName = databaseName
        newTab.tableContext.schemaName = schemaName
        bindToVisibleContainer(&newTab)
        newTab.tableContext.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    // schemaName is the schema drawn; on engines whose entries are schemas it is also the tab's entry.
    func addERDiagramTab(schemaKey: String, databaseName: String = "", schemaName: String? = nil) {
        let tabTitle = String(localized: "ER Diagram")
        var newTab = QueryTab(title: tabTitle, tabType: .erDiagram)
        newTab.tableContext.databaseName = databaseName
        newTab.tableContext.schemaName = schemaName
        bindToVisibleContainer(&newTab)
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

    func addObjectSourceTab(objectRef: DatabaseObjectRef) {
        if let existing = tabs.first(where: {
            $0.tabType == .objectSource && $0.display.objectRef?.namesSameObject(as: objectRef) == true
        }) {
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

    func addVersionHistoryTab(subject: VersionHistorySubject, title: String) {
        if let existing = tabs.first(where: {
            $0.tabType == .versionHistory && $0.display.versionHistorySubject == subject
        }) {
            selectedTabId = existing.id
            return
        }
        var newTab = QueryTab(title: title, tabType: .versionHistory)
        newTab.tableContext.isEditable = false
        newTab.display.versionHistorySubject = subject
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    @discardableResult
    func addTableListingTab(title: String, databaseName: String, schemaName: String?) -> UUID {
        let schemaName = schemaName.flatMap { $0.isEmpty ? nil : $0 }
        if let existing = tabs.first(where: {
            $0.tabType == .tableListing
                && $0.tableContext.databaseName == databaseName
                && $0.tableContext.schemaName == schemaName
        }) {
            selectedTabId = existing.id
            return existing.id
        }
        var newTab = QueryTab(title: title, tabType: .tableListing)
        newTab.tableContext.isEditable = false
        newTab.tableContext.databaseName = databaseName
        newTab.tableContext.schemaName = schemaName
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
        return newTab.id
    }

    // Qualified by schema where tables are listed per schema, or two listings in one database would share a label.
    static func tableListingTitle(kindTitle: String, schemaName: String?) -> String {
        guard let schemaName, !schemaName.isEmpty else { return kindTitle }
        return String(format: String(localized: "%@: %@"), kindTitle, schemaName)
    }

    static var versionHistoryFallbackTitle: String {
        String(localized: "History")
    }

    static func versionHistoryTitle(for name: String) -> String {
        guard !name.isBlank else { return versionHistoryFallbackTitle }
        return String(format: String(localized: "History: %@"), name)
    }

    static func objectSourceTitle(for objectRef: DatabaseObjectRef) -> String {
        let format: String
        switch objectRef.kind {
        case .procedure: format = String(localized: "Procedure: %@")
        case .function:  format = String(localized: "Function: %@")
        case .trigger:   format = String(localized: "Trigger: %@")
        case .userType:  format = String(localized: "Type: %@")
        case .view:      format = String(localized: "View: %@")
        case .materializedView: format = String(localized: "Materialized View: %@")
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

    // Returns false when no tab is selected; on true the caller runs the query.
    @discardableResult
    func replaceTabContent(
        tableName: String, databaseType: DatabaseType = .mysql,
        isView: Bool = false, objectType: TableInfo.TableType? = nil,
        isTemporary: Bool = false,
        databaseName: String = "",
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
        let pageSize = PluginManager.shared.paginationCapability(for: databaseType)
            .clampedRowCount(AppSettingsManager.shared.dataGrid.defaultPageSize)

        onTabRetargeted?(selectedId)

        var tab = tabs[selectedIndex]
        tab.tabType = .table
        tab.title = Self.tabTitle(name: tableName, schema: schemaName, databaseType: databaseType)
        // Built whole: a leftover field describes the previous table, and its primary keys matched a keyless table's edits.
        tab.tableContext = TabTableContext(
            tableName: tableName,
            databaseName: databaseName,
            schemaName: schemaName,
            isEditable: !isView,
            isView: isView,
            objectType: objectType,
            isTemporary: isTemporary
        )
        // Fresh too: a query tab keeps its file binding, so a retargeted table's Save wrote its query into that file.
        tab.content = TabQueryContent(query: query)
        tab.schemaVersion += 1
        tab.execution.executionTime = nil
        tab.execution.statusMessage = nil
        tab.execution.errorMessage = nil
        tab.execution.lastExecutedAt = nil
        tab.display.resultsViewMode = .data
        tab.display.resultSets = []
        tab.display.activeResultSetId = nil
        tab.sortState = SortState()
        tab.restoredSortSource = .unset
        tab.selectionSnapshot = .empty
        tab.pendingChanges = TabChangeSnapshot()
        tab.hasUserInteraction = false
        tab.filterState = TabFilterState()
        tab.valueFilter = GridValueFilterState()
        tab.columnLayout = ColumnLayoutState()
        tab.pagination = PaginationState(pageSize: pageSize)
        // An unconsumed restore describes the old rows; kept, it persists and applies to the new table on the next launch.
        tab.pendingRestoredSort = nil
        tab.restoredPage = nil
        tab.restoredPageSize = nil
        tab.restoredRowAnchor = nil
        tab.isPreview = isPreview
        tabs[selectedIndex] = tab
        tabStructureVersion += 1
        notifyTableOpened(
            tableName: tableName, schemaName: schemaName, databaseName: databaseName,
            isView: isView, objectType: objectType, isPreview: isPreview
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

// MARK: - Visible Container

extension QueryTabManager {
    var visibleTabs: [QueryTab] {
        if let cached = _visibleTabs { return cached }
        let listed = tabs.filter(isVisible)
        // Derived, so a pinned tab a restore, reopen or move appends still lands in the pinned run.
        let visible = listed.filter(\.isPinned) + listed.filter { !$0.isPinned }
        _visibleTabs = visible
        return visible
    }

    func containerName(of tab: QueryTab) -> String? {
        WorkspaceAnchoring.containerName(of: tab, target: containerTarget)
    }

    // A tab naming no container (a server dashboard, a query tab on a browse-following engine) shows in every entry.
    func isVisible(_ tab: QueryTab) -> Bool {
        guard let visibleContainer, let container = containerName(of: tab) else { return true }
        return container == visibleContainer
    }

    // Selection stays, falls back to the entry's last-used tab, or clears. Never moves the browse cursor; callers do that.
    func show(container: String?) {
        guard containerTarget != nil else { return }
        let container = container.flatMap { $0.isEmpty ? nil : $0 }
        if container != visibleContainer {
            setVisibleContainer(container)
        }
        let landing = selectionLanding(in: container)
        guard landing != selectedTabId else { return }
        selectedTabId = landing
    }

    // Entry goes in front before selecting, so a new window never reads as a user pick that moves the database.
    func seed(with tab: QueryTab) {
        tabs = [tab]
        show(container: containerName(of: tab) ?? visibleContainer)
        selectedTabId = tab.id
    }

    // Unbound tabs ran against whatever the connection browsed next, so a statement typed for one schema ran on another.
    func bindToVisibleContainer(_ tab: inout QueryTab) {
        guard let visibleContainer,
              Self.bindsToContainer(tab.tabType),
              containerName(of: tab) == nil
        else { return }
        switch containerTarget {
        case .database:
            tab.tableContext.databaseName = visibleContainer
        case .schema:
            tab.tableContext.schemaName = visibleContainer
        case nil:
            break
        }
    }

    // The entry on screen, not the browse cursor, which lags a switch and would pull the window back to the old entry.
    func openingDatabase(browsing browseDatabase: String) -> String {
        guard containerTarget == .database, let visibleContainer else { return browseDatabase }
        return visibleContainer
    }

    // Tabs from before entry binding ran against the connection's container, which is the one the restore lands in.
    func bindUnboundTabs() {
        guard visibleContainer != nil,
              tabs.contains(where: { Self.bindsToContainer($0.tabType) && containerName(of: $0) == nil })
        else { return }
        var bound = tabs
        for index in bound.indices {
            bindToVisibleContainer(&bound[index])
        }
        tabs = bound
    }

    // Server-wide tabs answer for the whole connection, so they belong to every entry.
    private static func bindsToContainer(_ type: TabType) -> Bool {
        switch type {
        case .query, .table, .createTable, .erDiagram, .objectSource, .tableListing:
            return true
        case .serverDashboard, .usersRoles, .insights, .versionHistory:
            return false
        }
    }

    private func selectionLanding(in container: String?) -> UUID? {
        let selected = selectedTabId.flatMap { id in tabs.first { $0.id == id } }
        guard let container else { return selected?.id ?? visibleTabs.first?.id }
        if let selected, containerName(of: selected) == container {
            return selected.id
        }
        if let remembered = containerTabHistory.tabToSelect(
            inContainer: container, among: tabs, target: containerTarget
        ) {
            return remembered
        }
        if let selected, isVisible(selected) {
            return selected.id
        }
        return visibleTabs.last?.id
    }

    // The selected tab is always listed; a selection naming an unlisted tab is mid close or adoption and left alone.
    fileprivate func reconcileVisibleContainer() {
        guard containerTarget != nil,
              let id = selectedTabId,
              let tab = tabs.first(where: { $0.id == id }),
              let container = containerName(of: tab),
              container != visibleContainer
        else { return }
        containerTabHistory.record(tabId: id, container: container)
        setVisibleContainer(container)
        onVisibleContainerReconciled?()
    }

    fileprivate func recordSelectedTabContainer() {
        guard let id = selectedTabId, let tab = tabs.first(where: { $0.id == id }) else { return }
        containerTabHistory.record(tabId: id, container: containerName(of: tab))
    }

    private func setVisibleContainer(_ container: String?) {
        visibleContainer = container
        _visibleTabs = nil
        AppEvents.shared.visibleContainerChanged.send()
    }
}
