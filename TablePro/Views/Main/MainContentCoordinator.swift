//
//  MainContentCoordinator.swift
//  TablePro
//
//  Coordinator managing business logic for MainContentView.
//  Separates view logic from presentation for better maintainability.
//

import CodeEditSourceEditor
import Foundation
import Observation
import os
import SwiftUI
import TableProPluginKit

/// Discard action types for unified alert handling
enum DiscardAction {
    case refresh
    case sort
    case pagination
    case filter
}

/// Cache entry for async-sorted query tab rows (stores index permutation, not row copies)
struct QuerySortCacheEntry {
    let sortedIndices: [Int]
    let columnIndex: Int
    let direction: SortDirection
    let resultVersion: Int
}

/// Sidebar table loading state — single source of truth for sidebar UI
enum SidebarLoadingState: Equatable {
    case idle
    case loading
    case loaded
    case error(String)
}

/// Represents which sheet is currently active in MainContentView.
/// Uses a single `.sheet(item:)` modifier instead of multiple `.sheet(isPresented:)`.
enum ActiveSheet: Identifiable {
    case databaseSwitcher
    case exportDialog
    case importDialog
    case quickSwitcher
    case exportQueryResults
    case maintenance(operation: String, tableName: String)

    var id: String {
        switch self {
        case .databaseSwitcher: "databaseSwitcher"
        case .exportDialog: "exportDialog"
        case .importDialog: "importDialog"
        case .quickSwitcher: "quickSwitcher"
        case .exportQueryResults: "exportQueryResults"
        case .maintenance: "maintenance"
        }
    }
}

/// Coordinator managing MainContentView business logic
@MainActor @Observable
final class MainContentCoordinator {
    static let logger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")
    static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    /// Monotonic counter for correlating rapid tab-switch/close log entries.
    static var switchSeq: Int = 0
    static func nextSwitchSeq() -> Int {
        switchSeq += 1
        return switchSeq
    }

    /// Posted during teardown so DataGridView coordinators can release cell views.
    /// Object is the connection UUID.
    static let teardownNotification = Notification.Name("MainContentCoordinator.teardown")

    // MARK: - Dependencies

    let connection: DatabaseConnection
    var connectionId: UUID { connection.id }
    /// Live safe mode level — reads from toolbar state (user-editable),
    /// not from the immutable connection snapshot.
    var safeModeLevel: SafeModeLevel { toolbarState.safeModeLevel }
    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let filterStateManager: FilterStateManager
    let columnVisibilityManager: ColumnVisibilityManager
    let toolbarState: ConnectionToolbarState

    // MARK: - Services

    internal var queryBuilder: TableQueryBuilder
    let persistence: TabPersistenceCoordinator
    @ObservationIgnored internal lazy var rowOperationsManager: RowOperationsManager = {
        RowOperationsManager(changeManager: changeManager)
    }()

    /// Stable identifier for this coordinator's window (set by MainContentView on appear)
    var windowId: UUID?

    /// Direct reference to sidebar viewmodel — eliminates global notification broadcasts
    weak var sidebarViewModel: SidebarViewModel?

    /// Direct reference to structure view actions — eliminates notification broadcasts
    weak var structureActions: StructureViewActionHandler?

    /// Direct reference to AI chat viewmodel — eliminates notification broadcasts
    weak var aiViewModel: AIChatViewModel?

    /// Direct reference to right panel state — enables showing AI panel programmatically
    @ObservationIgnored weak var rightPanelState: RightPanelState?

    /// Direct reference to this coordinator's content window, used for presenting alerts.
    /// Avoids NSApp.keyWindow which may return a sheet window, causing stuck dialogs.
    @ObservationIgnored weak var contentWindow: NSWindow?

    /// Back-reference to this coordinator's command actions, enabling window → coordinator → actions
    /// lookup when `@FocusedValue(\.commandActions)` has not resolved (e.g. focus in an AppKit subview).
    @ObservationIgnored weak var commandActions: MainContentCommandActions?

    // MARK: - Published State

    var schemaProvider: SQLSchemaProvider
    var cursorPositions: [CursorPosition] = []
    var tableMetadata: TableMetadata?
    // Removed: showErrorAlert and errorAlertMessage - errors now display inline
    var activeSheet: ActiveSheet?
    var importFileURL: URL?
    var needsLazyLoad = false
    var sidebarLoadingState: SidebarLoadingState = .idle

    /// Cache for async-sorted query tab rows (large datasets sorted on background thread)
    @ObservationIgnored private(set) var querySortCache: [UUID: QuerySortCacheEntry] = [:]

    // MARK: - Internal State

    /// Cached column types per table for selective queries (avoids refetching schema).
    /// Key: "connectionId:databaseName:tableName"
    @ObservationIgnored var cachedTableColumnTypes: [String: [ColumnType]] = [:]
    @ObservationIgnored var cachedTableColumnNames: [String: [String]] = [:]

    @ObservationIgnored internal var queryGeneration: Int = 0
    @ObservationIgnored internal var currentQueryTask: Task<Void, Never>?
    @ObservationIgnored internal var redisDatabaseSwitchTask: Task<Void, Never>?
    @ObservationIgnored private var changeManagerUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var activeSortTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var urlFilterObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pluginDriverObserver: NSObjectProtocol?
    @ObservationIgnored private var fileWatcher: DatabaseFileWatcher?
    @ObservationIgnored private var lastSchemaRefreshDate = Date.distantPast

    /// Set during handleTabChange to suppress redundant onChange(of: resultColumns) reconfiguration
    @ObservationIgnored internal var isHandlingTabSwitch = false
    @ObservationIgnored var isUpdatingColumnLayout = false

    /// Guards against re-entrant confirm dialogs (e.g. nested run loop during runModal)
    @ObservationIgnored internal var isShowingConfirmAlert = false

    /// Guards against duplicate safe mode confirmation prompts
    @ObservationIgnored internal var isShowingSafeModePrompt = false

    /// Continuation for callers that need to await the result of a fire-and-forget save
    /// (e.g. save-then-close). Set before calling `saveChanges`, resumed by `executeCommitStatements`.
    @ObservationIgnored internal var saveCompletionContinuation: CheckedContinuation<Bool, Never>?

