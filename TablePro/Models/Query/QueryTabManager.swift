//
//  QueryTabManager.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProUtilities

/// Manager for query tabs
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

    /// Every writer of the selection comes through here, which makes this the one place that sees
    /// every tab the user switches to: a click in the strip, Command 1 to 9, a new tab, a table
    /// opened from the sidebar, a reopened tab and the neighbour a close lands on alike. A view
    /// modifier could not stand in for it, because a connection the window is not showing has its
    /// views unparented.
    @Published var selectedTabId: UUID? {
        didSet {
            guard selectedTabId != oldValue else { return }
            recordSelectedTabContainer()
            reconcileVisibleContainer()
            scheduleActivationRecord()
        }
    }

    /// What a tab's entry is decided by: the database on an engine that switches databases, the
    /// schema on one that only switches schemas. Nil where the engine switches neither, and every
    /// tab is in the connection's one entry.
    let containerTarget: ContainerSwitchTarget?

    /// The connections-strip entry this window shows: the strip lists only that container's tabs,
    /// plus the ones that name no container. Nil shows every tab.
    ///
    /// A switch never closes a tab, it only changes which entry is in front; the tabs of the others
    /// are kept and come back with their entry.
    @Published private(set) var visibleContainer: String?

    /// Told when the selection carried the window into another entry, such as a tab picked from
    /// the recent-tabs list or rebound to another database, so the connection can browse it too.
    var onVisibleContainerReconciled: (() -> Void)?

    private(set) var containerTabHistory = ContainerTabHistory()
    private var _visibleTabs: [QueryTab]?

    /// Whether the window shows this connection's tabs, in the key window. The window sets it, for
    /// every connection it hosts at once. Only then is a selection a tab the user switched to: a
    /// restore that finishes for a connection in the background selects a tab nobody has seen, and
    /// recording it would send the next Control-Tab there. Coming to the front records the selected
    /// tab, because the user is now looking at it.
    var isFrontmost = false {
        didSet {
            guard isFrontmost != oldValue else { return }
            scheduleActivationRecord()
        }
    }

    @Published var tabStructureVersion: Int = 0

    var pendingFocusTabId: UUID?

    /// When each open tab was last the selected one, as a sequence number rather than a time, so
    /// two selections in one run-loop turn still order. The sequence is shared by every tab manager
    /// so a window hosting several connections can order all of their tabs together.
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

    /// Closing a tab used to mean closing its window, because a tab was a window. Selection
    /// lands on the tab that took its place in the strip, so the pane never blanks while the entry
    /// still has tabs. An entry left with none shows its empty state rather than another entry's tab.
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

    /// Reorders the strip. A pure permutation: the same tabs, a different order, and the selection
    /// stays on whichever tab it was on rather than on the position that tab vacated.
    ///
    /// `destination` is a position in the strip, which lists one entry's tabs, so the move lands
    /// beside the strip neighbour it was dropped next to wherever the other entries' tabs sit.
    ///
    /// The array is rebuilt and assigned once rather than mutated twice, because `tabs.didSet`
    /// bumps `tabStructureVersion` and republishes the workspace anchors on every write, and the
    /// state between a `remove` and an `insert` is a tab list the user never had.
    func moveTab(id: UUID, to destination: Int) {
        let strip = visibleTabs
        guard let source = strip.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(destination, 0), strip.count - 1)
        guard clamped != source else { return }

        let neighbourId = strip[clamped].id
        var reordered = tabs
        guard let flatSource = reordered.firstIndex(where: { $0.id == id }) else { return }
        let moving = reordered.remove(at: flatSource)
        guard let neighbour = reordered.firstIndex(where: { $0.id == neighbourId }) else { return }
        reordered.insert(moving, at: clamped > source ? neighbour + 1 : neighbour)
        tabs = reordered
    }

    /// Whether `tab` can move one place in `offset`'s direction, so a menu item can dim instead of
    /// being offered and doing nothing.
    func canMoveTab(id: UUID, by offset: Int) -> Bool {
        let strip = visibleTabs
        guard let index = strip.firstIndex(where: { $0.id == id }) else { return false }
        return strip.indices.contains(index + offset)
    }

    func moveTab(id: UUID, by offset: Int) {
        guard let index = visibleTabs.firstIndex(where: { $0.id == id }) else { return }
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
        let strip = visibleTabs
        guard strip.indices.contains(index) else { return }
        selectedTabId = strip[index].id
    }

    func selectTab(offsetBy offset: Int) {
        let strip = visibleTabs
        guard !strip.isEmpty else { return }
        let current = selectedTab.flatMap { tab in strip.firstIndex { $0.id == tab.id } } ?? 0
        let count = strip.count
        selectedTabId = strip[((current + offset) % count + count) % count].id
    }

    // MARK: - Recency

    /// The tab is recorded once the turn settles, not at each write. Opening a table into another
    /// connection brings that connection forward and then selects the new tab in the same turn, so
    /// the tab it was showing is never drawn; recorded as it passed through, it would be what the
    /// next Control-Tab went back to.
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
    private func adoptReopenedFile(at index: Int, content: String, stamp: FileStamp?, encoding: FileTextEncoding?) {
        /// An unknown baseline is not a licence to replace what the tab holds. `isFileDirty` reads a
        /// missing one as clean, so without this a tab that never learned what its file said would
        /// be overwritten by the very check meant to protect it.
        guard tabs[index].content.savedFileContent != nil, !tabs[index].content.isFileDirty else { return }
        FileTabBaseline.adopt(text: content, stamp: stamp, encoding: encoding, into: &tabs[index].content)
    }

    /// Take an already-built tab, such as one rebuilt from the recently closed history, rather than
    /// minting a fresh one. Selecting it drives the window title, toolbar, and persistence through
    /// the usual `selectedTabId` observation.
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

    /// Fired the instant a tab stops being about the table it was about. Whoever owns execution
    /// listens here rather than at the navigation call sites, because a retarget that forgets to
    /// invalidate is exactly how a finished query paints its rows into a tab showing something else.
    @Published var onTabRetargeted: ((UUID) -> Void)?

    @Published var onTableSchemaResolved: ((_ tableName: String, _ databaseName: String, _ schemaName: String) -> Void)?

    /// `objectType` carries what the object is, where the caller knew it, alongside the `isView`
    /// the callers that know only that much pass. Whoever records the open needs the kind: a
    /// MariaDB sequence recorded as "not a table" came back as a view and was offered Drop View.
    private func notifyTableOpened(
        tableName: String, schemaName: String?, databaseName: String,
        isView: Bool, objectType: TableInfo.TableType?, isPreview: Bool
    ) {
        onTableOpened?(tableName, schemaName, databaseName, isView, objectType, isPreview)
    }

    /// A table tab opened before its schema was known was reported without one, so whoever recorded
    /// that open learns the schema when the tab does. Otherwise the record keeps naming the table in
    /// whichever schema is browsed when it is next used.
    func adoptResolvedSchema(_ schemaName: String, at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].tableContext.schemaName = schemaName
        guard let tableName = tabs[index].tableContext.tableName else { return }
        onTableSchemaResolved?(tableName, tabs[index].tableContext.databaseName, schemaName)
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
        objectType: TableInfo.TableType? = nil,
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

    func addCreateTableTab(databaseName: String = "") {
        let tabTitle = String(localized: "Create Table")
        var newTab = QueryTab(title: tabTitle, tabType: .createTable)
        newTab.tableContext.databaseName = databaseName
        bindToVisibleContainer(&newTab)
        newTab.tableContext.isEditable = false
        newTab.hasUserInteraction = true
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    /// `schemaName` is the schema the diagram draws, which on an engine whose entries are schemas
    /// is the entry the tab belongs to, whichever one is on screen when it opens.
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

    /// Replace the currently selected tab's content with a new table.
    /// - Returns: `true` if the replacement happened (caller should run the query),
    ///   `false` if there is no selected tab.
    @discardableResult
    func replaceTabContent(
        tableName: String, databaseType: DatabaseType = .mysql,
        isView: Bool = false, objectType: TableInfo.TableType? = nil,
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
        /// Built whole rather than field by field: a field left over describes the previous table,
        /// and its primary keys were what a keyless table's edits matched rows on.
        tab.tableContext = TabTableContext(
            tableName: tableName,
            databaseName: databaseName,
            schemaName: schemaName,
            isEditable: !isView,
            isView: isView,
            objectType: objectType
        )
        /// Fresh for the same reason. A query tab keeps the file it was opened from, and a table
        /// carried that binding, so Save wrote the table's query into the file.
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
        tab.selectedRowIndices = []
        tab.cellSelection = .empty
        tab.pendingChanges = TabChangeSnapshot()
        tab.hasUserInteraction = false
        tab.filterState = TabFilterState()
        tab.valueFilter = GridValueFilterState()
        tab.columnLayout = ColumnLayoutState()
        tab.pagination = PaginationState(pageSize: pageSize)
        // Retargeting points the tab at a different table, so a restore that has not been consumed
        // yet describes rows this tab no longer shows. Left behind, it is persisted against the new
        // table and applied to it on the next launch.
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
    /// The tabs the strip lists: the visible entry's, plus the ones that name no container.
    var visibleTabs: [QueryTab] {
        if let cached = _visibleTabs { return cached }
        let visible = tabs.filter(isVisible)
        _visibleTabs = visible
        return visible
    }

    func containerName(of tab: QueryTab) -> String? {
        WorkspaceAnchoring.containerName(of: tab, target: containerTarget)
    }

    /// A tab that names no container belongs to no entry, so every entry shows it: a server
    /// dashboard, or a query tab on an engine whose query tabs run against whatever is browsed.
    func isVisible(_ tab: QueryTab) -> Bool {
        guard let visibleContainer, let container = containerName(of: tab) else { return true }
        return container == visibleContainer
    }

    /// Puts an entry in front. The selection stays when it is already in that entry, lands on the
    /// tab last used there otherwise, and on nothing when the entry holds no tab of its own, which
    /// is the entry's empty state rather than a tab from somewhere else.
    ///
    /// It never moves the browse cursor. Whoever moved the cursor calls this, or calls it first and
    /// moves the cursor after.
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

    /// A new window's only tab. Its entry is put in front before the tab is selected, so a window
    /// built around a tab never reads as the user picking a tab in another entry, which would move
    /// the connection's database on its own.
    func seed(with tab: QueryTab) {
        tabs = [tab]
        show(container: containerName(of: tab) ?? visibleContainer)
        selectedTabId = tab.id
    }

    /// A tab is bound to the database, or the schema on an engine whose entries are schemas, it was
    /// opened in. One a caller opened without naming it, such as a New Tab on a schema engine,
    /// Favorites or Open in Editor, gets the visible entry's. Left unbound it ran against whatever
    /// the connection browsed next, and picking a tab of another entry moves that: a statement
    /// typed against one schema would run against the other.
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

    /// Restored tabs from before tabs were bound to their entry: they ran against the container the
    /// connection was on, which is the one the restore lands in.
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

    /// Server-wide tabs answer for the whole connection, so they belong to every entry.
    private static func bindsToContainer(_ type: TabType) -> Bool {
        switch type {
        case .query, .table, .createTable, .erDiagram, .objectSource:
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

    /// Selecting a tab of another entry, or moving the selected tab into one, takes the window to
    /// that entry: the selected tab is always one the strip lists. A selection that names a tab not
    /// in the list yet is the moment inside a close or an adoption, and is left alone.
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
