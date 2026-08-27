//
//  MainContentCoordinator.swift
//  TablePro
//
//  Coordinator managing business logic for MainContentView.
//  Separates view logic from presentation for better maintainability.
//

import CodeEditSourceEditor
import Combine
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
    case resultSwitch
}

struct DisplayFormatsCacheEntry {
    let schemaVersion: Int
    let resultSetId: UUID?
    let smartDetectionEnabled: Bool
    let overridesVersion: Int
    let formats: [ValueDisplayFormat?]

    func matches(
        schemaVersion: Int,
        resultSetId: UUID?,
        smartDetectionEnabled: Bool,
        overridesVersion: Int
    ) -> Bool {
        self.schemaVersion == schemaVersion
            && self.resultSetId == resultSetId
            && self.smartDetectionEnabled == smartDetectionEnabled
            && self.overridesVersion == overridesVersion
    }
}

/// Represents which sheet is currently active in MainContentView.
/// Uses a single `.sheet(item:)` modifier instead of multiple `.sheet(isPresented:)`.
enum ActiveSheet: Identifiable {
    case sqlPreview
    case exportDialog
    case importDialog(formatId: String)
    case rowImport(formatId: String)
    case exportQueryResults
    case backupDatabase
    case restoreDatabase(fileURL: URL)
    /// The object's own database and schema travel with the request. A maintenance statement names
    /// its table and nothing else, so acting on wherever the object browser happens to point
    /// maintains the same-named table in another database whenever the two have drifted apart.
    /// This is the rule the sidebar's other destructive commands already keep by carrying their ref.
    case maintenance(operation: String, tableName: String, database: String?, schema: String?)
    case createDatabase
    case rewind

    var id: String {
        switch self {
        case .sqlPreview: "sqlPreview"
        case .exportDialog: "exportDialog"
        case .importDialog(let formatId): "importDialog-\(formatId)"
        case .rowImport(let formatId): "rowImport-\(formatId)"
        case .exportQueryResults: "exportQueryResults"
        case .backupDatabase: "backupDatabase"
        case .restoreDatabase(let fileURL): "restoreDatabase-\(fileURL.path)"
        case .maintenance(let operation, let tableName, let database, let schema):
            "maintenance-\(operation)-\(database ?? "")-\(schema ?? "")-\(tableName)"
        case .createDatabase: "createDatabase"
        case .rewind: "rewind"
        }
    }
}

/// Coordinator managing MainContentView business logic
@MainActor @Observable
final class MainContentCoordinator {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")
    nonisolated static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    /// Monotonic counter for correlating rapid tab-switch/close log entries.
    static var switchSeq: Int = 0
    static func nextSwitchSeq() -> Int {
        switchSeq += 1
        return switchSeq
    }

    // MARK: - Dependencies

    @ObservationIgnored let services: AppServices
    let connection: DatabaseConnection
    var connectionId: UUID { connection.id }
    var sqlDialect: SqlDialect { SqlDialect.from(databaseTypeId: connection.type.rawValue) }
    var browseDatabaseName: String {
        services.databaseManager.browseDatabaseName(for: connection)
    }
    var safeModeLevel: SafeModeLevel { toolbarState.safeModeLevel }
    func setSafeModeLevel(_ level: SafeModeLevel) {
        toolbarState.safeModeLevel = level
        services.databaseManager.setSafeModeLevel(level, for: connectionId)
    }
    let selectionState = GridSelectionState()
    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let toolbarState: ConnectionToolbarState
    let tabSessionRegistry: TabSessionRegistry
    let queryExecutor: QueryExecutor
    let windowSidebarState: WindowSidebarState
    /// Which tab each of this connection's containers was last on, so the connections strip lands
    /// on that container's work instead of leaving a tab from another database on screen.
    @ObservationIgnored internal var containerTabHistory = ContainerTabHistory()

    // MARK: - Services

    internal var queryBuilder: TableQueryBuilder
    let persistence: TabPersistenceCoordinator
    @ObservationIgnored internal lazy var rowOperationsManager: RowOperationsManager = {
        RowOperationsManager(changeManager: changeManager)
    }()

    @ObservationIgnored private(set) var filterCoordinator: FilterCoordinator!
    @ObservationIgnored private(set) var findCoordinator: FindCoordinator!
    @ObservationIgnored private(set) var queryExecutionCoordinator: QueryExecutionCoordinator!
    @ObservationIgnored private(set) var paginationCoordinator: PaginationCoordinator!
    @ObservationIgnored private(set) var rowEditingCoordinator: RowEditingCoordinator!

    /// Stable identifier for this coordinator's window (set by MainContentView on appear)
    var windowId: UUID?

    /// Setting this presents the favorite-edit dialog sheet from `MainEditorContentView`.
    var favoriteDialogQuery: FavoriteDialogQuery?

    /// Direct reference to sidebar viewmodel, eliminates global notification broadcasts
    weak var sidebarViewModel: SidebarViewModel?

    /// Direct reference to structure view actions — eliminates notification broadcasts
    weak var structureActions: StructureViewActionHandler?

    /// Raised while a close is applying the staged structure edits of tabs it is about to close.
    /// Each apply broadcasts a data refresh for its scope, and a mounted structure view on the same
    /// database answers that by asking whether to discard its own staged edits, which mid-close is
    /// a question the user cannot usefully answer. Scoped by the caller's `defer`, never latched.
    var isApplyingStagedStructureEdits = false

    /// Direct reference to create-table view actions so the Save Changes menu
    /// (Cmd+S) routes to table creation. Set by `CreateTableView` on appear.
    weak var createTableActions: CreateTableActionHandler?

    weak var usersRolesActions: UsersRolesActionHandler?

    /// Staged structure edits and table drafts, per tab. They belong here rather than in the view
    /// for two reasons: the view is destroyed on every tab switch and on every switch between Data
    /// and Structure, and the close gate has to be able to see the staged work of a tab the user is
    /// not currently looking at.
    var structureSessions: [UUID: StructureEditingSession] = [:]
    var createTableDrafts: [UUID: CreateTableDraft] = [:]

    /// Tabs holding staged principal changes. `usersRolesActions` is nilled the moment the tab is
    /// deselected, but the view model behind it is cached per tab id and keeps the staged work, so
    /// without this record a background Users & Roles tab reports itself clean and closes silently.
    @ObservationIgnored internal var tabsWithStagedPrincipals: Set<UUID> = []

    /// Tabs whose close confirmation is already on screen. `saveCompletionContinuation` is a single
    /// slot, so a second gesture arriving before the first sheet resolves would overwrite the
    /// continuation the first one is suspended on and leave that task waiting forever.
    @ObservationIgnored internal var tabClosesInFlight: Set<UUID> = []

    /// The grid that owns the current selection when it is not the data grid, so the
    /// inspector reads the selected row from it instead of the data tab's rows.
    /// Set by `TableStructureView` and `CreateTableView` on appear.
    weak var inspectorRowSource: (any InspectorRowSource)?