    /// Called during teardown to let the view layer release cached row providers and sort data.
    @ObservationIgnored var onTeardown: (() -> Void)?

    // MARK: - Window Lifecycle (Phase 2: driven by TabWindowController NSWindowDelegate)

    /// Whether this coordinator's window is the key (focused) window.
    /// Updated by TabWindowController delegate methods; consumed by
    /// event handlers (e.g. sidebar table-selection navigation filter).
    @ObservationIgnored var isKeyWindow = false

    /// Timestamp of the most recent resignKey. Used by `handleWindowDidBecomeKey`
    /// to detect menu-interaction bounces (resign + become within 200ms).
    @ObservationIgnored var lastResignKeyDate = Date.distantPast

    /// Eviction task scheduled in `handleWindowDidResignKey` (fires 5s later).
    @ObservationIgnored var evictionTask: Task<Void, Never>?

    /// View-layer callback invoked from `handleWindowDidBecomeKey` (e.g. sync
    /// SwiftUI-scoped sidebar selection to the current tab). Set by MainContentView
    /// in `.onAppear`. The callback closes over view state (@Binding tables,
    /// SharedSidebarState) that isn't available to the coordinator.
    @ObservationIgnored var onWindowBecameKey: (() -> Void)?

    /// View-layer callback invoked from `handleWindowWillClose` before teardown
    /// (e.g. `rightPanelState.teardown()` releases SwiftUI-scoped subviewmodels).
    @ObservationIgnored var onWindowWillClose: (() -> Void)?

    /// True once the coordinator's view has appeared (onAppear fired).
    /// Coordinators that SwiftUI creates during body re-evaluation but never
    /// adopts into @State are silently discarded — no teardown warning needed.
    @ObservationIgnored private let _didActivate = OSAllocatedUnfairLock(initialState: false)

    /// Tracks whether teardown() was called; used by deinit to log missed teardowns
    @ObservationIgnored private let _didTeardown = OSAllocatedUnfairLock(initialState: false)

    /// Tracks whether teardown has been scheduled (but not yet executed)
    /// so deinit doesn't warn if SwiftUI deallocates before the delayed Task fires
    @ObservationIgnored private let _teardownScheduled = OSAllocatedUnfairLock(initialState: false)

    /// Whether teardown is scheduled or already completed — used by views to skip
    /// persistence during window close teardown
    var isTearingDown: Bool { _teardownScheduled.withLock { $0 } || _didTeardown.withLock { $0 } }

    /// Set when NSApplication is terminating — suppresses deinit warning since
    /// SwiftUI does not call onDisappear during app termination
    nonisolated private static let _isAppTerminating = OSAllocatedUnfairLock(initialState: false)
    nonisolated static var isAppTerminating: Bool {
        get { _isAppTerminating.withLock { $0 } }
        set { _isAppTerminating.withLock { $0 = newValue } }
    }

    /// Registry of active coordinators for aggregated quit-time persistence.
    /// Keyed by ObjectIdentifier of each coordinator instance.
    private static var activeCoordinators: [ObjectIdentifier: MainContentCoordinator] = [:]

    /// Register this coordinator so quit-time persistence can aggregate tabs.
    private func registerForPersistence() {
        Self.activeCoordinators[ObjectIdentifier(self)] = self
    }

    /// Unregister this coordinator from quit-time aggregation.
    private func unregisterFromPersistence() {
        Self.activeCoordinators.removeValue(forKey: ObjectIdentifier(self))
    }

    /// Find a coordinator by its window identifier.
    static func coordinator(for windowId: UUID) -> MainContentCoordinator? {
        activeCoordinators.values.first { $0.windowId == windowId }
    }

    /// Find the coordinator whose `contentWindow` matches the given NSWindow.
    /// Used by `TabWindowController` to dispatch NSWindowDelegate callbacks
    /// to the correct coordinator without needing a shared registry key.
    static func coordinator(forWindow window: NSWindow) -> MainContentCoordinator? {
        activeCoordinators.values.first { $0.contentWindow === window }
    }

    /// Check whether any active coordinator has unsaved edits.
    static func hasAnyUnsavedChanges() -> Bool {
        activeCoordinators.values.contains { coordinator in
            coordinator.tabManager.tabs.contains { $0.pendingChanges.hasChanges }
        }
    }

    /// Collect all tabs from all active coordinators for a given connectionId.
    static func allTabs(for connectionId: UUID) -> [QueryTab] {
        activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .flatMap { $0.tabManager.tabs }
    }

    /// Find the first coordinator for `connectionId` that owns a tab matching `predicate`.
    /// Used to dedup cross-window tabs (Server Dashboard singleton, ER Diagram reuse).
    static func coordinator(
        forConnection connectionId: UUID,
        tabMatching predicate: (QueryTab) -> Bool
    ) -> MainContentCoordinator? {
        activeCoordinators.values.first { coordinator in
            coordinator.connectionId == connectionId
                && coordinator.tabManager.tabs.contains(where: predicate)
        }
    }

    /// Collect non-preview tabs for persistence.
    private static func aggregatedTabs(for connectionId: UUID) -> [QueryTab] {
        let coordinators = activeCoordinators.values
            .filter { $0.connectionId == connectionId }

        // Sort by native window tab order to preserve left-to-right position
        let orderedCoordinators: [MainContentCoordinator]
        if let firstWindow = coordinators.compactMap({ $0.contentWindow }).first,
           let tabbedWindows = firstWindow.tabbedWindows {
            let windowOrder = Dictionary(uniqueKeysWithValues:
                tabbedWindows.enumerated().map { (ObjectIdentifier($0.element), $0.offset) }
            )
            orderedCoordinators = coordinators.sorted { a, b in
                let aIdx = a.contentWindow.flatMap { windowOrder[ObjectIdentifier($0)] } ?? Int.max
                let bIdx = b.contentWindow.flatMap { windowOrder[ObjectIdentifier($0)] } ?? Int.max
                return aIdx < bIdx
            }
        } else {
            orderedCoordinators = Array(coordinators)
        }

        return orderedCoordinators
            .flatMap { $0.tabManager.tabs }
            .filter { !$0.isPreview }
    }

    /// Get selected tab ID from any coordinator for a given connectionId.
    private static func aggregatedSelectedTabId(for connectionId: UUID) -> UUID? {
        activeCoordinators.values
            .first { $0.connectionId == connectionId && $0.tabManager.selectedTabId != nil }?
            .tabManager.selectedTabId
    }

