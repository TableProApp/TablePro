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

/// Cache entry for async-sorted query tab rows. Stores a permutation of `RowID` so the
/// sort survives mutations: inserted rows append to the end of the sorted view, and
/// removed rows are dropped from the permutation without re-sorting.
struct QuerySortCacheEntry {
    let sortedIDs: [RowID]
    let columnIndex: Int
    let direction: SortDirection
    let schemaVersion: Int
}

struct DisplayFormatsCacheEntry {
    let schemaVersion: Int
    let smartDetectionEnabled: Bool
    let overridesVersion: Int
    let formats: [ValueDisplayFormat?]
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
        case .maintenance(let operation, let tableName): "maintenance-\(operation)-\(tableName)"
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
    var safeModeLevel: SafeModeLevel { toolbarState.safeModeLevel }
    let selectionState = GridSelectionState()
    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let toolbarState: ConnectionToolbarState
    let tabSessionRegistry: TabSessionRegistry
    let queryExecutor: QueryExecutor
    let windowSidebarState = WindowSidebarState()

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

    /// Direct reference to the data tab grid delegate — enables row mutation operations to
    /// dispatch insertRows/removeRows directly to the NSTableView via DataGridViewDelegate.
    @ObservationIgnored weak var dataTabDelegate: DataTabGridDelegate?

    /// Proxy for toggling the inspector NSSplitViewItem from coordinator code
    @ObservationIgnored weak var inspectorProxy: InspectorVisibilityProxy?

    /// Direct reference to split view controller for sidebar toggle
    @ObservationIgnored weak var splitViewController: MainSplitViewController?

    /// Direct reference to this coordinator's content window, used for presenting alerts.
    /// Avoids NSApp.keyWindow which may return a sheet window, causing stuck dialogs.
    @ObservationIgnored weak var contentWindow: NSWindow?

    /// Back-reference to this coordinator's command actions, enabling window → coordinator → actions
    /// lookup when `@FocusedValue(\.commandActions)` has not resolved (e.g. focus in an AppKit subview).
    @ObservationIgnored weak var commandActions: MainContentCommandActions?

    // MARK: - Published State

    var cursorPositions: [CursorPosition] = []
    var tableMetadata: TableMetadata?
    var activeSheet: ActiveSheet?
    var importFileURL: URL?
    var exportPreselectedTableNames: Set<String>?
    var needsLazyLoad = false

    /// Cache for async-sorted query tab rows (large datasets sorted on background thread)
    @ObservationIgnored var querySortCache: [UUID: QuerySortCacheEntry] = [:]

    @ObservationIgnored var displayFormatsCache: [UUID: DisplayFormatsCacheEntry] = [:]

    @ObservationIgnored var pendingScrollToTopAfterReplace: Set<UUID> = []

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
    @ObservationIgnored private var pluginDriverObserver: NSObjectProtocol?
    @ObservationIgnored private var externalFileModObserver: NSObjectProtocol?

    var fileConflictRequest: FileConflictRequest?

    struct FileConflictRequest: Identifiable {
        let id = UUID()
        let tabId: UUID
        let url: URL
        let mineContent: String
        let diskContent: String
    }
    @ObservationIgnored private var fileWatcher: DatabaseFileWatcher?

    /// Set during handleTabChange to suppress redundant column-change reconfiguration
    @ObservationIgnored internal var isHandlingTabSwitch = false
    @ObservationIgnored var isUpdatingColumnLayout = false

    /// Guards against re-entrant confirm dialogs (e.g. nested run loop during runModal)
    @ObservationIgnored internal var isShowingConfirmAlert = false

    /// Guards against duplicate safe mode confirmation prompts
    @ObservationIgnored internal var isShowingSafeModePrompt = false

    /// Continuation for callers that need to await the result of a fire-and-forget save
    /// (e.g. save-then-close). Set before calling `saveChanges`, resumed by `executeCommitStatements`.
    @ObservationIgnored internal var saveCompletionContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - Window Lifecycle (driven by TabWindowController NSWindowDelegate)

    /// Whether this coordinator's window is the key (focused) window.
    /// Updated by TabWindowController delegate methods; consumed by
    /// event handlers (e.g. sidebar table-selection navigation filter).
    @ObservationIgnored var isKeyWindow = false

    /// Eviction task scheduled in `handleWindowDidResignKey` (fires 5s later).
    @ObservationIgnored var evictionTask: Task<Void, Never>?

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