    /// Bumped whenever a published schema row changes, so the inspector re-reads it.
    var inspectorRowSourceRevision: Int = 0

    /// Direct reference to AI chat viewmodel — eliminates notification broadcasts
    weak var aiViewModel: AIChatViewModel?

    weak var rightPanelState: RightPanelState?

    /// Direct reference to the data tab grid delegate — enables row mutation operations to
    /// Observable mirror of the grid's display revision, so views outside the grid re-render when
    /// the value filter or the displayed order changes. The grid's own state lives on a plain
    /// AppKit object reached through observation-ignored hops, so it cannot invalidate a view.
    var gridDisplayRevision: Int = 0

    /// dispatch insertRows/removeRows directly to the NSTableView via DataGridViewDelegate.
    @ObservationIgnored weak var dataTabDelegate: DataTabGridDelegate?

    var activeGridDisplayIDs: [RowID]? {
        guard let tabId = tabManager.selectedTab?.id else { return nil }
        return displayIDs(forTab: tabId)
    }

    /// One-shot intent set when the user explicitly opens a table (Return/double-click),
    /// consumed by the grid as it appears to move focus into it. Never set on mere selection.
    @ObservationIgnored var pendingGridFocusOnOpen = false

    /// Proxy for toggling the inspector NSSplitViewItem from coordinator code
    @ObservationIgnored weak var inspectorProxy: InspectorVisibilityProxy?

    /// Direct reference to split view controller for sidebar toggle
    @ObservationIgnored weak var splitViewController: MainSplitViewController?

    /// Direct reference to this coordinator's content window, used for presenting alerts.
    /// Avoids NSApp.keyWindow which may return a sheet window, causing stuck dialogs.
    @ObservationIgnored weak var contentWindow: NSWindow?

    /// Back-reference to this coordinator's command actions, enabling window → coordinator → actions
    /// lookup. The app runs the AppKit lifecycle with no SwiftUI `Scene`, so a focused value has
    /// nothing to resolve against; this reference reaches every caller, AppKit and SwiftUI alike.
    @ObservationIgnored weak var commandActions: MainContentCommandActions?

    /// Presents the quick switcher as a floating panel anchored over this coordinator's window.
    /// The window owns it, because the panel anchors on the window and every connection the window
    /// hosts would otherwise bring one of its own to the same point.
    var quickSwitcherPanel: QuickSwitcherPanelController? {
        splitViewController?.quickSwitcherPanel
    }

    // MARK: - Published State

    var cursorPositions: [CursorPosition] = []
    var tableMetadata: TableMetadata?
    var activeSheet: ActiveSheet?
    /// Which scope the toolbar chip is showing a chooser for, so the popover opens against the
    /// component the user clicked. Separate from the switchers the presenter owns, and cleared
    /// alongside them so a window never holds two of them.
    var presentedScopeSwitcher: ContainerSwitchTarget?
    /// Owns the connection and database switcher surfaces. The commands present through this
    /// rather than flipping a flag a toolbar-hosted view has to observe, because that view is
    /// absent whenever its item is clipped into the overflow menu or removed by the user. It
    /// belongs to the window for the same reason the panel it drives does.
    var switcherPresenter: ToolbarSwitcherPresenter? {
        splitViewController?.switcherPresenter
    }
    var sessionContexts: [PluginSessionContext] = []
    var containerDropRequest: DatabaseDropRequest?
    var importFileURL: URL?
    var exportPreselection: ExportPreselection?
    var pendingLoadTrigger: TableLoadTrigger?
    @ObservationIgnored var deferredRestoreLoadTabId: UUID?

    @ObservationIgnored var displayFormatsCache: [UUID: DisplayFormatsCacheEntry] = [:]
    @ObservationIgnored var displayOrderCache: [UUID: DisplayOrderCacheEntry] = [:]
    @ObservationIgnored var displayStateCache: [UUID: DisplayStateCacheEntry] = [:]
    @ObservationIgnored var tableMetadataCache: [UUID: TableMetadataCacheEntry] = [:]
    @ObservationIgnored var displayStateClock = 0

    @ObservationIgnored let schemaColumns = SchemaColumnStore()
    @ObservationIgnored var columnScopeRequeryTask: Task<Void, Never>?

    @ObservationIgnored var pendingScrollToTopAfterReplace: Set<UUID> = []

    @ObservationIgnored var openTabInNewWindow: (EditorTabPayload) -> Void = {
        WindowManager.shared.openTab(payload: $0)
    }

    @ObservationIgnored var connectionExists: (UUID) -> Bool = { id in
        ConnectionStorage.shared.loadConnections().contains { $0.id == id }
    }

    /// Routing failures report through here so a test can observe the message instead of raising a
    /// real alert. `AlertHelper.present` runs application-modal when no window qualifies, and a
    /// unit test host has no window, so calling it directly parks the main thread in a modal loop
    /// that nothing can dismiss and no test time limit can interrupt.
    @ObservationIgnored var presentError: (String, String, NSWindow?) -> Void = { title, message, window in
        AlertHelper.showErrorSheet(title: title, message: message, window: window)
    }

    // MARK: - Internal State

    /// Per-tab execution ownership. Replaces a per-window generation counter, a stored per-tab
    /// `isExecuting` bool and two task handles that a tab retarget participated in none of.
    ///
    /// Deliberately observed rather than `@ObservationIgnored`: busy state is derived from
    /// membership here, so the views that used to read the stored flag have to be able to see it
    /// change. It is a value type, so every claim, settle and invalidate is a write to this
    /// property and invalidates its readers.
    internal var tabExecution = TabExecutionRegistry()
    @ObservationIgnored internal var currentQueryTask: Task<Void, Never>?

    /// Which claim installed `currentQueryTask`. The handle is one per window while claims are one
    /// per tab, so owning your own tab is not the same as owning the query the window is running:
    /// superseding tab B cancels tab A's task, and A's completion would otherwise nil out B's
    /// handle and leave B's query with no spinner and no way to stop it.
    @ObservationIgnored internal var currentQueryTaskOwner: TabExecutionClaim?
    @ObservationIgnored internal var rowCountTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Which user-requested exact count currently owns each tab's counting indicator.
    @ObservationIgnored internal var exactCountOwners: [UUID: UUID] = [:]
    @ObservationIgnored internal var tableLoadTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Each tab's browse history, keyed by tab id the way the other per-tab caches here are.
    ///
    /// Not a field on `QueryTab`: that struct is the persisted shape of a tab, and an entry
    /// describes rows that may be gone by the next launch. Keeping it out of the struct also keeps
    /// it out of the hand-written `Equatable`, so a push never re-publishes the tab list.
    @ObservationIgnored internal var navigationHistories: [UUID: TabNavigationHistory] = [:]