    /// Check if this coordinator is the first registered for its connection.
    private func isFirstCoordinatorForConnection() -> Bool {
        Self.activeCoordinators.values
            .first { $0.connectionId == self.connectionId } === self
    }

    private static let registerTerminationObserver: Void = {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainContentCoordinator.isAppTerminating = true
        }
    }()

    /// Evict row data for background tabs in this coordinator to free memory.
    /// Called when the coordinator's native window-tab becomes inactive.
    /// The currently selected tab is kept in memory so the user sees no
    /// refresh flicker when switching back — matching native macOS behavior.
    /// Background tabs are re-fetched automatically when selected.
    func evictInactiveRowData() {
        let selectedId = tabManager.selectedTabId
        for tab in tabManager.tabs where !tab.rowBuffer.isEvicted
            && !tab.resultRows.isEmpty
            && !tab.pendingChanges.hasChanges
            && tab.id != selectedId
        {
            tab.rowBuffer.evict()
        }
    }

    /// Remove sort cache entries for tabs that no longer exist
    func cleanupSortCache(openTabIds: Set<UUID>) {
        if querySortCache.keys.contains(where: { !openTabIds.contains($0) }) {
            querySortCache = querySortCache.filter { openTabIds.contains($0.key) }
        }
        for (tabId, task) in activeSortTasks where !openTabIds.contains(tabId) {
            task.cancel()
            activeSortTasks.removeValue(forKey: tabId)
        }
    }

    // MARK: - Initialization

    init(
        connection: DatabaseConnection,
        tabManager: QueryTabManager,
        changeManager: DataChangeManager,
        filterStateManager: FilterStateManager,
        columnVisibilityManager: ColumnVisibilityManager,
        toolbarState: ConnectionToolbarState
    ) {
        let initStart = Date()
        self.connection = connection
        self.tabManager = tabManager
        self.changeManager = changeManager
        self.filterStateManager = filterStateManager
        self.columnVisibilityManager = columnVisibilityManager
        self.toolbarState = toolbarState
        let dialect = PluginManager.shared.sqlDialect(for: connection.type)
        self.queryBuilder = TableQueryBuilder(
            databaseType: connection.type,
            dialect: dialect,
            dialectQuote: quoteIdentifierFromDialect(dialect)
        )
        self.persistence = TabPersistenceCoordinator(connectionId: connection.id)

        self.schemaProvider = SchemaProviderRegistry.shared.getOrCreate(for: connection.id)
        SchemaProviderRegistry.shared.retain(for: connection.id)
        urlFilterObservers = setupURLNotificationObservers()

        // Synchronous save at quit time. NotificationCenter with queue: .main
        // delivers the closure on the main thread, satisfying assumeIsolated's
        // precondition. The write completes before the process exits — unlike
        // Task-based saves that need a run loop.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only the first coordinator for this connection saves,
                // aggregating tabs from all windows to fix last-write-wins bug.
                // Skip isTearingDown check: during Cmd+Q, onDisappear fires
                // markTeardownScheduled() before willTerminate, and we still
                // need to save here.
                guard self.isFirstCoordinatorForConnection() else { return }
                let allTabs = Self.aggregatedTabs(for: self.connectionId)
                let selectedId = Self.aggregatedSelectedTabId(for: self.connectionId)
                self.persistence.saveNowSync(
                    tabs: allTabs,
                    selectedTabId: selectedId
                )
            }
        }

        _ = Self.registerTerminationObserver
        Self.lifecycleLogger.info(
            "[open] MainContentCoordinator.init done connId=\(connection.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(initStart) * 1_000))"
        )
    }

    func markActivated() {
        let start = Date()
        _didActivate.withLock { $0 = true }
        registerForPersistence()
        setupPluginDriver()
        startFileWatcherIfNeeded()
        // Retry when driver becomes available (connection may still be in progress)
        if changeManager.pluginDriver == nil {
            pluginDriverObserver = NotificationCenter.default.addObserver(
                forName: .databaseDidConnect, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.setupPluginDriver()
                }
            }
        }
        Self.lifecycleLogger.info(
            "[open] MainContentCoordinator.markActivated done connId=\(self.connection.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    /// Transition sidebar from `.idle` to `.loaded` when tables already exist
    /// (e.g. populated by another window's `refreshTables()`).
    func healSidebarLoadingStateIfNeeded() {
        guard sidebarLoadingState == .idle else { return }
        let tables = DatabaseManager.shared.session(for: connectionId)?.tables ?? []
        if !tables.isEmpty {
            sidebarLoadingState = .loaded
        }
    }

    /// Start watching the database file for external changes (SQLite, DuckDB).
    private func startFileWatcherIfNeeded() {
        guard PluginManager.shared.connectionMode(for: connection.type) == .fileBased else { return }
        let filePath = connection.database
        guard !filePath.isEmpty else { return }

        let watcher = DatabaseFileWatcher()
        watcher.watch(filePath: filePath, connectionId: connectionId) { [weak self] in
            guard let self, self.sidebarLoadingState != .loading else { return }
            Task { await self.refreshTablesIfStale() }
        }
        fileWatcher = watcher
    }

    /// Refresh schema only if not recently refreshed (avoids redundant work
    /// when both the file watcher and window focus trigger close together).
    func refreshTablesIfStale() async {
        guard Date().timeIntervalSince(lastSchemaRefreshDate) > 2 else { return }
        lastSchemaRefreshDate = Date()
        await refreshTables()
    }

    func showAIChatPanel() {
        RightPanelVisibility.shared.isPresented = true
        rightPanelState?.activeTab = .aiChat
    }

    /// Set up the plugin driver for query building dispatch on the query builder and change manager.
    private func setupPluginDriver() {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        let pluginDriver = driver.queryBuildingPluginDriver
        queryBuilder.setPluginDriver(pluginDriver)
        changeManager.pluginDriver = pluginDriver
        // Remove observer once successfully set up
        if pluginDriver != nil, let observer = pluginDriverObserver {
            NotificationCenter.default.removeObserver(observer)
            pluginDriverObserver = nil
        }
    }

    func markTeardownScheduled() {
        _teardownScheduled.withLock { $0 = true }
    }

    func clearTeardownScheduled() {
        _teardownScheduled.withLock { $0 = false }
    }

    func refreshTables() async {
        lastSchemaRefreshDate = Date()
        sidebarLoadingState = .loading
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            sidebarLoadingState = .error(String(localized: "Not connected"))
            return
        }
        do {
            let tables = try await driver.fetchTables()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DatabaseManager.shared.updateSession(connectionId) { $0.tables = tables }
            let currentDb = DatabaseManager.shared.session(for: connectionId)?.activeDatabase
            await schemaProvider.resetForDatabase(currentDb, tables: tables, driver: driver)

            // Clean up stale selections and pending operations for tables that no longer exist
            if let vm = sidebarViewModel {
                let validNames = Set(tables.map(\.name))
                let staleSelections = vm.selectedTables.filter { !validNames.contains($0.name) }
                if !staleSelections.isEmpty {
                    vm.selectedTables.subtract(staleSelections)
                }
                let stalePendingDeletes = vm.pendingDeletes.subtracting(validNames)
                if !stalePendingDeletes.isEmpty {
                    vm.pendingDeletes.subtract(stalePendingDeletes)
                    for name in stalePendingDeletes {
                        vm.tableOperationOptions.removeValue(forKey: name)
                    }
                }
                let stalePendingTruncates = vm.pendingTruncates.subtracting(validNames)
                if !stalePendingTruncates.isEmpty {
                    vm.pendingTruncates.subtract(stalePendingTruncates)
                    for name in stalePendingTruncates {
                        vm.tableOperationOptions.removeValue(forKey: name)
                    }
                }
            }

            sidebarLoadingState = .loaded
        } catch {
            sidebarLoadingState = .error(error.localizedDescription)
        }
    }

    /// Explicit cleanup called from `onDisappear`. Releases schema provider
    /// synchronously on MainActor so we don't depend on deinit + Task scheduling.
    func teardown() {
        let start = Date()
        Self.lifecycleLogger.info(
            "[close] MainContentCoordinator.teardown start connId=\(self.connection.id, privacy: .public) tabs=\(self.tabManager.tabs.count) windowId=\(self.windowId?.uuidString ?? "nil", privacy: .public)"
        )
        _didTeardown.withLock { $0 = true }

        unregisterFromPersistence()
        for observer in urlFilterObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        urlFilterObservers.removeAll()
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }
        if let observer = pluginDriverObserver {
            NotificationCenter.default.removeObserver(observer)
            pluginDriverObserver = nil
        }
        fileWatcher?.stopWatching(connectionId: connectionId)
        fileWatcher = nil
        currentQueryTask?.cancel()
        currentQueryTask = nil
        changeManagerUpdateTask?.cancel()
        changeManagerUpdateTask = nil
        redisDatabaseSwitchTask?.cancel()
        redisDatabaseSwitchTask = nil
        for task in activeSortTasks.values { task.cancel() }
        activeSortTasks.removeAll()

        // Let the view layer release cached row providers before we drop RowBuffers.
        // Called synchronously here because SwiftUI onChange handlers don't fire
        // reliably on disappearing views.
        onTeardown?()
        onTeardown = nil

        // Notify DataGridView coordinators to release NSTableView cell views
        NotificationCenter.default.post(
            name: Self.teardownNotification,
            object: connection.id
        )

        // Release heavy data so memory drops even if SwiftUI delays deallocation
        for tab in tabManager.tabs {
            tab.rowBuffer.evict()
        }
        querySortCache.removeAll()
        cachedTableColumnTypes.removeAll()
        cachedTableColumnNames.removeAll()

        tabManager.tabs.removeAll()
        tabManager.selectedTabId = nil

        // Release change manager state — pluginDriver holds a strong reference
        // to the entire database driver which prevents deallocation
        changeManager.clearChanges()
        changeManager.pluginDriver = nil

        // Release metadata and filter state
        tableMetadata = nil
        filterStateManager.filters.removeAll()
        filterStateManager.appliedFilters.removeAll()

        SchemaProviderRegistry.shared.release(for: connection.id)
        SchemaProviderRegistry.shared.purgeUnused()
        Self.lifecycleLogger.info(
            "[close] MainContentCoordinator.teardown done connId=\(self.connection.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    deinit {
        saveCompletionContinuation?.resume(returning: false)
        saveCompletionContinuation = nil

        let connectionId = connection.id
        let alreadyHandled = _didTeardown.withLock { $0 } || _teardownScheduled.withLock { $0 }

        // Never-activated coordinators are throwaway instances created by SwiftUI
        // during body re-evaluation — @State only keeps the first, rest are discarded
        guard _didActivate.withLock({ $0 }) else {
            MainActor.assumeIsolated { unregisterFromPersistence() }
            if !alreadyHandled {
                Task { @MainActor in
                    SchemaProviderRegistry.shared.release(for: connectionId)
                    SchemaProviderRegistry.shared.purgeUnused()
                }
            }
            return
        }

        if !alreadyHandled && !Self.isAppTerminating {
            let logger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")
            logger.warning("teardown() was not called before deallocation for connection \(connectionId)")
        }

        if !alreadyHandled {
            Task { @MainActor in
                SchemaProviderRegistry.shared.release(for: connectionId)
                SchemaProviderRegistry.shared.purgeUnused()
            }
        }
    }

    // MARK: - Initialization Actions

    /// Synchronous toolbar setup — no I/O, safe to call inline
    func initializeToolbar() {
        toolbarState.update(from: connection)

        if let session = DatabaseManager.shared.session(for: connectionId) {
            toolbarState.connectionState = mapSessionStatus(session.status)
            if let driver = session.driver {
                toolbarState.databaseVersion = driver.serverVersion
            }
        } else if let driver = DatabaseManager.shared.driver(for: connectionId) {
            toolbarState.connectionState = .connected
            toolbarState.databaseVersion = driver.serverVersion
        }
    }

    /// Load schema only if the shared provider hasn't loaded yet
    func loadSchemaIfNeeded() async {
        let alreadyLoaded = await schemaProvider.isSchemaLoaded()
        if !alreadyLoaded {
            await loadSchema()
        }
    }

    /// Initialize view with connection info and load schema (legacy — used by first window)
    func initializeView() async {
        initializeToolbar()
        await loadSchemaIfNeeded()
    }

    /// Map ConnectionStatus to ToolbarConnectionState
    private func mapSessionStatus(_ status: ConnectionStatus) -> ToolbarConnectionState {
        switch status {
        case .connected: return .connected
        case .connecting: return .executing
        case .disconnected: return .disconnected
        case .error: return .error("")
        }
    }

    // MARK: - Schema Loading

    func loadSchema() async {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        await schemaProvider.loadSchema(using: driver, connection: connection)
    }

    func loadTableMetadata(tableName: String) async {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }

        do {
            let metadata = try await driver.fetchTableMetadata(tableName: tableName)
            self.tableMetadata = metadata
        } catch {
            Self.logger.error("Failed to load table metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pre-compiled regex for extracting table name from SELECT queries
    private static let tableNameRegex = try? NSRegularExpression(
        pattern: #"(?i)^\s*SELECT\s+.+?\s+FROM\s+(?:\[([^\]]+)\]|[`"]([^`"]+)[`"]|([\w$]+))\s*(?:WHERE|ORDER|LIMIT|GROUP|HAVING|OFFSET|FETCH|$|;)"#,
        options: []
    )

    private static let mongoCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\.(\w+)\."#,
        options: []
    )

    private static let mongoBracketCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\["([^"]+)"\]"#,
        options: []
    )

    // MARK: - Query Execution

    func runQuery() {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        let fullQuery = tabManager.tabs[index].query

        // For table tabs, use the full query. For query tabs, extract at cursor
        let sql: String
        if tabManager.tabs[index].tabType == .table {
            sql = fullQuery
        } else if let firstCursor = cursorPositions.first,
                  firstCursor.range.length > 0 {
            // Execute selected text only
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(
                firstCursor.range,
                NSRange(location: 0, length: nsQuery.length)
            )
            sql = nsQuery.substring(with: clampedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sql = SQLStatementScanner.statementAtCursor(
                in: fullQuery,
                cursorPosition: cursorPositions.first?.range.location ?? 0
            )
        }

        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Split into individual statements for multi-statement support
        let statements = SQLStatementScanner.allStatements(in: sql)
        guard !statements.isEmpty else { return }

        dispatchStatements(statements, tabIndex: index)
    }

    /// Execute table tab query directly.
    /// Table tab queries are always app-generated SELECTs, so they skip dangerous-query
    /// checks but still respect safe mode levels that apply to all queries.
    func executeTableTabQueryDirectly() {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        let sql = tabManager.tabs[index].query
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let level = safeModeLevel
        if level.appliesToAllQueries && level.requiresConfirmation,
           tabManager.tabs[index].lastExecutedAt == nil
        {
            guard !isShowingSafeModePrompt else { return }
            isShowingSafeModePrompt = true
            Task { @MainActor in
                defer { isShowingSafeModePrompt = false }
                let window = NSApp.keyWindow
                let permission = await SafeModeGuard.checkPermission(
                    level: level,
                    isWriteOperation: false,
                    sql: sql,
                    operationDescription: String(localized: "Execute Query"),
                    window: window,
                    databaseType: connection.type
                )
                switch permission {
                case .allowed:
                    executeQueryInternal(sql)
                case .blocked(let reason):
                    if index < tabManager.tabs.count {
                        tabManager.tabs[index].errorMessage = reason
                    }
                }
            }
        } else {
            executeQueryInternal(sql)
        }
    }

    // MARK: - Editor Query Loading

    func loadQueryIntoEditor(_ query: String) {
        if let tabIndex = tabManager.selectedTabIndex,
           tabIndex < tabManager.tabs.count,
           tabManager.tabs[tabIndex].tabType == .query {
            tabManager.tabs[tabIndex].query = query
            tabManager.tabs[tabIndex].hasUserInteraction = true
        } else {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .query,
                initialQuery: query
            )
            WindowManager.shared.openTab(payload: payload)
        }
    }

    func insertQueryFromAI(_ query: String) {
        if let tabIndex = tabManager.selectedTabIndex,
           tabIndex < tabManager.tabs.count,
           tabManager.tabs[tabIndex].tabType == .query {
            let existingQuery = tabManager.tabs[tabIndex].query
            if existingQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tabManager.tabs[tabIndex].query = query
            } else {
                tabManager.tabs[tabIndex].query = existingQuery + "\n\n" + query
            }
            tabManager.tabs[tabIndex].hasUserInteraction = true
        } else if tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: query, databaseName: connection.database)
        } else {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .query,
                initialQuery: query
            )
            WindowManager.shared.openTab(payload: payload)
        }
    }

    /// Run EXPLAIN on the current query (database-type-aware prefix)
    func runExplainQuery() {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        let fullQuery = tabManager.tabs[index].query

        // Extract query the same way as runQuery()
        let sql: String
        if tabManager.tabs[index].tabType == .table {
            sql = fullQuery
        } else if let firstCursor = cursorPositions.first,
                  firstCursor.range.length > 0 {
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(
                firstCursor.range,
                NSRange(location: 0, length: nsQuery.length)
            )
            sql = nsQuery.substring(with: clampedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sql = SQLStatementScanner.statementAtCursor(
                in: fullQuery,
                cursorPosition: cursorPositions.first?.range.location ?? 0
            )
        }

        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Use first statement only (EXPLAIN on a single statement)
        let statements = SQLStatementScanner.allStatements(in: trimmed)
        guard let stmt = statements.first else { return }

        let level = safeModeLevel
        let needsConfirmation = level.appliesToAllQueries && level.requiresConfirmation

        // Multi-variant EXPLAIN: use plugin-declared variants if available
        let explainVariants = PluginMetadataRegistry.shared.snapshot(
            forTypeId: connection.type.pluginTypeId
        )?.explainVariants ?? []

        if !explainVariants.isEmpty {
            if needsConfirmation {
                Task { @MainActor in
                    let window = NSApp.keyWindow
                    let permission = await SafeModeGuard.checkPermission(
                        level: level,
                        isWriteOperation: false,
                        sql: "EXPLAIN",
                        operationDescription: String(localized: "Execute Query"),
                        window: window,
                        databaseType: connection.type
                    )
                    if case .allowed = permission {
                        runVariantExplain(explainVariants[0])
                    }
                }
            } else {
                runVariantExplain(explainVariants[0])
            }
            return
        }

        guard let adapter = DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter,
              let explainSQL = adapter.buildExplainQuery(stmt) else {
            if let index = tabManager.selectedTabIndex {
                tabManager.tabs[index].errorMessage = String(localized: "EXPLAIN is not supported for this database type.")
            }
            return
        }

        if needsConfirmation {
            Task { @MainActor in
                let window = NSApp.keyWindow
                let permission = await SafeModeGuard.checkPermission(
                    level: level,
                    isWriteOperation: false,
                    sql: explainSQL,
                    operationDescription: String(localized: "Execute Query"),
                    window: window,
                    databaseType: connection.type
                )
                if case .allowed = permission {
                    executeQueryInternal(explainSQL)
                }
            }
        } else {
            Task { @MainActor in
                executeQueryInternal(explainSQL)
            }
        }
    }

    /// Internal query execution (called after any confirmations)
    internal func executeQueryInternal(
        _ sql: String
    ) {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        if currentQueryTask != nil {
            currentQueryTask?.cancel()
            try? DatabaseManager.shared.driver(for: connectionId)?.cancelQuery()
            currentQueryTask = nil
        }
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        // Batch mutations into a single array write to avoid multiple @Published
        // notifications — each notification triggers a full SwiftUI update cycle.
        var tab = tabManager.tabs[index]
        tab.isExecuting = true
        tab.executionTime = nil
        tab.errorMessage = nil
        tab.explainText = nil
        tab.explainPlan = nil
        tabManager.tabs[index] = tab
        toolbarState.setExecuting(true)

        if PluginManager.shared.supportsQueryProgress(for: connection.type) {
            installClickHouseProgressHandler()
        }

        let conn = connection
        let tabId = tabManager.tabs[index].id

        let (useProgressiveLoading, progressiveLimit) = resolveProgressiveLoading(sql: sql, tabType: tab.tabType)
        let effectiveSQL = sql

        let tableName: String?
        let isEditable: Bool
        let usesNoSQLBrowsing = PluginManager.shared.editorLanguage(for: connection.type) != .sql
            || (DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter)?
                .queryBuildingPluginDriver != nil
        if usesNoSQLBrowsing {
            tableName = tabManager.selectedTab?.tableName
            isEditable = tableName != nil
        } else if tab.tabType == .table, let existingName = tab.tableName {
            // Table tabs already know their table name — don't re-extract from SQL
            // which can fail for schema-qualified or quoted identifiers
            tableName = existingName
            isEditable = true
        } else {
            tableName = extractTableName(from: effectiveSQL)
            isEditable = tableName != nil
        }

        currentQueryTask = Task { [weak self] in
            guard let self else { return }

            do {
                // Pre-check metadata cache before starting any queries.
                var parallelSchemaTask: Task<SchemaResult, Error>?
                var needsMetadataFetch = false

                if isEditable, let tableName = tableName {
                    let cached = isMetadataCached(tabId: tabId, tableName: tableName)
                    needsMetadataFetch = !cached

                    // Metadata queries run on the main driver. They serialize behind any
                    // in-flight query at the C-level DispatchQueue and execute immediately after.
                    if needsMetadataFetch {
                        let connId = connectionId
                        // Note: Schema fetch operations are not tracked by ConnectionHealthMonitor.queriesInFlight.
                        // This is acceptable because the health monitor checks session.isConnected before pinging,
                        // and schema fetches are short-lived.
                        parallelSchemaTask = Task {
                            guard let driver = DatabaseManager.shared.driver(for: connId) else {
                                throw DatabaseError.notConnected
                            }
                            async let cols = driver.fetchColumns(table: tableName)
                            async let fks = driver.fetchForeignKeys(table: tableName)
                            let result = try await (columnInfo: cols, fkInfo: fks)
                            let approxCount = try? await driver.fetchApproximateRowCount(table: tableName)
                            return (columnInfo: result.columnInfo, fkInfo: result.fkInfo, approximateRowCount: approxCount)
                        }
                    }
                }

                // Main data query (on primary driver — runs concurrently with metadata)
                guard let queryDriver = DatabaseManager.shared.driver(for: connectionId) else {
                    throw DatabaseError.notConnected
                }
                let fetchResult: QueryFetchResult
                do {
                    fetchResult = try await Self.fetchQueryData(
                        driver: queryDriver,
                        sql: effectiveSQL,
                        useProgressiveLoading: useProgressiveLoading,
                        progressiveLimit: progressiveLimit
                    )
                }
                let safeColumns = fetchResult.columns
                let safeColumnTypes = fetchResult.columnTypes
                let safeRows = fetchResult.rows
                let safeExecutionTime = fetchResult.executionTime
                let safeRowsAffected = fetchResult.rowsAffected
                let safeStatusMessage = fetchResult.statusMessage
                let pageContext = fetchResult.pageContext

                guard !Task.isCancelled else {
                    parallelSchemaTask?.cancel()
                    await resetExecutionState(tabId: tabId, executionTime: safeExecutionTime)
                    return
                }

                // Await schema result before Phase 1 so data + FK arrows appear together
                var schemaResult: SchemaResult?
                if needsMetadataFetch {
                    schemaResult = await awaitSchemaResult(
                        parallelTask: parallelSchemaTask,
                        tableName: tableName ?? ""
                    )
                }

                // Parse schema metadata if available
                let metadata = schemaResult.map { self.parseSchemaMetadata($0) }

                // Phase 1: Display data rows + FK arrows in a single MainActor update.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    currentQueryTask = nil
                    if PluginManager.shared.supportsQueryProgress(for: self.connection.type) {
                        self.clearClickHouseProgress()
                    }
                    toolbarState.setExecuting(false)
                    toolbarState.lastQueryDuration = safeExecutionTime

                    // Always reset isExecuting even if generation is stale
                    if capturedGeneration != queryGeneration || Task.isCancelled {
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].isExecuting = false
                        }
                        return
                    }

                    applyPhase1Result(
                        tabId: tabId,
                        columns: safeColumns,
                        columnTypes: safeColumnTypes,
                        rows: safeRows,
                        executionTime: safeExecutionTime,
                        rowsAffected: safeRowsAffected,
                        statusMessage: safeStatusMessage,
                        tableName: tableName,
                        isEditable: isEditable,
                        metadata: metadata,
                        hasSchema: schemaResult != nil,
                        sql: sql,
                        connection: conn,
                        queryPageContext: pageContext
                    )
                }

                // Phase 2: Background exact COUNT + enum values.
                if isEditable, let tableName = tableName {
                    if needsMetadataFetch {
                        launchPhase2Work(
                            tableName: tableName,
                            tabId: tabId,
                            capturedGeneration: capturedGeneration,
                            connectionType: conn.type,
                            schemaResult: schemaResult
                        )
                    } else {
                        // Metadata cached but still need exact COUNT for pagination
                        launchPhase2Count(
                            tableName: tableName,
                            tabId: tabId,
                            capturedGeneration: capturedGeneration,
                            connectionType: conn.type
                        )
                    }
                } else if !isEditable || tableName == nil {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard capturedGeneration == queryGeneration else { return }
                        guard !Task.isCancelled else { return }
                        changeManager.clearChangesAndUndoHistory()
                    }
                }
            } catch {
                // Always reset isExecuting even if generation is stale —
                // skipping this leaves the tab permanently stuck in "executing"
                // state, requiring a reconnect to recover.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        var tab = tabManager.tabs[idx]
                        tab.isExecuting = false
                        tab.pagination.isLoadingMore = false
                        tabManager.tabs[idx] = tab
                    }
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)
                    guard capturedGeneration == queryGeneration else { return }
                    handleQueryExecutionError(error, sql: sql, tabId: tabId, connection: conn)
                }
            }
        }
    }

    /// Reset execution state when a query is cancelled
    @MainActor
    private func resetExecutionState(tabId: UUID, executionTime: TimeInterval) {
        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
            tabManager.tabs[idx].isExecuting = false
        }
        currentQueryTask = nil
        toolbarState.setExecuting(false)
        toolbarState.lastQueryDuration = executionTime
    }

    /// Fetch enum/set values for columns from database-specific sources
    func fetchEnumValues(
        columnInfo: [ColumnInfo],
        tableName: String,
        driver: DatabaseDriver,
        connectionType: DatabaseType
    ) async -> [String: [String]] {
        var result: [String: [String]] = [:]

        // Build enum/set value lookup map from column types (MySQL/MariaDB + ClickHouse Enum8/Enum16)
        for col in columnInfo {
            if let values = ColumnType.parseEnumValues(from: col.dataType) {
                result[col.name] = values
            } else if let values = ColumnType.parseClickHouseEnumValues(from: col.dataType) {
                result[col.name] = values
            }
        }

        // Fetch actual enum values from catalog via dependent types (PostgreSQL returns values, others return [])
        if let enumTypes = try? await driver.fetchDependentTypes(forTable: tableName),
           !enumTypes.isEmpty {
            let typeMap = Dictionary(uniqueKeysWithValues: enumTypes.map { ($0.name, $0.labels) })
            for col in columnInfo where col.dataType.uppercased().hasPrefix("ENUM(") {
                let raw = col.dataType
                if let openParen = raw.firstIndex(of: "("),
                   let closeParen = raw.lastIndex(of: ")") {
                    let typeName = String(raw[raw.index(after: openParen)..<closeParen])
                    if let values = typeMap[typeName] {
                        result[col.name] = values
                    }
                }
            }
        }

        // Fetch CHECK constraint pseudo-enum values from DDL (SQLite-style CHECK ... IN constraints).
        // Only attempt DDL parsing when no enum values were found via catalog (avoids unnecessary
        // fetchTableDDL calls for databases that don't use CHECK constraints for enums).
        if result.isEmpty, let createSQL = try? await driver.fetchTableDDL(table: tableName) {
            let columns = try? await driver.fetchColumns(table: tableName)
            for col in columns ?? [] {
                if let values = Self.parseSQLiteCheckConstraintValues(
                    createSQL: createSQL, columnName: col.name
                ) {
                    result[col.name] = values
                }
            }
        }

        return result
    }

    private static func parseSQLiteCheckConstraintValues(createSQL: String, columnName: String) -> [String]? {
        let escapedName = NSRegularExpression.escapedPattern(for: columnName)
        let pattern = "CHECK\\s*\\(\\s*\"?\(escapedName)\"?\\s+IN\\s*\\(([^)]+)\\)\\s*\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsString = createSQL as NSString
        guard let match = regex.firstMatch(
            in: createSQL,
            range: NSRange(location: 0, length: nsString.length)
        ), match.numberOfRanges > 1 else {
            return nil
        }
        let valuesString = nsString.substring(with: match.range(at: 1))
        return ColumnType.parseEnumValues(from: "ENUM(\(valuesString))")
    }

    // MARK: - SQL Helpers

    static func stripTrailingOrderBy(from sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsString = trimmed as NSString
        let pattern = "\\s+ORDER\\s+BY\\s+(?![^(]*\\))[^)]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return trimmed
        }
        let range = NSRange(location: 0, length: nsString.length)
        return regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SQL Parsing

    func extractTableName(from sql: String) -> String? {
        let nsRange = NSRange(sql.startIndex..., in: sql)

        // SQL: SELECT ... FROM tableName  (group 1 = bracket-quoted, group 2 = plain/backtick/double-quote)
        if let regex = Self.tableNameRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange) {
            for group in 1...3 {
                let r = match.range(at: group)
                if r.location != NSNotFound, let range = Range(r, in: sql) {
                    return String(sql[range])
                }
            }
        }

        // MQL bracket notation: db["collectionName"].find(...)
        if let regex = Self.mongoBracketCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        // MQL dot notation: db.collectionName.find(...)
        if let regex = Self.mongoCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        return nil
    }

    // MARK: - Sorting

    func handleSort(columnIndex: Int, ascending: Bool, isMultiSort: Bool = false, selectedRowIndices: inout Set<Int>) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard columnIndex >= 0 && columnIndex < tab.resultColumns.count else { return }

        var currentSort = tab.sortState
        let newDirection: SortDirection = ascending ? .ascending : .descending

        if isMultiSort {
            // Multi-sort: toggle existing or append new column
            if let existingIndex = currentSort.columns.firstIndex(where: { $0.columnIndex == columnIndex }) {
                if currentSort.columns[existingIndex].direction == newDirection {
                    // Same direction clicked again — remove from sort
                    currentSort.columns.remove(at: existingIndex)
                } else {
                    // Toggle direction
                    currentSort.columns[existingIndex].direction = newDirection
                }
            } else {
                // Add new column to sort list
                currentSort.columns.append(SortColumn(columnIndex: columnIndex, direction: newDirection))
            }
        } else {
            // Single sort: replace all with single column
            currentSort = SortState()
            currentSort.columns = [SortColumn(columnIndex: columnIndex, direction: newDirection)]
        }
        if tab.tabType == .query {
            // When more rows are available server-side, re-execute with ORDER BY
            // instead of sorting locally (we only have a partial result set)
            if tab.pagination.hasMoreRows {
                let columnName = tab.resultColumns[columnIndex]
                let direction = currentSort.columns.first?.direction == .ascending ? "ASC" : "DESC"
                let baseQuery = tab.pagination.baseQueryForMore ?? tab.query
                let strippedQuery = Self.stripTrailingOrderBy(from: baseQuery)
                let quotedColumn = queryBuilder.quoteIdentifier(columnName)
                let orderQuery = "\(strippedQuery) ORDER BY \(quotedColumn) \(direction)"
                tabManager.tabs[tabIndex].sortState = currentSort
                tabManager.tabs[tabIndex].hasUserInteraction = true
                tabManager.tabs[tabIndex].pagination.resetLoadMore()
                tabManager.tabs[tabIndex].query = orderQuery
                runQuery()
                return
            }

            tabManager.tabs[tabIndex].sortState = currentSort
            tabManager.tabs[tabIndex].hasUserInteraction = true
            tabManager.tabs[tabIndex].pagination.reset()
            let rows = tab.resultRows
            let tabId = tab.id
            let resultVersion = tab.resultVersion
            let sortColumns = currentSort.columns
            let colTypes = tab.columnTypes

            if rows.count > 1_000 {
                // Sort on background thread to avoid UI freeze
                activeSortTasks[tabId]?.cancel()
                activeSortTasks.removeValue(forKey: tabId)
                tabManager.tabs[tabIndex].isExecuting = true
                toolbarState.setExecuting(true)
                querySortCache.removeValue(forKey: tabId)

                let sortStartTime = Date()
                let task = Task.detached { [weak self] in
                    let sortedIndices = Self.multiColumnSortIndices(
                        rows: rows,
                        sortColumns: sortColumns,
                        columnTypes: colTypes
                    )
                    let sortDuration = Date().timeIntervalSince(sortStartTime)

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        // Guard against stale completion: verify tab still expects this sort
                        guard let idx = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }),
                              self.tabManager.tabs[idx].sortState == currentSort else {
                            return
                        }
                        self.querySortCache[tabId] = QuerySortCacheEntry(
                            sortedIndices: sortedIndices,
                            columnIndex: sortColumns.first?.columnIndex ?? 0,
                            direction: sortColumns.first?.direction ?? .ascending,
                            resultVersion: resultVersion
                        )
                        var sortedTab = self.tabManager.tabs[idx]
                        sortedTab.isExecuting = false
                        sortedTab.executionTime = sortDuration
                        self.tabManager.tabs[idx] = sortedTab
                        self.toolbarState.setExecuting(false)
                        self.toolbarState.lastQueryDuration = sortDuration
                        self.activeSortTasks.removeValue(forKey: tabId)
                        self.changeManager.reloadVersion += 1
                    }
                }
                activeSortTasks[tabId] = task
            } else {
                // Small dataset: view sorts synchronously, just trigger reload
                changeManager.reloadVersion += 1
            }
            return
        }

        let tabId = tab.id
        let capturedSort = currentSort
        let capturedQuery = tab.query
        let capturedColumns = tab.resultColumns
        confirmDiscardChangesIfNeeded(action: .sort) { [weak self] confirmed in
            guard let self, confirmed,
                  let idx = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
            self.tabManager.tabs[idx].sortState = capturedSort
            self.tabManager.tabs[idx].hasUserInteraction = true
            self.tabManager.tabs[idx].pagination.reset()
            let newQuery = self.queryBuilder.buildMultiSortQuery(
                baseQuery: capturedQuery,
                sortState: capturedSort,
                columns: capturedColumns
            )
            self.tabManager.tabs[idx].query = newQuery
            self.runQuery()
        }
    }

    /// Multi-column sort returning index permutation (nonisolated for background thread).
    /// Returns an array of indices into the original `rows` array, sorted by the given columns.
    nonisolated private static func multiColumnSortIndices(
        rows: [[String?]],
        sortColumns: [SortColumn],
        columnTypes: [ColumnType] = []
    ) -> [Int] {
        // Fast path: single-column sort avoids intermediate key array allocation
        if sortColumns.count == 1 {
            let col = sortColumns[0]
            let colIndex = col.columnIndex
            let ascending = col.direction == .ascending
            let colType = colIndex < columnTypes.count ? columnTypes[colIndex] : nil
            var indices = Array(0..<rows.count)
            indices.sort { i1, i2 in
                let v1 = colIndex < rows[i1].count ? (rows[i1][colIndex] ?? "") : ""
                let v2 = colIndex < rows[i2].count ? (rows[i2][colIndex] ?? "") : ""
                let cmp = RowSortComparator.compare(v1, v2, columnType: colType)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
            return indices
        }

        var indices = Array(0..<rows.count)
        indices.sort { i1, i2 in
            let row1 = rows[i1]
            let row2 = rows[i2]
            for sortCol in sortColumns {
                let v1 = sortCol.columnIndex < row1.count ? (row1[sortCol.columnIndex] ?? "") : ""
                let v2 = sortCol.columnIndex < row2.count ? (row2[sortCol.columnIndex] ?? "") : ""
                let colType = sortCol.columnIndex < columnTypes.count
                    ? columnTypes[sortCol.columnIndex] : nil
                let result = RowSortComparator.compare(v1, v2, columnType: colType)
                if result == .orderedSame { continue }
                return sortCol.direction == .ascending
                    ? result == .orderedAscending
                    : result == .orderedDescending
            }
            return false
        }
        return indices
    }
}