    /// Stable instance identity. Used to key the registry so a recycled
    /// `ObjectIdentifier` from a freshly-allocated coordinator can never
    /// remove a different instance's entry from a delayed cleanup Task.
    let instanceId = UUID()

    /// Registry of active coordinators for aggregated quit-time persistence.
    /// Keyed by `instanceId` (UUID) — never by `ObjectIdentifier`, which can
    /// be recycled across allocations.
    static var activeCoordinators: [UUID: MainContentCoordinator] = [:]

    /// Register this coordinator so quit-time persistence can aggregate tabs.
    /// Idempotent — repeated registration is a no-op.
    func registerEagerly() {
        Self.activeCoordinators[instanceId] = self
    }

    private func registerForPersistence() {
        Self.activeCoordinators[instanceId] = self
    }

    private func unregisterFromPersistence() {
        Self.activeCoordinators.removeValue(forKey: instanceId)
    }

    /// Collect non-preview tabs for persistence.
    static func aggregatedTabs(for connectionId: UUID) -> [QueryTab] {
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
    static func aggregatedSelectedTabId(for connectionId: UUID) -> UUID? {
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
        for (index, tab) in tabManager.tabs.enumerated()
        where tab.id != selectedId && !tab.pendingChanges.hasChanges {
            tabSessionRegistry.evict(for: tab.id)
            // Mirror the session's epoch bump back to the QueryTab so the
            // `.task(id:)` in MainEditorContentView re-fires lazy-load on
            // re-selection. The session bump alone is not observed by SwiftUI.
            tabManager.tabs[index].loadEpoch &+= 1
        }
    }

    /// Remove sort cache entries for tabs that no longer exist
    func cleanupSortCache(openTabIds: Set<UUID>) {
        if querySortCache.keys.contains(where: { !openTabIds.contains($0) }) {
            querySortCache = querySortCache.filter { openTabIds.contains($0.key) }
        }
        if displayFormatsCache.keys.contains(where: { !openTabIds.contains($0) }) {
            displayFormatsCache = displayFormatsCache.filter { openTabIds.contains($0.key) }
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
        toolbarState: ConnectionToolbarState,
        tabSessionRegistry: TabSessionRegistry? = nil,
        queryExecutor: QueryExecutor? = nil
    ) {
        let initStart = Date()
        self.connection = connection
        self.tabManager = tabManager
        self.changeManager = changeManager
        self.toolbarState = toolbarState
        self.tabSessionRegistry = tabSessionRegistry ?? TabSessionRegistry()
        self.queryExecutor = queryExecutor ?? QueryExecutor(connection: connection)
        let dialect = PluginManager.shared.sqlDialect(for: connection.type)
        self.queryBuilder = TableQueryBuilder(
            databaseType: connection.type,
            dialect: dialect,
            dialectQuote: dialect.map { quoteIdentifierFromDialect($0) }
        )
        self.persistence = TabPersistenceCoordinator(connectionId: connection.id)

        _ = SchemaProviderRegistry.shared.getOrCreate(for: connection.id)
        SchemaProviderRegistry.shared.retain(for: connection.id)
        ConnectionDataCache.shared(for: connection.id).ensureLoaded()
        changeManager.undoManagerProvider = { [weak self] in self?.contentWindow?.undoManager }
        changeManager.onUndoApplied = { [weak self] result in self?.handleUndoResult(result) }

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

        externalFileModObserver = NotificationCenter.default.addObserver(
            forName: .linkedSQLFoldersDidUpdate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkOpenTabsForExternalModification()
            }
        }

        Self.lifecycleLogger.info(
            "[open] MainContentCoordinator.init done connId=\(connection.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(initStart) * 1_000))"
        )
    }

    private func checkOpenTabsForExternalModification() {
        for index in tabManager.tabs.indices {
            guard let url = tabManager.tabs[index].content.sourceFileURL,
                  let loadMtime = tabManager.tabs[index].content.loadMtime,
                  let currentMtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            else { continue }

            let modified = currentMtime > loadMtime.addingTimeInterval(0.5)
            if modified != tabManager.tabs[index].content.externalModificationDetected {
                tabManager.tabs[index].content.externalModificationDetected = modified
            }
        }
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
                Task {
                    self?.setupPluginDriver()
                }
            }
        }
        Self.lifecycleLogger.info(
            "[open] MainContentCoordinator.markActivated done connId=\(self.connection.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    /// Start watching the database file for external changes (SQLite, DuckDB).
    private func startFileWatcherIfNeeded() {
        guard PluginManager.shared.connectionMode(for: connection.type) == .fileBased else { return }
        let filePath = connection.database
        guard !filePath.isEmpty else { return }

        let watcher = DatabaseFileWatcher()
        watcher.watch(filePath: filePath, connectionId: connectionId) { [weak self] in
            guard let self else { return }
            if case .loading = SchemaService.shared.state(for: self.connectionId) { return }
            Task { await self.refreshTables() }
        }
        fileWatcher = watcher
    }

    /// Refresh schema only if not recently refreshed (avoids redundant work
    /// when both the file watcher and window focus trigger close together).
    func refreshTablesIfStale() async {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        await SchemaService.shared.reloadIfStale(
            connectionId: connectionId,
            driver: driver,
            connection: connection,
            staleness: 2
        )
        await reconcilePostSchemaLoad()
    }

    func showAIChatPanel() {
        inspectorProxy?.showInspector()
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
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        await SchemaService.shared.reload(
            connectionId: connectionId,
            driver: driver,
            connection: connection
        )
        await reconcilePostSchemaLoad()
    }

    /// Push the SchemaService table list into the autocomplete provider and prune sidebar
    /// state for tables that no longer exist.
    private func reconcilePostSchemaLoad() async {
        guard case .loaded(let tables) = SchemaService.shared.state(for: connectionId) else { return }
        if let driver = DatabaseManager.shared.driver(for: connectionId),
           let provider = SchemaProviderRegistry.shared.provider(for: connectionId) {
            let currentDb = DatabaseManager.shared.session(for: connectionId)?.activeDatabase
            await provider.resetForDatabase(currentDb, tables: tables, driver: driver)
        }

        guard let vm = sidebarViewModel else { return }
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

    /// Explicit cleanup called from `onDisappear`. Releases schema provider
    /// synchronously on MainActor so we don't depend on deinit + Task scheduling.
    func teardown() {
        let start = Date()
        Self.lifecycleLogger.info(
            "[close] MainContentCoordinator.teardown start connId=\(self.connection.id, privacy: .public) tabs=\(self.tabManager.tabs.count) windowId=\(self.windowId?.uuidString ?? "nil", privacy: .public)"
        )
        _didTeardown.withLock { $0 = true }

        unregisterFromPersistence()
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }
        if let observer = pluginDriverObserver {
            NotificationCenter.default.removeObserver(observer)
            pluginDriverObserver = nil
        }
        if let observer = externalFileModObserver {
            NotificationCenter.default.removeObserver(observer)
            externalFileModObserver = nil
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

        NotificationCenter.default.post(
            name: Self.teardownNotification,
            object: connection.id
        )

        tabSessionRegistry.removeAll()
        querySortCache.removeAll()
        displayFormatsCache.removeAll()
        cachedTableColumnTypes.removeAll()
        cachedTableColumnNames.removeAll()

        tabManager.tabs.removeAll()
        tabManager.selectedTabId = nil

        // Release change manager state — pluginDriver holds a strong reference
        // to the entire database driver which prevents deallocation
        changeManager.clearChanges()
        changeManager.pluginDriver = nil

        // Release metadata
        tableMetadata = nil

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
            let id = instanceId
            Task { @MainActor in
                Self.activeCoordinators.removeValue(forKey: id)
            }
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

    /// Load schema if not already loaded by another window for this connection.
    func loadSchemaIfNeeded() async {
        await loadSchema()
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
        await SchemaService.shared.load(
            connectionId: connectionId,
            driver: driver,
            connection: connection
        )
        await reconcilePostSchemaLoad()
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

    // MARK: - Query Execution

    func runQuery() {
        guard let (tab, index) = tabManager.selectedTabAndIndex,
              !tab.execution.isExecuting else { return }

        let fullQuery = tab.content.query

        let sql: String
        if tab.tabType == .table {
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

        if AppSettingsManager.shared.editor.queryParametersEnabled {
            let paramStatements = SQLStatementScanner.allStatements(in: sql)
            guard !paramStatements.isEmpty else { return }
            let combinedSQL = paramStatements.joined(separator: "; ")
            let detectedNames = SQLParameterExtractor.extractParameters(from: combinedSQL)

            if !detectedNames.isEmpty {
                let reconciled = detectAndReconcileParameters(
                    sql: combinedSQL,
                    existing: tabManager.tabs[index].content.queryParameters
                )
                tabManager.tabs[index].content.queryParameters = reconciled

                if !tabManager.tabs[index].content.isParameterPanelVisible {
                    tabManager.tabs[index].content.isParameterPanelVisible = true
                    return
                }

                tabManager.tabStructureVersion += 1
                dispatchParameterizedStatements(
                    paramStatements,
                    parameters: reconciled,
                    tabIndex: index
                )
                return
            }
        }

        let statements = SQLStatementScanner.allStatements(in: sql)
        guard !statements.isEmpty else { return }

        tabManager.tabStructureVersion += 1
        dispatchStatements(statements, tabIndex: index)
    }

    /// Execute table tab query directly.
    /// Table tab queries are always app-generated SELECTs, so they skip dangerous-query
    /// checks but still respect safe mode levels that apply to all queries.
    func executeTableTabQueryDirectly() {
        guard let (tab, index) = tabManager.selectedTabAndIndex,
              !tab.execution.isExecuting else { return }

        let sql = tab.content.query
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let level = safeModeLevel
        if level.appliesToAllQueries && level.requiresConfirmation,
           tab.execution.lastExecutedAt == nil
        {
            guard !isShowingSafeModePrompt else { return }
            isShowingSafeModePrompt = true
            Task {
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
                        tabManager.tabs[index].execution.errorMessage = reason
                    }
                }
            }
        } else {
            executeQueryInternal(sql)
        }
    }

    // MARK: - Editor Query Loading

    func loadQueryIntoEditor(_ query: String) {
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query {
            tabManager.tabs[tabIndex].content.query = query
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
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query {
            let existingQuery = tab.content.query
            if existingQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tabManager.tabs[tabIndex].content.query = query
            } else {
                tabManager.tabs[tabIndex].content.query = existingQuery + "\n\n" + query
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
        guard let (tab, _) = tabManager.selectedTabAndIndex,
              !tab.execution.isExecuting else { return }

        let fullQuery = tab.content.query

        let sql: String
        if tab.tabType == .table {
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
                Task {
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
            if let (_, index) = tabManager.selectedTabAndIndex {
                tabManager.tabs[index].execution.errorMessage = String(localized: "EXPLAIN is not supported for this database type.")
            }
            return
        }

        if needsConfirmation {
            Task {
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
            Task {
                executeQueryInternal(explainSQL)
            }
        }
    }

    internal func executeQueryInternal(
        _ sql: String
    ) {
        guard let (selectedTab, index) = tabManager.selectedTabAndIndex,
              !selectedTab.execution.isExecuting else { return }

        if currentQueryTask != nil {
            currentQueryTask?.cancel()
            do {
                try DatabaseManager.shared.driver(for: connectionId)?.cancelQuery()
            } catch {
                Self.logger.warning("cancelQuery failed: \(error.localizedDescription, privacy: .public)")
            }
            currentQueryTask = nil
        }
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        var tab = tabManager.tabs[index]
        tab.execution.isExecuting = true
        tab.execution.executionTime = nil
        tab.execution.errorMessage = nil
        tab.display.explainText = nil
        tab.display.explainPlan = nil
        tabManager.tabs[index] = tab
        toolbarState.setExecuting(true)

        if PluginManager.shared.supportsQueryProgress(for: connection.type) {
            installClickHouseProgressHandler()
        }

        let conn = connection
        let tabId = tabManager.tabs[index].id

        let rowCap = resolveRowCap(sql: sql, tabType: tab.tabType)
        let (tableName, isEditable) = resolveTableEditability(tab: tab, sql: sql)

        let needsMetadataFetch: Bool
        if isEditable, let tableName {
            needsMetadataFetch = !isMetadataCached(tabId: tabId, tableName: tableName)
        } else {
            needsMetadataFetch = false
        }

        currentQueryTask = Task { [weak self] in
            guard let self else { return }

            do {
                let executionResult = try await queryExecutor.executeQuery(
                    sql: sql,
                    parameters: nil,
                    rowCap: rowCap,
                    tableName: tableName,
                    fetchSchemaForTable: needsMetadataFetch
                )

                guard !Task.isCancelled else {
                    await resetExecutionState(
                        tabId: tabId,
                        executionTime: executionResult.fetchResult.executionTime
                    )
                    return
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    currentQueryTask = nil
                    if PluginManager.shared.supportsQueryProgress(for: self.connection.type) {
                        self.clearClickHouseProgress()
                    }
                    toolbarState.setExecuting(false)
                    toolbarState.lastQueryDuration = executionResult.fetchResult.executionTime

                    if capturedGeneration != queryGeneration || Task.isCancelled {
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].execution.isExecuting = false
                        }
                        return
                    }

                    applyPhase1Result(
                        tabId: tabId,
                        columns: executionResult.fetchResult.columns,
                        columnTypes: executionResult.fetchResult.columnTypes,
                        rows: executionResult.fetchResult.rows,
                        executionTime: executionResult.fetchResult.executionTime,
                        rowsAffected: executionResult.fetchResult.rowsAffected,
                        statusMessage: executionResult.fetchResult.statusMessage,
                        tableName: tableName,
                        isEditable: isEditable,
                        metadata: executionResult.parsedMetadata,
                        hasSchema: executionResult.schemaResult != nil,
                        sql: sql,
                        connection: conn,
                        isTruncated: executionResult.fetchResult.isTruncated
                    )
                }

                if isEditable, let tableName {
                    if needsMetadataFetch {
                        launchPhase2Work(
                            tableName: tableName,
                            tabId: tabId,
                            capturedGeneration: capturedGeneration,
                            connectionType: conn.type,
                            schemaResult: executionResult.schemaResult
                        )
                    } else {
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
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        var tab = tabManager.tabs[idx]
                        tab.execution.isExecuting = false
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
    internal func resetExecutionState(tabId: UUID, executionTime: TimeInterval) {
        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
            tabManager.tabs[idx].execution.isExecuting = false
        }
        currentQueryTask = nil
        toolbarState.setExecuting(false)
        toolbarState.lastQueryDuration = executionTime
    }

    internal func resolveTableEditability(tab: QueryTab, sql: String) -> (tableName: String?, isEditable: Bool) {
        let usesNoSQLBrowsing = PluginManager.shared.editorLanguage(for: connection.type) != .sql
            || (DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter)?
                .queryBuildingPluginDriver != nil
        if usesNoSQLBrowsing {
            let name = tabManager.selectedTab?.tableContext.tableName
            return (name, name != nil)
        } else if tab.tabType == .table, let existingName = tab.tableContext.tableName {
            return (existingName, true)
        } else {
            let name = extractTableName(from: sql)
            return (name, name != nil)
        }
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
                if let values = QuerySqlParser.parseSQLiteCheckConstraintValues(
                    createSQL: createSQL, columnName: col.name
                ) {
                    result[col.name] = values
                }
            }
        }

        return result
    }

    // MARK: - SQL Helpers

    static func stripTrailingOrderBy(from sql: String) -> String {
        QuerySqlParser.stripTrailingOrderBy(from: sql)
    }

    // MARK: - SQL Parsing

    func extractTableName(from sql: String) -> String? {
        QuerySqlParser.extractTableName(from: sql)
    }

    // MARK: - Sorting

    func handleSort(columnIndex: Int, ascending: Bool, isMultiSort: Bool = false) {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex else { return }

        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        guard columnIndex >= 0 && columnIndex < tableRows.columns.count else { return }

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
                let columnName = tableRows.columns[columnIndex]
                let direction = currentSort.columns.first?.direction == .ascending ? "ASC" : "DESC"
                let baseQuery = tab.pagination.baseQueryForMore ?? tab.content.query
                let strippedQuery = Self.stripTrailingOrderBy(from: baseQuery)
                let quotedColumn = queryBuilder.quoteIdentifier(columnName)
                let orderQuery = "\(strippedQuery) ORDER BY \(quotedColumn) \(direction)"
                tabManager.tabs[tabIndex].sortState = currentSort
                tabManager.tabs[tabIndex].hasUserInteraction = true
                tabManager.tabs[tabIndex].pagination.resetLoadMore()
                tabManager.tabs[tabIndex].content.query = orderQuery
                runQuery()
                return
            }

            tabManager.tabs[tabIndex].sortState = currentSort
            tabManager.tabs[tabIndex].hasUserInteraction = true
            tabManager.tabs[tabIndex].pagination.reset()
            let tabId = tab.id
            let schemaVersion = tab.schemaVersion
            let sortColumns = currentSort.columns
            let colTypes = tableRows.columnTypes
            let storageRows = tableRows.rows
            let snapshotRows: [(id: RowID, values: [String?])] = storageRows.map { ($0.id, $0.values) }

            if storageRows.count > 1_000 {
                // Sort on background thread to avoid UI freeze
                activeSortTasks[tabId]?.cancel()
                activeSortTasks.removeValue(forKey: tabId)
                tabManager.tabs[tabIndex].execution.isExecuting = true
                toolbarState.setExecuting(true)
                querySortCache.removeValue(forKey: tabId)

                let sortStartTime = Date()
                let task = Task.detached { [weak self] in
                    let sortedIDs = Self.multiColumnSortedIDs(
                        rows: snapshotRows,
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
                            sortedIDs: sortedIDs,
                            columnIndex: sortColumns.first?.columnIndex ?? 0,
                            direction: sortColumns.first?.direction ?? .ascending,
                            schemaVersion: schemaVersion
                        )
                        var sortedTab = self.tabManager.tabs[idx]
                        sortedTab.execution.isExecuting = false
                        sortedTab.execution.executionTime = sortDuration
                        self.tabManager.tabs[idx] = sortedTab
                        self.toolbarState.setExecuting(false)
                        self.toolbarState.lastQueryDuration = sortDuration
                        self.activeSortTasks.removeValue(forKey: tabId)
                        self.dataTabDelegate?.dataGridDidReplaceAllRows()
                    }
                }
                activeSortTasks[tabId] = task
            } else {
                dataTabDelegate?.dataGridDidReplaceAllRows()
            }
            return
        }

        let tabId = tab.id
        let capturedSort = currentSort
        let capturedQuery = tab.content.query
        let capturedColumns = tableRows.columns
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
            self.tabManager.tabs[idx].content.query = newQuery
            self.runQuery()
        }
    }

    func removeMultiSortColumn(columnIndex: Int) {
        guard let tab = tabManager.selectedTab else { return }
        guard let existing = tab.sortState.columns.first(where: { $0.columnIndex == columnIndex }) else { return }
        let ascending = existing.direction == .ascending
        handleSort(columnIndex: columnIndex, ascending: ascending, isMultiSort: true)
    }

    func clearSort() {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex else { return }
        guard tab.sortState.isSorting else { return }

        let emptySort = SortState()

        if tab.tabType == .query {
            tabManager.tabs[tabIndex].sortState = emptySort
            tabManager.tabs[tabIndex].hasUserInteraction = true
            querySortCache.removeValue(forKey: tab.id)
            dataTabDelegate?.dataGridDidReplaceAllRows()
            return
        }

        let tabId = tab.id
        let capturedQuery = tab.content.query
        confirmDiscardChangesIfNeeded(action: .sort) { [weak self] confirmed in
            guard let self, confirmed,
                  let idx = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
            self.tabManager.tabs[idx].sortState = emptySort
            self.tabManager.tabs[idx].hasUserInteraction = true
            self.tabManager.tabs[idx].pagination.reset()
            self.tabManager.tabs[idx].content.query = Self.stripTrailingOrderBy(from: capturedQuery)
            self.runQuery()
        }
    }

    /// Multi-column sort returning a permutation of `RowID` (nonisolated for background thread).
    nonisolated private static func multiColumnSortedIDs(
        rows: [(id: RowID, values: [String?])],
        sortColumns: [SortColumn],
        columnTypes: [ColumnType] = []
    ) -> [RowID] {
        // Fast path: single-column sort avoids intermediate key array allocation
        if sortColumns.count == 1 {
            let col = sortColumns[0]
            let colIndex = col.columnIndex
            let ascending = col.direction == .ascending
            let colType = colIndex < columnTypes.count ? columnTypes[colIndex] : nil
            var indices = Array(0..<rows.count)
            indices.sort { i1, i2 in
                let row1 = rows[i1].values
                let row2 = rows[i2].values
                let v1 = colIndex < row1.count ? (row1[colIndex] ?? "") : ""
                let v2 = colIndex < row2.count ? (row2[colIndex] ?? "") : ""
                let cmp = RowSortComparator.compare(v1, v2, columnType: colType)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
            return indices.map { rows[$0].id }
        }

        var indices = Array(0..<rows.count)
        indices.sort { i1, i2 in
            let row1 = rows[i1].values
            let row2 = rows[i2].values
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
        return indices.map { rows[$0].id }
    }
}