    /// The row a restored tab should land on, keyed by tab because one grid coordinator serves
    /// every tab in the window. Set when a navigation starts and consumed by the first draw that
    /// has the rows, or dropped with the tab.
    @ObservationIgnored internal var pendingRowAnchors: [UUID: [String: String]] = [:]
    @ObservationIgnored internal var redisDatabaseSwitchTask: Task<Void, Never>?
    @ObservationIgnored private var periodicSaveTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored internal var postConnectCancellable: AnyCancellable?
    @ObservationIgnored private var externalFileModCancellable: AnyCancellable?
    @ObservationIgnored private var schemaSwitchCancellable: AnyCancellable?

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

    /// What restoring the last save would do, once it has been planned against the live rows.
    internal var rewindPlan: RewindPlan?

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

    @ObservationIgnored var refreshCoalesceTask: Task<Void, Never>?
    @ObservationIgnored var refreshPendingTrailing = false

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

    var isActivated: Bool {
        _didActivate.withLock { $0 }
    }

    /// One window hosts every connection and a connection has one coordinator, so a
    /// connection's tabs are simply that coordinator's list. Tabs used to be scattered across
    /// a connection's windows and had to be gathered and renumbered.
    static func aggregatedTabs(for connectionId: UUID) -> [QueryTab] {
        activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .flatMap { coordinator in
                coordinator.tabManager.tabs.map(coordinator.enrichedForPersistence)
            }
    }

    /// Resolve transient view state that only the live coordinator knows about
    /// (sort column names, editor cursor offset) onto the tab before it is serialized.
    func enrichedForPersistence(_ tab: QueryTab) -> QueryTab {
        var enriched = tab
        if enriched.sortState.isSorting {
            let columns = columnsForPersistence(of: tab)
            enriched.sortState.columns = enriched.sortState.columns.map { column in
                guard column.columnName == nil,
                      column.columnIndex >= 0,
                      column.columnIndex < columns.count else { return column }
                var named = column
                named.columnName = columns[column.columnIndex]
                return named
            }
        }
        // Only when there is a live caret to write. `cursorPositions` starts empty and is fed by
        // the editor's own change events, so a tab whose editor never became first responder has
        // none, and writing that absence over the tab's saved caret discards it.
        if tab.tabType == .query, tab.id == tabManager.selectedTabId,
           let range = cursorPositions.first?.range {
            enriched.restoredCursorOffset = range.location
            enriched.restoredCursorLength = range.length
        }
        return enriched
    }

    private func columnsForPersistence(of tab: QueryTab) -> [String] {
        let buffer = tabSessionRegistry.tableRows(for: tab.id)
        return buffer.columns.isEmpty ? effectiveResultColumns(for: tab) : buffer.columns
    }

    /// Map persisted sort columns (keyed by name) back to indices into the live column set.
    /// Columns that no longer exist are dropped, so a renamed or removed column degrades gracefully.
    static func resolveRestoredSortColumns(
        _ persisted: [PersistedSortColumn],
        in columns: [String]
    ) -> [SortColumn] {
        persisted.compactMap { column in
            guard let columnIndex = columns.firstIndex(of: column.columnName) else { return nil }
            return SortColumn(columnIndex: columnIndex, direction: column.direction, columnName: column.columnName)
        }
    }

    /// The selection a query tab was left with, as a range to hand straight to the editor.
    ///
    /// The editor applies this once through its own controller rather than through the cursor
    /// binding, so this is a plain read. The value stays on the tab until the editor reports it
    /// consumed, because `body` runs many times before the text view exists.
    func restoredCursorRange(for tabId: UUID) -> NSRange? {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tabType == .query,
              let offset = tabManager.tabs[index].restoredCursorOffset else { return nil }
        let length = (tabManager.tabs[index].content.query as NSString).length
        let clamped = min(max(0, offset), length)
        let selectionLength = min(tabManager.tabs[index].restoredCursorLength ?? 0, length - clamped)
        return NSRange(location: clamped, length: max(0, selectionLength))
    }

    /// The regions collapsed in a query tab.
    ///
    /// Folds live on the tab rather than on the window, so switching tabs cannot carry one tab's collapsed regions
    /// onto another and nothing has to be cleared when a tab appears.
    func foldRanges(for tabId: UUID) -> [Range<Int>]? {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tabType == .query else { return nil }
        return tabManager.tabs[index].collapsedFoldRanges
    }

    func recordFoldRanges(_ ranges: [Range<Int>], for tabId: UUID) {
        let stored = ranges.isEmpty ? nil : ranges
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].collapsedFoldRanges != stored else { return }
        tabManager.mutate(at: index) {
            $0.collapsedFoldRanges = stored
        }
    }

    /// The statement a selected result asked the editor to go to, if one is waiting.
    func pendingStatementJump(for tabId: UUID) -> StatementAnchor? {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tabType == .query else { return nil }
        return tabManager.tabs[index].pendingStatementJump
    }

    /// Asks the tab's editor to take the reader to `anchor`.
    ///
    /// The anchor is stored rather than applied, because the editor owns the text this has to be resolved against and
    /// may not be mounted yet. It is cleared as soon as an editor consumes it, so selecting the same result again
    /// asks again rather than being swallowed as an unchanged value.
    func requestStatementJump(_ anchor: StatementAnchor, in tabId: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tabType == .query else { return }
        tabManager.mutate(at: index) { $0.pendingStatementJump = anchor }
    }

    func clearPendingStatementJump(for tabId: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].pendingStatementJump != nil else { return }
        tabManager.mutate(at: index) { $0.pendingStatementJump = nil }
    }

    func clearRestoredCursor(for tabId: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].restoredCursorOffset != nil
                  || tabManager.tabs[index].restoredCursorLength != nil else { return }
        tabManager.mutate(at: index) {
            $0.restoredCursorOffset = nil
            $0.restoredCursorLength = nil
        }
    }

    private static let periodicSaveInterval: Duration = .seconds(30)
    private static let draftSaveDebounce: Duration = .seconds(1)

    /// Persist shortly after the user stops typing. Editing query text changes no tab
    /// identity, so it drives none of the structural saves, and without this a scratch
    /// query lives only in memory until the 30 second timer or the quit-time flush.
    func scheduleDraftSave() {
        guard !Self.isAppTerminating, !isTearingDown else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.draftSaveDebounce)
            guard let self, !Task.isCancelled, !Self.isAppTerminating, !self.isTearingDown else { return }
            guard self.isFirstCoordinatorForConnection() else { return }
            self.persistence.saveAggregated()
        }
    }

    private func startPeriodicSave() {
        guard periodicSaveTask == nil else { return }
        periodicSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicSaveInterval)
                guard let self, !Task.isCancelled, !Self.isAppTerminating, !self.isTearingDown else { return }
                guard self.isFirstCoordinatorForConnection() else { continue }
                self.persistence.saveAggregated()
            }
        }
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

    /// Frees the row data of every background tab that can fetch it again, called when this
    /// coordinator's window stops being key. The selected tab keeps its rows so returning to the
    /// window costs no refresh, and `canEvictReloadableTableRows` decides the rest: a query tab, a
    /// tab holding a pinned result, a failed tab and a tab with work in flight all stay resident,
    /// because none of them would come back on their own.
    func evictInactiveRowData() {
        for tab in tabManager.tabs {
            evictReloadableTableRows(for: tab.id)
        }
    }

    // MARK: - Initialization

    init(
        connection: DatabaseConnection,
        tabManager: QueryTabManager,
        changeManager: DataChangeManager,
        toolbarState: ConnectionToolbarState,
        tabSessionRegistry: TabSessionRegistry? = nil,
        queryExecutor: QueryExecutor? = nil,
        services: AppServices = .live
    ) {
        let initStart = Date()
        self.services = services
        self.connection = connection
        self.windowSidebarState = WindowSidebarState(connectionId: connection.id)
        self.tabManager = tabManager
        self.changeManager = changeManager
        self.toolbarState = toolbarState
        let resolvedRegistry = tabSessionRegistry ?? TabSessionRegistry()
        self.tabSessionRegistry = resolvedRegistry
        tabManager.bindTabSessionRegistry(resolvedRegistry)
        self.queryExecutor = queryExecutor ?? QueryExecutor(connection: connection)
        let dialect = services.pluginManager.sqlDialect(for: connection.type)
        self.queryBuilder = TableQueryBuilder(
            databaseType: connection.type,
            dialect: dialect,
            dialectQuote: dialect.map { quoteIdentifierFromDialect($0) }
        )
        self.persistence = TabPersistenceCoordinator(connectionId: connection.id)

        ConnectionDataCache.shared(for: connection.id).ensureLoaded()
        changeManager.undoManagerProvider = { [weak self] in self?.contentWindow?.undoManager }
        changeManager.onUndoApplied = { [weak self] result in self?.handleUndoResult(result) }
        tabManager.onTabRetargeted = { [weak self] tabId in
            self?.dataTabDelegate?.tableViewCoordinator?.flushPendingColumnLayoutPersistence()
            self?.supersedeExecution(for: tabId)
            self?.releaseRetargetedTabState(for: tabId)
        }

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
                self.dataTabDelegate?.tableViewCoordinator?.flushPendingColumnLayoutPersistence()
                // Only the first coordinator for this connection saves,
                // aggregating tabs from all windows to fix last-write-wins bug.
                // Skip isTearingDown check: during Cmd+Q, onDisappear fires
                // markTeardownScheduled() before willTerminate, and we still
                // need to save here.
                let allTabs = Self.aggregatedTabs(for: self.connectionId)
                let selectedId = Self.aggregatedSelectedTabId(for: self.connectionId)
                self.persistence.saveNowSync(tabs: allTabs, selectedTabId: selectedId)
            }
        }

        _ = Self.registerTerminationObserver

        externalFileModCancellable = services.appEvents.linkedSQLFoldersDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                guard payload == nil || payload == self.connectionId else { return }
                self.checkOpenTabsForExternalModification()
            }

        schemaSwitchCancellable = services.appEvents.currentSchemaChanged
            .sink { [weak self] changedConnectionId in
                guard let self, changedConnectionId == self.connectionId else { return }
                Task { @MainActor in
                    if let schema = self.services.databaseManager.session(for: self.connectionId)?.browseSchema {
                        self.toolbarState.currentSchema = schema
                    }
                    await self.refreshTables()
                }
            }

        self.filterCoordinator = FilterCoordinator(parent: self)
        self.findCoordinator = FindCoordinator(parent: self)
        self.queryExecutionCoordinator = QueryExecutionCoordinator(parent: self)
        self.paginationCoordinator = PaginationCoordinator(parent: self)
        self.rowEditingCoordinator = RowEditingCoordinator(parent: self)

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
                tabManager.mutate(at: index) { $0.content.externalModificationDetected = modified }
            }
        }
    }

    func markActivated() {
        let start = Date()
        let wasAlreadyActive = _didActivate.withLock { current -> Bool in
            let prior = current
            current = true
            return prior
        }
        if !wasAlreadyActive {
            services.schemaProviderRegistry.setLiveScopeProvider(CoordinatorLiveScopeProvider.shared)
            services.schemaProviderRegistry.retain(for: connection.id)
        }
        registerForPersistence()
        SessionRecoveryTracker.sync()
        startPeriodicSave()
        setupPluginDriver()
        startFileWatcherIfNeeded()
        if changeManager.pluginDriver == nil {
            armPostConnectSchemaLoad()
        }
        Self.lifecycleLogger.info(
            "[open] MainContentCoordinator.markActivated done connId=\(self.connection.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    /// Start watching the database file for external changes (SQLite, DuckDB).
    private func startFileWatcherIfNeeded() {
        guard services.pluginManager.connectionMode(for: connection.type) == .fileBased else { return }
        let filePath = connection.database
        guard !filePath.isEmpty else { return }

        let watcher = DatabaseFileWatcher()
        watcher.watch(filePath: filePath, connectionId: connectionId) { [weak self] in
            guard let self else { return }
            if case .loading = services.schemaService.state(for: self.connectionId) { return }
            Task { await self.refreshTables() }
        }
        fileWatcher = watcher
    }

    func showAIChatPanel() {
        inspectorProxy?.showInspector()
        rightPanelState?.activeTab = .aiChat
    }

    /// Set up the plugin driver for query building dispatch on the query builder and change manager.
    internal func setupPluginDriver() {
        guard let driver = services.databaseManager.driver(for: connectionId) else { return }
        let pluginDriver = driver.queryBuildingPluginDriver
        queryBuilder.setPluginDriver(pluginDriver)
        changeManager.pluginDriver = pluginDriver
    }

    func markTeardownScheduled() {
        _teardownScheduled.withLock { $0 = true }
    }

    func clearTeardownScheduled() {
        _teardownScheduled.withLock { $0 = false }
    }

    /// Requests the connection-scoped refresh, which every window of this connection
    /// shares, then applies the window-local follow-up.
    func refreshTables(currentDatabaseOnly: Bool = false) async {
        schemaColumns.removeAll()
        await services.schemaRefreshService.refresh(
            connection: connection,
            database: currentDatabaseOnly ? browseDatabaseName : nil
        )
        pruneStaleSidebarState()
    }

    func refreshRoutines() async {
        try? await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { [services, connectionId] driver in
            _ = await services.schemaService.reloadRoutines(connectionId: connectionId, driver: driver)
        }
    }

    func refreshTriggers() async {
        guard connection.type.supportsDatabaseTriggerBrowse else { return }
        try? await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { [services, connectionId] driver in
            _ = await services.schemaService.reloadTriggers(connectionId: connectionId, driver: driver)
        }
    }

    /// Opens the viewer rather than fetching here. Inspecting an object should not put its source
    /// into an editable query buffer, where the next Cmd+Return runs it, and the viewer refetches
    /// on its own so a restored tab shows the current definition instead of a stale one.
    func showObjectSource(_ objectRef: DatabaseObjectRef) {
        let resolved = objectRef.resolvingDatabase(browseDatabaseName)
        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .objectSource,
            databaseName: resolved.database,
            schemaName: resolved.schema,
            objectRef: resolved,
            tabTitle: QueryTabManager.objectSourceTitle(for: resolved)
        )
        WindowManager.shared.openTab(payload: payload)
    }

    func openObjectSourceInEditor(_ objectRef: DatabaseObjectRef, source: String) {
        let resolved = objectRef.resolvingDatabase(browseDatabaseName)
        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .query,
            databaseName: resolved.database,
            schemaName: resolved.schema,
            initialQuery: source,
            skipAutoExecute: true,
            tabTitle: resolved.displayIdentity
        )
        WindowManager.shared.openTab(payload: payload)
    }

    /// Drop sidebar state for tables that no longer exist. The selection lives in this
    /// window's sidebar, so it is pruned per window.
    internal func pruneStaleSidebarState() {
        guard case .loaded = services.schemaService.state(for: connectionId) else { return }
        let tables = services.schemaService.allLoadedTables(for: connectionId)
        guard let vm = sidebarViewModel else { return }
        let validNames = Set(tables.map(\.name))
        let staleSelections = vm.selectedTables.filter { !validNames.contains($0.table.name) }
        if !staleSelections.isEmpty {
            vm.selectedTables.subtract(staleSelections)
        }
        let stalePendingDeletes = vm.pendingDeletes.filter { !validNames.contains($0.table.name) }
        if !stalePendingDeletes.isEmpty {
            vm.pendingDeletes.subtract(stalePendingDeletes)
            for ref in stalePendingDeletes {
                vm.tableOperationOptions.removeValue(forKey: ref)
            }
        }
        let stalePendingTruncates = vm.pendingTruncates.filter { !validNames.contains($0.table.name) }
        if !stalePendingTruncates.isEmpty {
            vm.pendingTruncates.subtract(stalePendingTruncates)
            for ref in stalePendingTruncates {
                vm.tableOperationOptions.removeValue(forKey: ref)
            }
        }
    }

    /// Explicit cleanup, called when the connection or the window that hosts it goes away, never
    /// from a view's `onDisappear`: a workspace switch unparents a connection's panes, which is a
    /// disappearance the connection is expected to come back from. Releases the schema provider
    /// synchronously on MainActor so we don't depend on deinit + Task scheduling.
    func teardown() {
        let start = Date()
        Self.lifecycleLogger.info(
            "[close] MainContentCoordinator.teardown start connId=\(self.connection.id, privacy: .public) tabs=\(self.tabManager.tabs.count) windowId=\(self.windowId?.uuidString ?? "nil", privacy: .public)"
        )
        _didTeardown.withLock { $0 = true }

        unregisterFromPersistence()
        SessionRecoveryTracker.sync()
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }
        postConnectCancellable = nil
        externalFileModCancellable = nil
        schemaSwitchCancellable = nil
        fileWatcher?.stopWatching(connectionId: connectionId)
        fileWatcher = nil
        currentQueryTask?.cancel()
        currentQueryTask = nil
        /// A cancelled task is not a finished one. `Task.cancel()` is cooperative, so the driver
        /// call may still be running and will throw on the way out; without this the resulting
        /// error reaches the ordinary failure path and reports a query that "failed" when what
        /// actually happened is that the window closed.
        reportEndedExecutions(tabExecution.invalidateAll(reason: .sessionEnded))
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = nil
        for entry in tableLoadTasks.values { entry.task.cancel() }
        tableLoadTasks.removeAll()
        cancelAllRowCountTasks()
        periodicSaveTask?.cancel()
        periodicSaveTask = nil
        draftSaveTask?.cancel()
        draftSaveTask = nil
        redisDatabaseSwitchTask?.cancel()
        redisDatabaseSwitchTask = nil

        dataTabDelegate?.tableViewCoordinator?.releaseData()

        tabSessionRegistry.removeAll()
        /// The delegate a session owns holds closures the mounted view installed, and those capture
        /// the view, which holds this coordinator. Dropping the dictionary is not enough to break
        /// that, so the wiring is released explicitly here as well as at every per-tab drop site.
        for session in structureSessions.values { session.releaseViewWiring() }
        structureSessions.removeAll()
        createTableDrafts.removeAll()
        displayFormatsCache.removeAll()
        displayOrderCache.removeAll()
        displayStateCache.removeAll()
        tableMetadataCache.removeAll()
        schemaColumns.removeAll()
        columnScopeRequeryTask?.cancel()

        tabManager.tabs.removeAll()
        tabManager.selectedTabId = nil

        // Release change manager state — pluginDriver holds a strong reference
        // to the entire database driver which prevents deallocation
        changeManager.clearChanges()
        changeManager.pluginDriver = nil

        tableMetadata = nil

        services.schemaProviderRegistry.release(for: connection.id)
        services.schemaProviderRegistry.purgeUnused()
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
        // during body re-evaluation — @State only keeps the first, rest are discarded.
        // Retain is paired with `markActivated`, so a never-activated coordinator
        // never retained the schema provider and must not release it here.
        guard _didActivate.withLock({ $0 }) else {
            let id = instanceId
            Task { @MainActor in
                Self.activeCoordinators.removeValue(forKey: id)
                SessionRecoveryTracker.sync()
            }
            return
        }

        if !alreadyHandled && !Self.isAppTerminating {
            let logger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")
            logger.warning("teardown() was not called before deallocation for connection \(connectionId)")
        }

        if !alreadyHandled {
            let registry = services.schemaProviderRegistry
            Task { @MainActor in
                registry.release(for: connectionId)
                registry.purgeUnused()
            }
        }
    }

    // MARK: - Initialization Actions

    /// Synchronous toolbar setup — no I/O, safe to call inline
    func initializeToolbar() {
        toolbarState.update(from: connection)

        if let session = services.databaseManager.session(for: connectionId) {
            toolbarState.updateConnectionState(from: session.reportedStatus)
            if let driver = session.driver {
                toolbarState.databaseVersion = driver.serverVersion
            }
        } else if let driver = services.databaseManager.driver(for: connectionId) {
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

    // MARK: - Query Execution

    func runQuery(trigger: TableLoadTrigger = .userInitiated, bypassRowLimit: Bool = false) {
        guard let (tab, index) = tabManager.selectedTabAndIndex else { return }
        guard !tabExecution.isExecuting(tab.id) else {
            traceExecutionBlocked(tabId: tab.id, site: "runQuery")
            return
        }

        if tab.tabType == .table {
            executeTableTabQueryDirectly(trigger: trigger)
            return
        }

        let fullQuery = tab.content.query

        /// The offset says where the SQL sits in the tab's query, so each result can point back at the statement that
        /// produced it. A sort override is SQL the app wrote rather than text the reader can be sent to, so it has
        /// none. The other two hand over untrimmed text with an exact offset and let the scanner do the trimming,
        /// which keeps the two from having to agree about how much whitespace was dropped.
        let sql: String
        let sourceOffset: Int?
        if let sortOverride = tab.pagination.sortExecutionOverride {
            tabManager.mutate(at: index) { $0.pagination.sortExecutionOverride = nil }
            sql = sortOverride
            sourceOffset = nil
        } else if let firstCursor = cursorPositions.first,
                  firstCursor.range.length > 0 {
            // Execute selected text only
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(
                firstCursor.range,
                NSRange(location: 0, length: nsQuery.length)
            )
            sql = nsQuery.substring(with: clampedRange)
            sourceOffset = clampedRange.location
        } else {
            let statement = SQLStatementScanner.locatedStatementAtCursor(
                in: fullQuery,
                cursorPosition: cursorPositions.first?.range.location ?? 0,
                dialect: sqlDialect
            )
            sql = statement.sql
            sourceOffset = statement.offset
        }

        executeResolvedSQL(sql, tabIndex: index, bypassRowLimit: bypassRowLimit, sourceOffset: sourceOffset)
    }

    /// Runs one statement, named by its own text rather than by where the caret happens to be.
    ///
    /// The gutter's run control draws itself from the same scan this executes through, so the control runs the
    /// statement it sits beside even when the caret is somewhere else entirely. It hands over the SQL rather than a
    /// range on purpose: the editor's text and the tab's binding are two strings that can differ for a moment, and a
    /// range resolved against the wrong one truncates silently. Past that it is the ordinary path, so parameters, safe
    /// mode and the execution gate all apply exactly as they do to any other run.
    @discardableResult
    func runStatement(_ sql: String, sourceOffset: Int? = nil) -> Bool {
        guard let (tab, index) = tabManager.selectedTabAndIndex, tab.tabType == .query else { return false }
        guard !tabExecution.isExecuting(tab.id) else {
            traceExecutionBlocked(tabId: tab.id, site: "runStatement")
            return false
        }

        return executeResolvedSQL(sql, tabIndex: index, bypassRowLimit: false, sourceOffset: sourceOffset)
    }

    /// Everything both run paths do once the SQL to run has been decided.
    ///
    /// Shared so that a statement run from the gutter and a statement run from the caret cannot drift apart on
    /// parameter handling, which is the half of this that is easy to forget.
    ///
    /// Returns whether the SQL was actually dispatched. It is not when the statement carries parameters whose panel
    /// has yet to be filled in: that opens the panel and runs nothing, and a caller that advances the caret on the
    /// strength of a run would then be pointing at the wrong statement when the reader presses again.
    @discardableResult
    private func executeResolvedSQL(
        _ sql: String,
        tabIndex index: Int,
        bypassRowLimit: Bool,
        sourceOffset: Int? = nil
    ) -> Bool {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let anchored = { (statements: [SQLStatementScanner.ExecutableStatement]) in
            guard let sourceOffset else { return statements }
            return statements.map { $0.offset(by: sourceOffset) }
        }

        if services.appSettings.editor.queryParametersEnabled {
            let paramStatements = anchored(SQLStatementScanner.executableStatements(in: sql, dialect: sqlDialect))
            guard !paramStatements.isEmpty else { return false }
            let combinedSQL = paramStatements.map(\.sql).joined(separator: "; ")
            let detectedNames = SQLParameterExtractor.extractParameters(from: combinedSQL)

            if !detectedNames.isEmpty {
                let reconciled = detectAndReconcileParameters(
                    sql: combinedSQL,
                    existing: tabManager.tabs[index].content.queryParameters
                )
                tabManager.mutate(at: index) { $0.content.queryParameters = reconciled }

                if !tabManager.tabs[index].content.isParameterPanelVisible {
                    tabManager.mutate(at: index) { $0.content.isParameterPanelVisible = true }
                    return false
                }

                tabManager.tabStructureVersion += 1
                dispatchParameterizedStatements(
                    paramStatements,
                    parameters: reconciled,
                    tabIndex: index,
                    bypassRowLimit: bypassRowLimit
                )
                return true
            }
        }

        let statements = anchored(SQLStatementScanner.executableStatements(in: sql, dialect: sqlDialect))
        guard !statements.isEmpty else { return false }

        tabManager.tabStructureVersion += 1
        dispatchStatements(statements, tabIndex: index, bypassRowLimit: bypassRowLimit)
        return true
    }

    /// Execute table tab query directly.
    /// Table tab queries are always app-generated SELECTs, so they skip dangerous-query
    /// checks but still respect safe mode levels that apply to all queries.
    func executeTableTabQueryDirectly(trigger: TableLoadTrigger = .userInitiated) {
        guard let (tab, index) = tabManager.selectedTabAndIndex else { return }
        TableLoadTracer.shared.stage(.executeRequested, tabId: tab.id)

        let sql = tab.content.query
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            traceNavigationAbandoned(tabId: tab.id, outcome: .emptyQuery)
            return
        }

        let level = safeModeLevel
        if level.appliesToAllQueries && level.requiresConfirmation,
           tab.execution.lastExecutedAt == nil
        {
            guard !isShowingSafeModePrompt else {
                traceNavigationAbandoned(tabId: tab.id, outcome: .safeModePromptAlreadyOpen)
                return
            }
            isShowingSafeModePrompt = true
            Task {
                defer { isShowingSafeModePrompt = false }
                let decision = await ExecutionGateProvider.shared.authorize(
                    OperationRequest(
                        connectionId: connectionId,
                        databaseType: connection.type,
                        sql: sql,
                        kind: .readQuery,
                        caller: .userInterface,
                        capabilities: .interactiveUser,
                        operationDescription: String(localized: "Execute Query")
                    )
                )
                switch decision {
                case .authorized:
                    executeQueryInternal(sql, isAutoLoad: true, trigger: trigger)
                case .denied(let reason):
                    traceNavigationAbandoned(tabId: tab.id, outcome: .safeModeDenied)
                    tabManager.mutate(at: index) { $0.execution.errorMessage = reason }
                }
            }
        } else {
            executeQueryInternal(sql, isAutoLoad: true, trigger: trigger)
        }
    }

    // MARK: - Editor Query Loading

    @discardableResult
    func loadQueryIntoEditor(
        _ query: String,
        databaseName: String? = nil,
        forceNewTab: Bool = false
    ) -> WindowTabOpenDisposition {
        let targetDatabaseName = databaseName ?? browseDatabaseName
        if !forceNewTab,
           let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query,
           databaseName == nil
           || tab.tableContext.resolvedDatabaseName(browsing: browseDatabaseName) == targetDatabaseName {
            tabManager.mutate(at: tabIndex) {
                $0.content.query = query
                $0.hasUserInteraction = true
            }
            return .currentCoordinator
        }

        if !forceNewTab, tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: query, databaseName: targetDatabaseName)
            return .currentCoordinator
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: targetDatabaseName,
            initialQuery: query
        )
        openTabInNewWindow(payload)
        return .focusedElsewhere
    }

    var aiInsertReusesSelectedQueryTab: Bool {
        guard let (tab, _) = tabManager.selectedTabAndIndex, tab.tabType == .query else { return false }
        return tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func insertQueryFromAI(_ query: String) {
        if aiInsertReusesSelectedQueryTab, let (_, tabIndex) = tabManager.selectedTabAndIndex {
            tabManager.mutate(at: tabIndex) { mutTab in
                mutTab.content.query = query
                mutTab.hasUserInteraction = true
            }
        } else if tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: query, databaseName: browseDatabaseName)
        } else {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .query,
                initialQuery: query
            )
            WindowManager.shared.openTab(payload: payload)
        }
    }

    internal func executeQueryInternal(
        _ sql: String,
        isAutoLoad: Bool = false,
        trigger: TableLoadTrigger = .userInitiated,
        bypassRowLimit: Bool = false,
        anchor: StatementAnchor? = nil
    ) {
        guard let (selectedTab, index) = tabManager.selectedTabAndIndex else { return }

        supersedeExecution(for: selectedTab.id)
        let claim = tabExecution.claim(selectedTab.id)

        tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
        let tab = tabManager.tabs[index]

        if services.pluginManager.supportsQueryProgress(for: connection.type) {
            installClickHouseProgressHandler()
        }

        let conn = connection
        let tabId = tabManager.tabs[index].id

        let traceToken = adoptOrBeginExecutionTrace(tabId: tabId)
        traceExecutionStarted(traceToken, epoch: claim.epoch, isAutoLoad: isAutoLoad)

        let rowCap = resolveRowCap(sql: sql, tabType: tab.tabType, bypassLimit: bypassRowLimit)
        let (tableName, isEditable) = resolveTableEditability(tab: tab, sql: sql)

        let needsMetadataFetch: Bool
        if isEditable, let tableName {
            needsMetadataFetch = !isMetadataCached(tabId: tabId, tableName: tableName)
        } else {
            needsMetadataFetch = false
        }
        if let tableName {
            Self.logger.info(
                "[fk] metadata decision table=\(tableName, privacy: .public) isEditable=\(isEditable) needsFetch=\(needsMetadataFetch)"
            )
        }
        guard let scope = scope(for: tab) else {
            guard tabExecution.settle(claim) else { return }
            tabManager.mutate(at: index) { tab in
                tab.execution.errorMessage = String(localized: "Not connected to database")
            }
            return
        }

        let queryTask = Task { [weak self] in
            guard let self else { return }

            if isAutoLoad {
                do {
                    try await services.databaseManager.ensureConnected(conn)
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        traceConnectUnavailable(traceToken)
                        guard tabExecution.settle(claim) else { return }
                        retireQueryTask(for: claim)
                        pendingLoadTrigger = trigger
                    }
                    return
                }
            }

            let schemaTask: Task<FetchedTableSchema, Error>?
            if needsMetadataFetch, let tableName {
                schemaTask = Task { try await QueryExecutor.fetchTableSchema(scope: scope, tableName: tableName) }
            } else {
                schemaTask = nil
            }

            let fetchBeganAt = ContinuousClock.now
            do {
                let fetchResult = try await services.databaseManager.withScopedDriver(
                    scope: scope,
                    route: services.databaseManager.executionRoute(for: scope),
                    cancellation: .cancellableRead
                ) { [queryExecutor] driver in
                    try await queryExecutor.executeQuery(
                        driver: driver,
                        sql: sql,
                        parameters: nil,
                        rowCap: rowCap
                    )
                }
                let fetchEndedAt = ContinuousClock.now

                guard !Task.isCancelled else {
                    schemaTask?.cancel()
                    traceFetchCancelled(traceToken, began: fetchBeganAt, ended: fetchEndedAt)
                    await resetExecutionState(claim: claim, executionTime: fetchResult.executionTime)
                    return
                }

                let inlineMeta = needsMetadataFetch
                    ? QueryExecutor.inlineMetadata(from: fetchResult.resultColumnMeta, columns: fetchResult.columns)
                    : nil

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    traceFetchCompleted(traceToken, began: fetchBeganAt, ended: fetchEndedAt, result: fetchResult)

                    // Every write below belongs to whoever owns the tab now. A superseded result
                    // that cleared the spinner or nilled the task handle would be reporting on a
                    // query that is still running, so the gate comes before all of them. Settling
                    // is that gate: it answers and releases in one step, and it comes before the
                    // cancellation check rather than sharing a guard with it, because a short
                    // circuit there would leave the tab claimed forever and refusing later runs.
                    guard tabExecution.settle(claim) else {
                        traceStaleResultDropped(traceToken)
                        return
                    }
                    retireQueryTask(for: claim)
                    guard !Task.isCancelled else {
                        traceStaleResultDropped(traceToken)
                        return
                    }
                    if services.pluginManager.supportsQueryProgress(for: self.connection.type) {
                        self.clearClickHouseProgress()
                    }
                    toolbarState.lastQueryDuration = fetchResult.executionTime

                    traceApplyingResult(traceToken, tabId: tabId)

                    applyPhase1Result(
                        tabId: tabId,
                        columns: fetchResult.columns,
                        columnTypes: fetchResult.columnTypes,
                        rows: fetchResult.rows,
                        executionTime: fetchResult.executionTime,
                        rowsAffected: fetchResult.rowsAffected,
                        statusMessage: fetchResult.statusMessage,
                        tableName: tableName,
                        isEditable: isEditable,
                        metadata: inlineMeta,
                        hasSchema: false,
                        sql: sql,
                        connection: conn,
                        isTruncated: fetchResult.isTruncated,
                        anchor: anchor
                    )

                    scheduleTraceCompletion(traceToken, outcome: .completed)
                    reportQueryOperation(
                        claim: claim,
                        trigger: trigger,
                        outcome: .succeeded(
                            OperationSummary(
                                rowsReturned: fetchResult.rows.count,
                                rowsAffected: fetchResult.rowsAffected
                            )
                        )
                    )
                }

                if isEditable, let tableName {
                    /// Committing to phase 2 is what makes the total pending, so it is recorded here
                    /// rather than inside `resolveRowCount`. On a first open the metadata arm reaches
                    /// that function only after a Task hop and the schema round trip, and phase 1 has
                    /// already cleared `isLoading` synchronously, so the tab spends the whole fetch
                    /// looking settled with no total: the readout states a row count it is about to
                    /// replace, and `Count Exactly` is offered against a total nobody has yet.
                    tabManager.mutate(tabId: tabId) { $0.pagination.isCountPending = true }
                    launchPhase2(
                        tableName: tableName,
                        tabId: tabId,
                        connectionType: conn.type,
                        needsMetadataFetch: needsMetadataFetch,
                        schemaTask: schemaTask
                    )
                } else if !isEditable || tableName == nil {
                    clearChangesIfCurrent(claim: claim)
                }
            } catch {
                schemaTask?.cancel()
                finishFailedQuery(
                    error,
                    tabId: tabId,
                    sql: sql,
                    connection: conn,
                    claim: claim,
                    isAutoLoad: isAutoLoad,
                    trigger: trigger,
                    traceToken: traceToken
                )
            }
        }
        installQueryTask(queryTask, for: claim)
    }

    /// A nil claim means work that runs against a tab without claiming it, which is Fetch All. It
    /// still owns the handle for as long as it runs; it just cannot be retired by any claim.
    internal func installQueryTask(_ task: Task<Void, Never>, for claim: TabExecutionClaim?) {
        currentQueryTask = task
        currentQueryTaskOwner = claim
    }

    /// Retires the window's Stop handle, but only for the execution that installed it. A completion
    /// that owns its own tab can still be a stranger to the query the window is running, and taking
    /// that one's handle down would leave a live query with nothing to cancel it.
    ///
    /// It no longer reports anything: what the titlebar shows is derived from `tabExecution`, so a
    /// completion that cannot retire the handle can no longer leave the window claiming to be busy.
    internal func retireQueryTask(for claim: TabExecutionClaim?) {
        guard currentQueryTaskOwner == claim else { return }
        currentQueryTask = nil
        currentQueryTaskOwner = nil
    }

    internal func cancelInFlightQueryTask(reach: DriverCancellationReach = .userStop) {
        guard currentQueryTask != nil else { return }
        currentQueryTask?.cancel()
        do {
            try services.databaseManager.cancelRunningQuery(for: connectionId, reach: reach)
        } catch {
            Self.logger.warning("cancelQuery failed: \(error.localizedDescription, privacy: .public)")
        }
        currentQueryTask = nil
        currentQueryTaskOwner = nil
    }

    /// Ends whatever the tab was doing so a new navigation owns it outright. Invalidating before the
    /// new claim is minted is what makes "the user navigated away and no successor ever ran" still
    /// discard the old result, which a counter that only moved on a successful start could not do.
    ///
    /// Removing the entry is also what puts the titlebar back to idle, because the indicator reads
    /// the registry. A retarget need not be followed by a successor, and nothing else would have
    /// lowered a stored flag.
    internal func supersedeExecution(for tabId: UUID) {
        reportEndedExecutions(tabExecution.invalidate(tabId, reason: .supersededNavigation).map { [$0] } ?? [])
        cancelTableLoad(for: tabId)
        cancelRowCountTask(for: tabId)
        cancelInFlightQueryTask(reach: .supersededNavigation)
    }

    /// Reset execution state when a query is cancelled, releasing the tab only if this claim still
    /// owns it. Settling is that gate and it comes first, exactly as `finishFailedQuery` does for
    /// the other way an execution ends early.
    ///
    /// This used to invalidate by tab id, which releases whatever the tab is running now rather
    /// than what this claim started. A cancelled execution unwinding after its successor had
    /// claimed the tab therefore deleted the successor's entry, and the successor's own `settle`
    /// then refused to apply the rows it had just fetched (#2342).
    @MainActor
    internal func resetExecutionState(claim: TabExecutionClaim, executionTime: TimeInterval) {
        guard tabExecution.settle(claim) else { return }
        reportEndedExecutions([
            EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
        ])
        guard currentQueryTaskOwner == claim else { return }
        retireQueryTask(for: claim)
        toolbarState.lastQueryDuration = executionTime
    }

    internal func resolveTableEditability(tab: QueryTab, sql: String) -> (tableName: String?, isEditable: Bool) {
        if tab.tabType != .table, QueryClassifier.isExplainStatement(sql) {
            return (nil, false)
        }
        let usesNoSQLBrowsing = services.pluginManager.editorLanguage(for: connection.type) != .sql
            || (services.databaseManager.driver(for: connectionId) as? PluginDriverAdapter)?
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

    func fetchEnumValues(
        columnInfo: [ColumnInfo],
        tableName: String,
        connectionType: DatabaseType
    ) async -> [String: [String]] {
        var result: [String: [String]] = [:]

        for col in columnInfo {
            if let values = col.allowedValues, !values.isEmpty {
                result[col.name] = values
            }
        }

        if result.isEmpty,
           let scope = selectedTabScope,
           let createSQL = try? await services.databaseManager.withMetadataDriver(scope: scope, { driver in
               try await driver.fetchTableDDL(table: tableName)
           }) {
            for col in columnInfo {
                if let values = QuerySqlParser.parseSQLiteCheckConstraintValues(
                    createSQL: createSQL, columnName: col.name
                ) {
                    result[col.name] = values
                }
            }
        }

        return result
    }

    // MARK: - SQL Parsing

    func extractTableName(from sql: String) -> String? {
        QuerySqlParser.extractTableName(
            from: sql,
            dialect: sqlDialect,
            browseSchema: services.databaseManager.session(for: connectionId)?.browseSchema
        )
    }

    // MARK: - Sorting

    func handleSortStateChanged(_ newState: SortState) {
        guard let (tab, _) = tabManager.selectedTabAndIndex else { return }
        guard newState != tab.sortState else { return }

        let tableRows = tabSessionRegistry.tableRows(for: tab.id)

        if tab.tabType == .query {
            let tabId = tab.id
            let capturedSort = newState
            let hasBoundParameters = tab.pagination.baseQueryParameterValues?.isEmpty == false
            let baseQuery = hasBoundParameters
                ? tab.content.query
                : (tab.pagination.baseQueryForMore ?? tab.content.query)
            let capturedColumns = tableRows.columns
            confirmDiscardChangesIfNeeded(action: .sort) { [weak self] confirmed in
                guard let self, confirmed else { return }
                let orderClause = capturedSort.columns.compactMap { sortCol -> String? in
                    guard sortCol.columnIndex >= 0, sortCol.columnIndex < capturedColumns.count else { return nil }
                    let columnName = capturedColumns[sortCol.columnIndex]
                    let direction = sortCol.direction == .ascending ? "ASC" : "DESC"
                    return "\(self.queryBuilder.quoteIdentifier(columnName)) \(direction)"
                }.joined(separator: ", ")
                let orderQuery = QuerySqlParser.applyingOrderBy(
                    orderClause,
                    to: baseQuery,
                    lexicalDialect: self.sqlDialect
                )
                guard self.tabManager.mutate(tabId: tabId, { tab in
                    tab.sortState = capturedSort
                    tab.hasUserInteraction = true
                    tab.pagination.reset()
                    tab.pagination.resetLoadMore()
                    tab.pagination.sortExecutionOverride = orderQuery
                }) else { return }
                self.runQuery()
            }
            return
        }

        let tabId = tab.id
        let capturedSort = newState
        confirmDiscardChangesIfNeeded(action: .sort) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard self.tabManager.mutate(tabId: tabId, { tab in
                tab.sortState = capturedSort
                tab.hasUserInteraction = true
                tab.pagination.reset()
            }) else { return }
            guard let tabIndex = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
            self.rebuildTableQuery(at: tabIndex)
            self.runQuery()
        }
    }
}
