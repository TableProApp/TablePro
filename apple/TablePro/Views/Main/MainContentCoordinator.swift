//
//  MainContentCoordinator.swift
//  TablePro
//
//  Coordinator managing business logic for MainContentView.
//  Separates view logic from presentation for better maintainability.
//

import Combine
import Foundation
import os
import SwiftUI
import TableProEditorKit
import TableProPluginKit
import TableProSQLGrammar

enum DiscardAction {
    case refresh
    case sort
    case pagination
    case filter
    case resultSwitch
    case navigation
    case displayOrder
    case columnVisibility
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

// Drives one `.sheet(item:)` in MainContentView instead of several `.sheet(isPresented:)`.
enum ActiveSheet: Identifiable {
    case sqlPreview
    case exportDialog
    case importDialog(formatId: String)
    case rowImport(formatId: String)
    // The files are in `importBatch`, each imported into its own table.
    case rowImportBatch
    case exportQueryResults
    // Carries the right-clicked tables: the object browser may point elsewhere by the time the sheet appears.
    case transferTables(tables: Set<String>, schema: String?)
    // Carries the right-clicked databases, not the object browser's current one. Empty means the browse database.
    case backupDatabase(databases: Set<String>)
    case restoreDatabase(fileURL: URL)
    // Carries the object's own scope: the statement names only the table, so the browser's scope could hit a same-named one.
    case maintenance(
        operation: PluginMaintenanceOperation,
        tableName: String,
        database: String?,
        schema: String?
    )
    case createDatabase
    // The right-clicked database, not wherever the object browser points by the time Create is pressed.
    case createSchema(database: String?)
    case editSchema(DatabaseContainerRef)
    // Carries the object's scope so the comment lands on the right-clicked object, not a same-named one the browser points at.
    case editObjectComment(DatabaseObjectTarget)
    case setSequenceNextValue(DatabaseObjectTarget)
    case editSequence(DatabaseObjectTarget)
    // Carries the source database, schema and objects: the object browser may point elsewhere by the time the sheet appears.
    case copyObjects(ObjectCopyLaunchRequest)
    case rewind
    case tableRebuildReview
    // Carries the collection and database so the document is saved where it was read, not where the browser points on Save.
    case documentEditor(DocumentEditorRequest)
    case createUserType(database: String?, schema: String?)
    case searchDatabase(DatabaseSearchSession)
    case joinBuilder(JoinBuilderLaunchRequest)
    case generateRows(RowGenerationSession)

    var id: String {
        switch self {
        case .sqlPreview: "sqlPreview"
        case .exportDialog: "exportDialog"
        case .importDialog(let formatId): "importDialog-\(formatId)"
        case .rowImport(let formatId): "rowImport-\(formatId)"
        case .rowImportBatch: "rowImportBatch"
        case .exportQueryResults: "exportQueryResults"
        case .transferTables(let tables, let schema):
            "transferTables-\(schema ?? "")-\(tables.sorted().joined(separator: ","))"
        case .backupDatabase: "backupDatabase"
        case .restoreDatabase(let fileURL): "restoreDatabase-\(fileURL.path)"
        case .maintenance(let operation, let tableName, let database, let schema):
            "maintenance-\(operation.name)-\(database ?? "")-\(schema ?? "")-\(tableName)"
        case .createDatabase: "createDatabase"
        case .createSchema(let database): "createSchema-\(database ?? "")"
        case .editSchema(let container): "editSchema-\(container.id)"
        case .editObjectComment(let target):
            "editObjectComment-\(target.scope.database)-\(target.scope.schema ?? "")-\(target.name)"
        case .setSequenceNextValue(let target):
            "setSequenceNextValue-\(target.scope.database)-\(target.scope.schema ?? "")-\(target.name)"
        case .editSequence(let target):
            "editSequence-\(target.scope.database)-\(target.scope.schema ?? "")-\(target.name)"
        case .copyObjects(let launch): "copyObjects-\(launch.id)"
        case .rewind: "rewind"
        case .tableRebuildReview: "tableRebuildReview"
        case .documentEditor(let request): "documentEditor-\(request.id.uuidString)"
        case .createUserType(let database, let schema): "createUserType-\(database ?? "")-\(schema ?? "")"
        case .searchDatabase(let session): "searchDatabase-\(session.id.uuidString)"
        case .joinBuilder(let launch): "joinBuilder-\(launch.id.uuidString)"
        case .generateRows(let session): "generateRows-\(session.id.uuidString)"
        }
    }
}

@MainActor
final class MainContentCoordinator: ObservableObject {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator")
    nonisolated static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    // Correlates rapid tab-switch and tab-close log entries.
    static var switchSeq: Int = 0
    static func nextSwitchSeq() -> Int {
        switchSeq += 1
        return switchSeq
    }

    // MARK: - Dependencies

    let services: AppServices
    let connection: DatabaseConnection
    var connectionId: UUID { connection.id }
    var sqlDialect: SqlDialect { SqlDialect.from(databaseTypeId: connection.type.rawValue) }

    var lexicalGrammar: SQLLexicalGrammar {
        SQLLexicalResolver.executionGrammar(for: connection.type, connectionId: connectionId)
    }
    var statementModel: QueryStatementModel { QueryStatementModel.forDatabaseType(connection.type) }
    // Only SQL: `:name` means something else in MongoDB, Elasticsearch (`?q=name:lamp`), Redis (`GET user:name`) and SurrealQL.
    var bindsNamedParameters: Bool { services.pluginManager.editorLanguage(for: connection.type) == .sql }
    var browseDatabaseName: String {
        services.databaseManager.browseDatabaseName(for: connection)
    }
    var newTabDatabaseName: String {
        tabManager.openingDatabase(browsing: browseDatabaseName)
    }
    var safeModeLevel: SafeModeLevel { toolbarState.safeModeLevel }
    // The floor includes Agent mode's; the Safe Mode list offers levels from it and the toolbar tooltip explains it.
    var safeModeStatus: SafeModeStatus {
        SafeModeStatus(level: safeModeLevel, floor: AgentModeSafeModeFloor.effectiveFloor(for: connection))
    }
    func setSafeModeLevel(_ level: SafeModeLevel) {
        services.databaseManager.chooseSafeModeLevel(level, for: connectionId)
        toolbarState.safeModeLevel = services.databaseManager.session(for: connectionId)?.safeModeLevel ?? level
    }
    let selectionSummary = SelectionSummaryState()
    let tabManager: QueryTabManager
    let changeManager: DataChangeManager
    let toolbarState: ConnectionToolbarState
    let tabSessionRegistry: TabSessionRegistry
    let queryExecutor: QueryExecutor
    internal var executionGate: any ExecutionGate = ExecutionGateProvider.shared
    let windowSidebarState: WindowSidebarState

    // MARK: - Services

    @Published internal var queryBuilder: TableQueryBuilder
    let persistence: TabPersistenceCoordinator
    internal lazy var rowOperationsManager: RowOperationsManager = {
        RowOperationsManager(changeManager: changeManager)
    }()

    private(set) var filterCoordinator: FilterCoordinator!
    private(set) var findCoordinator: FindCoordinator!
    private(set) var queryExecutionCoordinator: QueryExecutionCoordinator!
    private(set) var paginationCoordinator: PaginationCoordinator!
    private(set) var rowEditingCoordinator: RowEditingCoordinator!
    private(set) lazy var browseCursorCoordinator = BrowseCursorCoordinator(parent: self)

    // Set by MainContentView on appear.
    @Published var windowId: UUID?

    @Published var favoriteDialogQuery: FavoriteDialogQuery?

    weak var sidebarViewModel: SidebarViewModel?

    weak var structureActions: StructureViewActionHandler?

    // Lets Save Changes (Cmd+S) route to table creation. Set by `CreateTableView` on appear.
    weak var createTableActions: CreateTableActionHandler?

    weak var usersRolesActions: UsersRolesActionHandler?

    // Not in the view: it dies on every tab and Data/Structure switch, and the close gate must see unseen tabs' staged work.
    @Published var structureSessions: [UUID: StructureEditingSession] = [:]
    @Published var createTableDrafts: [UUID: CreateTableDraft] = [:]
    // Kept here for the same reasons as `structureSessions`.
    @Published var userTypeEditors: [UUID: UserTypeEditorModel] = [:]
    // Held here for the same reason: the diagram stages schema edits that Save and the close gate reach.
    @Published var erDiagramModels: [UUID: ERDiagramViewModel] = [:]

    // The cached view model keeps staged work after `usersRolesActions` is nilled; without this a background tab closes silently.
    internal var tabsWithStagedPrincipals: Set<UUID> = []

    // `saveCompletionContinuation` is one slot: a second close gesture would overwrite it and strand the first task forever.
    internal var tabClosesInFlight: Set<UUID> = []

    // The non-data grid that owns the selection, read by the inspector. Set by `TableStructureView` and `CreateTableView`.
    weak var inspectorRowSource: (any InspectorRowSource)?

    // Bumped when a published schema row changes, so the inspector re-reads it.
    @Published var inspectorRowSourceRevision: Int = 0

    // Never builds the view model: a command reveals the assistant first, and revealing is what activates it.
    var aiViewModel: AIChatViewModel? { trailingPaneState?.assistant.viewModelIfActivated }

    weak var trailingPaneState: TrailingPaneState?

    // Moves when a value filter or a display format changes, so views outside the grid re-read the order.
    @Published var gridDisplayRevision: Int = 0

    // Refreshes the inspector JSON without `gridDisplayRevision`'s full rebuild; a subject so observers don't redraw per keystroke.
    let inspectorRowContentChanged = PassthroughSubject<Void, Never>()

    // One grid model per data tab, outliving every mount of its grid.
    var dataGridEntries: [UUID: DataTabGridEntry] = [:]
    // Set while a tab switch still has the outgoing tab's edits in the change manager.
    var tabSwitchOutgoingTabId: UUID?
    private(set) lazy var gridChangeState = AnyChangeManager(changeManager)
    let gridCellsEdited = PassthroughSubject<Void, Never>()

    // One-shot: set on an explicit open (Return, double-click), consumed by the grid to take focus. Never set on selection.
    var pendingGridFocusOnOpen = false

    weak var trailingPaneProxy: TrailingPaneProxy?

    weak var splitViewController: MainSplitViewController?

    // For alerts instead of NSApp.keyWindow, which may return a sheet window and leave dialogs stuck.
    weak var contentWindow: NSWindow?

    // No SwiftUI `Scene` in the AppKit lifecycle, so a focused value can't resolve; this reaches AppKit and SwiftUI callers.
    weak var commandActions: MainContentCommandActions?

    // Owned by the window: the panel anchors on it, and each connection the window hosts would otherwise bring its own.
    var quickSwitcherPanel: QuickSwitcherPanelController? {
        splitViewController?.quickSwitcherPanel
    }

    // MARK: - Published State

    @Published var cursorPositions: [CursorPosition] = []
    @Published var activeSheet: ActiveSheet? {
        didSet { releaseImportFileUnlessImporting() }
    }
    // Commands present through this, not a flag: the toolbar view is gone when its item is in overflow or removed.
    var switcherPresenter: ToolbarSwitcherPresenter? {
        splitViewController?.switcherPresenter
    }
    @Published var sessionContexts: [PluginSessionContext] = []
    @Published var containerDropRequest: DatabaseDropRequest?
    @Published var importFile: ImportFileHandoff?
    @Published var importBatch: ImportBatchFiles.Resolution?
    @Published var exportPreselection: ExportPreselection?
    @Published var exportFormatId: String?
    // Kept after the sheet closes, so reopening Search Database after opening a result shows the results again.
    var databaseSearchSession: DatabaseSearchSession?
    @Published var pendingLoadTrigger: TableLoadTrigger?
    var deferredRestoreLoadTabId: UUID?

    var displayFormatsCache: [UUID: DisplayFormatsCacheEntry] = [:]
    // Published because the inspector rebuilds its snapshot from it (load, comment refetch, rename).
    @Published var tableMetadataCache: [UUID: TableMetadataCacheEntry] = [:]
    // Bumped per Table Info invalidation so an in-flight read can't mark the cache current; per window, as it can precede a tab entry.
    var tableMetadataGeneration = 0
    var displayStateClock = 0

    let schemaColumns = SchemaColumnStore()
    var columnScopeRequeryTask: Task<Void, Never>?

    var openTabInNewWindow: (EditorTabPayload) -> Void = {
        WindowManager.shared.openTab(payload: $0)
    }

    var connectionExists: (UUID) -> Bool = { id in
        ConnectionStorage.shared.loadConnections().contains { $0.id == id }
    }

    var hostedTabRouting = HostedTabRouting.live

    var importFormatLookup = ImportFormatLookup.live

    // Injectable: `AlertHelper.present` goes app-modal with no window, and a unit test host has none, hanging the main thread.
    var presentError: (String, String, NSWindow?) -> Void = { title, message, window in
        AlertHelper.showErrorSheet(title: title, message: message, window: window)
    }

    // MARK: - Internal State

    // Published on purpose: busy state is derived from membership here, and every claim, settle and invalidate is a write.
    @Published internal var tabExecution = TabExecutionRegistry()

    // Keyed by tab: the window hosts several tabs on one connection, and a shared handle made every start a Stop for its holder.
    internal var queryTasks = TabQueryTasks()
    internal var rowCountTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    // Tab id to the user-requested exact count that owns its counting indicator.
    internal var exactCountOwners: [UUID: UUID] = [:]
    internal var tableLoadTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    // Not on `QueryTab`: that is the persisted shape, and staying out of its `Equatable` keeps a push from re-publishing tabs.
    internal var navigationHistories: [UUID: TabNavigationHistory] = [:]
    internal var redisDatabaseSwitchTask: Task<Void, Never>?
    private var periodicSaveTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    internal var postConnectCancellable: AnyCancellable?
    // Owned here, not by the view: a connection switch cancels the view's `task`, and a cancelled first load never reran.
    internal var schemaLoadTask: Task<Void, Never>?
    // A reconnect installs a new driver, and a load on the old one says nothing about the new catalog.
    internal weak var schemaLoadDriver: (any DatabaseDriver)?
    // On the coordinator: a dropped session swaps the view, and restoring twice overwrote the live tabs' changes.
    internal var hasRestoredTabs = false
    // Set once restore ran or was not due. A moved tab waits for it so it merges into and saves with the saved set.
    internal var hasSettledTabRestore = false
    internal var movesAwaitingRestore: [PendingTabMove] = []
    // Counts every appearance, a switch back to this connection included.
    internal private(set) var activationCount = 0
    private var externalFileModCancellable: AnyCancellable?
    internal lazy var sourceFileDiskChangeMonitor = SourceFileDiskChangeMonitor(tabManager: tabManager)
    private var schemaSwitchCancellable: AnyCancellable?
    private var clearedEditsCancellable: AnyCancellable?
    private var gridRepaintCancellable: AnyCancellable?
    private var browseContainerCancellable: AnyCancellable?

    @Published var fileConflictRequest: FileConflictRequest?

    struct FileConflictRequest: Identifiable {
        let id = UUID()
        let tabId: UUID
        let url: URL
        let mineContent: String
        let diskContent: String
    }
    internal private(set) var fileWatcher: DatabaseFileWatcher?

    // Set during handleTabChange to suppress redundant column-change reconfiguration.
    internal var isHandlingTabSwitch = false
    var isUpdatingColumnLayout = false

    // Guards re-entrant confirm dialogs (nested run loop during runModal).
    internal var isShowingConfirmAlert = false

    internal var isShowingSafeModePrompt = false

    @Published internal var rewindPlan: RewindPlan?

    // The rebuild a column drag asked for, held while the user reviews it.
    @Published internal var tableRebuildRequest: TableRebuildReviewRequest?

    // For save-then-close callers. Set before `saveChanges`, resumed by `executeCommitStatements`.
    internal var saveCompletionContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - Window Lifecycle (driven by TabWindowController NSWindowDelegate)

    // Updated by TabWindowController; read by event handlers such as the sidebar table-selection filter.
    var isKeyWindow = false

    // Scheduled in `handleWindowDidResignKey`, fires 5s later.
    var evictionTask: Task<Void, Never>?

    var refreshCoalesceTask: Task<Void, Never>?
    var refreshPendingTrailing = false

    // SwiftUI creates and discards coordinators during body re-evaluation; those never activate and need no teardown warning.
    private let _didActivate = OSAllocatedUnfairLock(initialState: false)

    // Read by deinit to log missed teardowns.
    private let _didTeardown = OSAllocatedUnfairLock(initialState: false)

    // So deinit doesn't warn if SwiftUI deallocates before the delayed teardown Task fires.
    private let _teardownScheduled = OSAllocatedUnfairLock(initialState: false)

    // Views skip persistence during window close teardown.
    var isTearingDown: Bool { _teardownScheduled.withLock { $0 } || _didTeardown.withLock { $0 } }

    // Suppresses the deinit warning: SwiftUI does not call onDisappear during app termination.
    nonisolated private static let _isAppTerminating = OSAllocatedUnfairLock(initialState: false)
    nonisolated static var isAppTerminating: Bool {
        get { _isAppTerminating.withLock { $0 } }
        set { _isAppTerminating.withLock { $0 = newValue } }
    }

    // Registry key: a recycled `ObjectIdentifier` could let a delayed cleanup Task remove another instance's entry.
    let instanceId = UUID()

    // For quit-time persistence. Keyed by `instanceId`, never `ObjectIdentifier`, which can be recycled.
    static var activeCoordinators: [UUID: MainContentCoordinator] = [:]

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

    // Union across windows: saving one window's tabs erased torn-off ones. Deduped, since SwiftUI's throwaway coordinators repeat tabs.
    static func aggregatedTabs(for connectionId: UUID) -> [QueryTab] {
        var seen = Set<UUID>()
        return activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .flatMap { coordinator in
                coordinator.tabManager.tabs.map(coordinator.enrichedForPersistence)
            }
            .filter { seen.insert($0.id).inserted }
    }

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
        // Only with a live caret: a tab whose editor never took focus has no `cursorPositions`, and writing that erased its saved caret.
        if tab.tabType == .query, tab.id == tabManager.selectedTabId,
           let range = cursorPositions.first?.range {
            enriched.restoredCursorOffset = range.location
            enriched.restoredCursorLength = range.length
        }
        // The model keeps the selection; a tab moved to another window carries it in the tab.
        if let store = dataGridEntries[tab.id]?.store {
            enriched.selectionSnapshot = store.selectionSnapshot
        }
        return enriched
    }

    private func columnsForPersistence(of tab: QueryTab) -> [String] {
        let buffer = tabSessionRegistry.tableRows(for: tab.id)
        return buffer.columns.isEmpty ? effectiveResultColumns(for: tab) : buffer.columns
    }

    static func resolveRestoredSortColumns(
        _ persisted: [PersistedSortColumn],
        in columns: [String]
    ) -> [SortColumn] {
        persisted.compactMap { column in
            guard let columnIndex = columns.firstIndex(of: column.columnName) else { return nil }
            return SortColumn(columnIndex: columnIndex, direction: column.direction, columnName: column.columnName)
        }
    }

    // A plain read: the value stays on the tab until the editor reports it consumed, since `body` runs before the text view exists.
    func restoredCursorRange(for tabId: UUID) -> NSRange? {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tabType == .query,
              let offset = tabManager.tabs[index].restoredCursorOffset else { return nil }
        let length = (tabManager.tabs[index].content.query as NSString).length
        let clamped = min(max(0, offset), length)
        let selectionLength = min(tabManager.tabs[index].restoredCursorLength ?? 0, length - clamped)
        return NSRange(location: clamped, length: max(0, selectionLength))
    }

    // Folds live on the tab, not the window, so a tab switch can't carry one tab's folds onto another.
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

    func pendingStatementJump(for tabId: UUID) -> StatementAnchor? {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[index].tabType == .query else { return nil }
        return tabManager.tabs[index].pendingStatementJump
    }

    // Stored, not applied: the editor may not be mounted yet. Cleared on consume, so selecting the same result asks again.
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

    // Typing changes no tab identity, so without this a scratch query lives only in memory until the 30s timer or quit flush.
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

    static func aggregatedSelectedTabId(for connectionId: UUID) -> UUID? {
        activeCoordinators.values
            .first { $0.connectionId == connectionId && $0.tabManager.selectedTabId != nil }?
            .tabManager.selectedTabId
    }

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

    // Called on resign key. The selected tab keeps its rows; `canEvictReloadableTableRows` keeps tabs that can't reload themselves.
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
            pagination: services.pluginManager.paginationCapability(for: connection.type),
            dialectQuote: dialect.map { quoteIdentifierFromDialect($0) }
        )
        self.persistence = TabPersistenceCoordinator.forConnection(connection.id)

        ConnectionDataCache.shared(for: connection.id).ensureLoaded()
        changeManager.undoManagerProvider = { [weak self] in self?.contentWindow?.undoManager }
        changeManager.onUndoApplied = { [weak self] result in self?.handleUndoResult(result) }
        tabManager.onVisibleContainerReconciled = { [weak self] in
            self?.browseCursorCoordinator.followVisibleContainer()
        }
        browseContainerCancellable = services.appEvents.browseContainerChanged
            .filter { [connectionId = connection.id] changed in changed == connectionId }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.browseCursorCoordinator.browseContainerDidChange()
            }
        tabManager.onTabRetargeted = { [weak self] tabId in
            self?.existingGridModel(forTab: tabId)?.discardEditing()
            self?.flushColumnLayoutPersistence()
            self?.supersedeExecution(for: tabId)
            self?.releaseRetargetedTabState(for: tabId)
        }

        // Synchronous: queue .main satisfies assumeIsolated, and the write finishes before exit, unlike Task-based saves.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushColumnLayoutPersistence()
                // First coordinator saves every window's tabs (last-write-wins bug). No isTearingDown check: Cmd+Q marks it before willTerminate.
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
                self.refreshSourceFileDiskChanges()
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
        clearedEditsCancellable = resumeWhenEditsClear()
        gridRepaintCancellable = observeChangeManagerForGridRepaint()

        Self.lifecycleLogger.info(
            "[open] MainContentCoordinator.init done connId=\(connection.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(initStart) * 1_000))"
        )
    }

    func refreshSourceFileDiskChanges() {
        sourceFileDiskChangeMonitor.refresh()
    }

    func markActivated() {
        let start = Date()
        activationCount += 1
        let wasAlreadyActive = _didActivate.withLock { current -> Bool in
            let prior = current
            current = true
            return prior
        }
        // Runs on every appearance, a connection switch included; only the first starts coordinator-lifetime work.
        if !wasAlreadyActive {
            services.schemaProviderRegistry.setLiveScopeProvider(CoordinatorLiveScopeProvider.shared)
            services.schemaProviderRegistry.retain(for: connection.id)
            registerForPersistence()
            // Live coordinators change only here and in `teardown()`, so a switch has nothing new to write.
            SessionRecoveryTracker.sync()
            startPeriodicSave()
            startFileWatcherIfNeeded()
        }
        setupPluginDriver()
        loadSchemaOnActivation()
        Self.lifecycleLogger.info(
            "[open] MainContentCoordinator.markActivated done connId=\(self.connection.id, privacy: .public) firstActivation=\(!wasAlreadyActive) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    private func startFileWatcherIfNeeded() {
        guard fileWatcher == nil,
              services.pluginManager.connectionMode(for: connection.type) == .fileBased else { return }
        let filePath = connection.database
        guard !filePath.isEmpty else { return }

        let watcher = DatabaseFileWatcher()
        watcher.watch(filePath: filePath, connectionId: connectionId) { [weak self] in
            guard let self else { return }
            if case .loading = services.schemaService.state(for: self.connectionId) { return }
            DatabaseTreeMetadataService.shared.markListsStale(connectionId: self.connectionId)
            Task { await self.refreshTables() }
        }
        fileWatcher = watcher
    }

    // Activates lazily so a window that never opens the assistant never reads the conversation history off disk.
    func showAssistant() {
        // Gate first: activating reads the stored conversations, and the pane would refuse to open anyway.
        guard AppSettingsManager.shared.ai.enabled else { return }
        trailingPaneState?.assistant.activate(connection: connection)
        trailingPaneProxy?.showAssistant()
    }

    func showRowAsJSON() {
        trailingPaneState?.inspector.viewMode = .json
        trailingPaneProxy?.showInspector()
    }

    internal func setupPluginDriver() {
        guard let driver = services.databaseManager.driver(for: connectionId) else { return }
        // Both are published: writing the same driver back on every appearance re-evaluates every view that reads them.
        let browseBuilder = driver.queryBuildingPluginDriver
        if !queryBuilder.usesPluginDriver(browseBuilder) {
            queryBuilder.setPluginDriver(browseBuilder)
        }
        let rowWriter = driver.rowWritingPluginDriver
        if rowWriter !== changeManager.pluginDriver {
            changeManager.pluginDriver = rowWriter
        }
    }

    func markTeardownScheduled() {
        _teardownScheduled.withLock { $0 = true }
    }

    func clearTeardownScheduled() {
        _teardownScheduled.withLock { $0 = false }
    }

    // The refresh is connection-scoped and shared by every window; the follow-up is window-local.
    func refreshTables(currentDatabaseOnly: Bool = false) async {
        schemaColumns.removeAll()
        await services.schemaRefreshService.refresh(
            connection: connection,
            database: currentDatabaseOnly ? browseDatabaseName : nil
        )
        pruneStaleSidebarState()
    }

    func refreshRoutines() async {
        let scope = services.databaseManager.browseScope(for: connectionId)
        try? await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { [services, connectionId] driver in
            _ = await services.schemaService.reloadRoutines(connectionId: connectionId, driver: driver, scope: scope)
        }
    }

    func refreshTriggers() async {
        guard connection.type.supportsDatabaseTriggerBrowse else { return }
        let scope = services.databaseManager.browseScope(for: connectionId)
        try? await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { [services, connectionId] driver in
            _ = await services.schemaService.reloadTriggers(connectionId: connectionId, driver: driver, scope: scope)
        }
    }

    func refreshUserDefinedTypes() async {
        guard connection.type.supportsUserDefinedTypeBrowse else { return }
        let scope = services.databaseManager.browseScope(for: connectionId)
        try? await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { [services, connectionId] driver in
            _ = await services.schemaService.reloadUserDefinedTypes(
                connectionId: connectionId,
                driver: driver,
                scope: scope
            )
        }
    }

    // Opens the viewer, not a query buffer: Cmd+Return would run the source, and the viewer refetches the current definition.
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

    // Never from `onDisappear`: a workspace switch unparents panes the connection comes back to. Releases synchronously, not via deinit.
    func teardown() {
        let start = Date()
        Self.lifecycleLogger.info(
            "[close] MainContentCoordinator.teardown start connId=\(self.connection.id, privacy: .public) tabs=\(self.tabManager.tabs.count) windowId=\(self.windowId?.uuidString ?? "nil", privacy: .public)"
        )
        _didTeardown.withLock { $0 = true }

        unregisterFromPersistence()
        dropMovesAwaitingRestore(reason: "coordinator torn down")
        SessionRecoveryTracker.sync()
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }
        postConnectCancellable = nil
        schemaLoadTask?.cancel()
        schemaLoadTask = nil
        externalFileModCancellable = nil
        sourceFileDiskChangeMonitor.cancel()
        schemaSwitchCancellable = nil
        browseContainerCancellable = nil
        fileWatcher?.stopWatching(connectionId: connectionId)
        fileWatcher = nil
        cancelAllQueryTasks()
        // `Task.cancel()` is cooperative: the driver call may still throw and report a failure when the window just closed.
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
        databaseSearchSession?.stop()
        databaseSearchSession = nil

        releaseAllGridModels()

        tabSessionRegistry.removeAll()
        // The session delegate holds view closures that capture this coordinator, so the wiring is released explicitly.
        for session in structureSessions.values { session.releaseViewWiring() }
        structureSessions.removeAll()
        createTableDrafts.removeAll()
        userTypeEditors.removeAll()
        erDiagramModels.removeAll()
        displayFormatsCache.removeAll()
        tableMetadataCache.removeAll()
        schemaColumns.removeAll()
        columnScopeRequeryTask?.cancel()
        releaseImportFile()

        tabManager.tabs.removeAll()
        tabManager.selectedTabId = nil

        // pluginDriver strongly holds the whole database driver, which blocks deallocation.
        changeManager.clearChanges()
        changeManager.pluginDriver = nil

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

        // Never-activated coordinators are SwiftUI throwaways that never retained the schema provider, so must not release it.
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

    // No I/O, safe to call inline.
    func initializeToolbar() {
        toolbarState.update(from: connection)

        if let session = services.databaseManager.session(for: connectionId) {
            toolbarState.updateConnectionState(from: session.reportedStatus)
        }
    }

    // A second window or a remount finds the schema loaded and leaves the shared autocomplete alone.
    func loadSchemaIfNeeded() async {
        loadSchemaOnActivation()
        await schemaLoadTask?.value
    }

    // Legacy, used by the first window.
    func initializeView() async {
        initializeToolbar()
        await loadSchemaIfNeeded()
    }

    // MARK: - Query Execution

    func runQuery(
        viewport: GridReloadIntent, trigger: TableLoadTrigger = .userInitiated,
        bypassRowLimit: Bool = false, extraCapabilities: CallerCapabilities = []
    ) {
        guard let (tab, index) = tabManager.selectedTabAndIndex else { return }
        guard !tabExecution.isExecuting(tab.id) else {
            traceExecutionBlocked(tabId: tab.id, site: "runQuery")
            return
        }
        commitActiveGridEdit()

        if tab.tabType == .table {
            executeTableTabQueryDirectly(trigger: trigger, viewport: viewport)
            return
        }

        // The offset lets each result point back at its statement. Both paths pass untrimmed text and let the scanner trim.
        let target = selectionOrStatementAtCursor(in: tab.content.query)
        executeResolvedSQL(
            target.sql, tabIndex: index, bypassRowLimit: bypassRowLimit,
            sourceOffset: target.offset, extraCapabilities: extraCapabilities
        )
    }

    // Takes SQL, not a range: the editor text and the tab binding can briefly differ, and a range on the wrong one truncates silently.
    @discardableResult
    func runStatement(_ sql: String, sourceOffset: Int? = nil) -> Bool {
        guard let (tab, index) = tabManager.selectedTabAndIndex, tab.tabType == .query else { return false }
        guard !tabExecution.isExecuting(tab.id) else {
            traceExecutionBlocked(tabId: tab.id, site: "runStatement")
            return false
        }
        commitActiveGridEdit()

        return executeResolvedSQL(sql, tabIndex: index, bypassRowLimit: false, sourceOffset: sourceOffset)
    }

    // Returns false when a parameter panel opens instead, so callers don't advance the caret on a run that didn't happen.
    @discardableResult
    private func executeResolvedSQL(
        _ sql: String,
        tabIndex index: Int,
        bypassRowLimit: Bool,
        sourceOffset: Int? = nil,
        extraCapabilities: CallerCapabilities = []
    ) -> Bool {
        let batches = queryExecutionCoordinator.executionBatches(in: sql, sourceOffset: sourceOffset ?? 0)
        let statements = batches.flatMap(\.statements)
        guard !statements.isEmpty else { return false }

        if services.appSettings.editor.queryParametersEnabled, bindsNamedParameters {
            let combinedSQL = SQLParameterExtractor.parameterSource(of: statements)
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
                dispatchParameterizedBatches(
                    batches,
                    parameters: reconciled,
                    tabIndex: index,
                    bypassRowLimit: bypassRowLimit,
                    extraCapabilities: extraCapabilities
                )
                return true
            }
        }

        tabManager.tabStructureVersion += 1
        dispatchBatches(batches, tabIndex: index, bypassRowLimit: bypassRowLimit, extraCapabilities: extraCapabilities)
        return true
    }

    // App-built SELECTs skip dangerous-query checks but keep safe mode. Returns the confirmation task when Safe Mode asks first.
    @discardableResult
    func executeTableTabQueryDirectly(
        trigger: TableLoadTrigger = .userInitiated,
        viewport: GridReloadIntent
    ) -> Task<Void, Never>? {
        guard let tab = tabManager.selectedTab else { return nil }
        TableLoadTracer.shared.stage(.executeRequested, tabId: tab.id)

        let sql = tab.content.query
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            traceNavigationAbandoned(tabId: tab.id, outcome: .emptyQuery)
            return nil
        }

        let level = safeModeLevel
        if level.appliesToAllQueries && level.requiresConfirmation,
           tab.execution.lastExecutedAt == nil
        {
            guard !isShowingSafeModePrompt else {
                traceNavigationAbandoned(tabId: tab.id, outcome: .safeModePromptAlreadyOpen)
                return nil
            }
            isShowingSafeModePrompt = true
            let tabId = tab.id
            let askedContext = tab.tableContext
            return Task {
                let decision = await executionGate.authorize(
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
                isShowingSafeModePrompt = false
                // Only on the tab and table the sheet showed: elsewhere it put these rows under another name; SQL alone misses a Redis db switch.
                let asked = tabManager.tabs.first(where: { $0.id == tabId })
                guard tabManager.selectedTabId == tabId,
                      let asked,
                      asked.content.query == sql,
                      asked.tableContext.tableName == askedContext.tableName,
                      asked.tableContext.databaseName == askedContext.databaseName else {
                    traceNavigationAbandoned(tabId: tabId, outcome: .superseded)
                    if tabManager.selectedTabId != tabId {
                        declineTableLoad(for: tabId)
                    }
                    lazyLoadCurrentTabIfNeeded(trigger: trigger)
                    return
                }
                switch decision {
                case .authorized:
                    executeQueryInternal(sql, isAutoLoad: true, trigger: trigger, viewport: viewport, source: .sameSource)
                case .denied(let reason, _):
                    traceNavigationAbandoned(tabId: tabId, outcome: .safeModeDenied)
                    queryExecutionCoordinator.presentTabFailure(reason, announcing: reason, onTab: tabId)
                }
            }
        }
        executeQueryInternal(sql, isAutoLoad: true, trigger: trigger, viewport: viewport, source: .sameSource)
        return nil
    }

    // MARK: - Editor Query Loading

    @discardableResult
    func loadQueryIntoEditor(
        _ query: String,
        databaseName: String? = nil,
        forceNewTab: Bool = false
    ) -> WindowTabOpenDisposition {
        let targetDatabaseName = databaseName ?? newTabDatabaseName
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
            tabManager.addTab(initialQuery: query, databaseName: newTabDatabaseName)
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
        anchor: StatementAnchor? = nil,
        viewport: GridReloadIntent = .firstRow,
        source: ResultSourceChange = .newSource
    ) {
        guard let (selectedTab, index) = tabManager.selectedTabAndIndex else { return }

        let (claim, lease) = beginTabExecution(for: selectedTab.id)

        tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
        let tab = tabManager.tabs[index]

        let conn = connection
        let tabId = tabManager.tabs[index].id

        let traceToken = adoptOrBeginExecutionTrace(tabId: tabId)
        traceExecutionStarted(traceToken, epoch: claim.epoch, isAutoLoad: isAutoLoad)

        let statement = resolveStatement(sql: sql, tabType: tab.tabType, bypassLimit: bypassRowLimit)
        let rowCap = statement.rowCap
        let (tableName, isEditable) = resolveTableEditability(tab: tab, sql: sql)

        let needsDefinition = tabSessionRegistry.needsDefinition(tabId)
        let needsMetadataFetch = tableName.map { isEditable && !isMetadataCached(tabId: tabId, tableName: $0) } ?? false
        // Captured now, while the result this decision was made against is still the active one.
        let cachedMetadata: ParsedSchemaMetadata? = needsMetadataFetch ? nil : ParsedSchemaMetadata.cached(
            rows: tabSessionRegistry.tableRows(for: tabId),
            primaryKeyColumns: tabManager.tabs[index].tableContext.primaryKeyColumns
        )
        if let tableName {
            Self.logger.info(
                "[fk] metadata decision table=\(tableName, privacy: .private(mask: .hash)) isEditable=\(isEditable) needsFetch=\(needsMetadataFetch)"
            )
        }
        guard let scope = scope(for: tab) else {
            guard tabExecution.settle(claim) else { return }
            tabManager.mutate(at: index) { tab in
                tab.execution.errorMessage = String(localized: "Not connected to database")
                tab.pagination.isLoading = false
            }
            return
        }
        let isTableTab = tab.tabType == .table
        let (grammar, lengthColumns) = (lexicalGrammar, unloadedValueLengthColumns(for: tab))

        let failureOutput = ServerOutputBox()
        let queryTask = Task { [weak self] in
            guard let self else { return }

            if isAutoLoad, await !connectBeforeAutoLoad(conn, claim: claim, trigger: trigger, traceToken: traceToken) {
                return
            }

            if let tableName, !tableName.isEmpty { prefetchForeignKeys(scope: scope) }
            let schemaTask = QueryExecutor.schemaFetch(tableName: needsMetadataFetch ? tableName : nil, scope: scope)

            let fetchBeganAt = ContinuousClock.now
            do {
                let (fetchResult, tableEdits) = try await withExecutionDriver(
                    scope: scope,
                    isTableTab: isTableTab,
                    lease: lease
                ) { [queryExecutor] driver in
                    let fetched = try await queryExecutor.executeQuery(
                        driver: driver,
                        sql: statement.sql,
                        parameters: nil,
                        rowCap: rowCap,
                        capturingOutputInto: isTableTab ? nil : failureOutput
                    )
                    let edits = isAutoLoad ? nil : await SucceededStatements.single(
                        statement.sql, scope: scope, databaseType: conn.type, grammar: grammar, ranOn: driver
                    )
                    return (fetched.foldingUnloadedValues(lengthColumns: lengthColumns), edits)
                }
                let fetchEndedAt = ContinuousClock.now
                if !isAutoLoad { Self.postStatementRan(statement.sql, on: conn, succeeded: tableEdits) }

                guard !Task.isCancelled else {
                    schemaTask?.cancel()
                    traceFetchCancelled(traceToken, began: fetchBeganAt, ended: fetchEndedAt)
                    await resetExecutionState(claim: claim, executionTime: fetchResult.executionTime)
                    return
                }

                let inlineMeta = needsMetadataFetch
                    ? QueryExecutor.inlineMetadata(from: fetchResult.resultColumnMeta, columns: fetchResult.columns)
                    : nil
                // Rows and definition commit together after a definition change, so new columns never sit under old keys or defaults.
                let definition = needsDefinition ? try? await schemaTask?.value : nil

                let applied = await MainActor.run { [weak self] () -> Bool in
                    guard let self else { return false }
                    traceFetchCompleted(traceToken, began: fetchBeganAt, ended: fetchEndedAt, result: fetchResult)

                    // Settle first: it gates every write below, and sharing a guard with the cancel check would leave the tab claimed forever.
                    guard tabExecution.settle(claim) else {
                        traceStaleResultDropped(traceToken)
                        return false
                    }
                    retireQueryTask(.claim(claim))
                    guard !Task.isCancelled, rereadStillApplies(source) else {
                        traceStaleResultDropped(traceToken)
                        return false
                    }
                    toolbarState.recordQueryTiming(fetchResult.resolvedTiming, for: tabId)

                    traceApplyingResult(traceToken, tabId: tabId)

                    let definitionMetadata = adoptLoadedDefinition(definition, of: tableName, in: scope, readBy: claim)
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
                        metadata: definitionMetadata ?? inlineMeta ?? cachedMetadata,
                        hasSchema: definitionMetadata != nil,
                        read: TableFreshness.Read(startedAt: claim.startedAt, includesDefinition: definitionMetadata != nil),
                        sql: sql,
                        connection: conn,
                        isTruncated: fetchResult.isTruncated,
                        anchor: anchor,
                        timing: fetchResult.resolvedTiming,
                        viewport: viewport,
                        source: source,
                        serverOutput: fetchResult.serverOutput,
                        rowLocators: isTableTab ? fetchResult.rowLocators : nil,
                        absentCells: fetchResult.absentCells,
                        unloadedCells: fetchResult.unloadedCells
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
                    return true
                }
                // Phase 2 writes onto whatever the tab holds, so only the execution that applied its rows may start it.
                guard applied else {
                    schemaTask?.cancel()
                    return
                }

                if isEditable, let tableName {
                    // Marked pending here: phase 1 clears `isLoading` first, so without it the tab looks settled and offers Count Exactly early.
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
                if !isAutoLoad { Self.postStatementRan(statement.sql, on: conn) }
                finishFailedQuery(
                    error,
                    tabId: tabId,
                    sql: sql,
                    connection: conn,
                    claim: claim,
                    isAutoLoad: isAutoLoad,
                    trigger: trigger,
                    traceToken: traceToken,
                    serverOutput: failureOutput.output
                )
            }
        }
        installQueryTask(queryTask, owner: .claim(claim), lease: lease)
    }

    internal func resolveTableEditability(tab: QueryTab, sql: String) -> (tableName: String?, isEditable: Bool) {
        if tab.tabType != .table, QueryClassifier.isExplainStatement(sql) {
            return (nil, false)
        }
        let editorLanguage = services.pluginManager.editorLanguage(for: connection.type)
        let pluginBuildsBrowse = (services.databaseManager.driver(for: connectionId) as? PluginDriverAdapter)?
            .queryBuildingPluginDriver != nil
        // Plugin-built browse or non-SQL: no table from query text; a tab's stored name or a pipeline `_id` can name another collection.
        let usesNoSQLBrowsing = editorLanguage != .sql || pluginBuildsBrowse
        if tab.tabType != .table, usesNoSQLBrowsing {
            return (nil, false)
        }
        if usesNoSQLBrowsing {
            let name = tab.tableContext.tableName
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
               try await driver.fetchTableDDL(table: tableName, schema: scope.schema)
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
            readings: connection.type.lexicalReadings,
            browseSchema: services.databaseManager.session(for: connectionId)?.browseSchema
        )
    }

    // MARK: - Sorting

    func handleSortStateChanged(_ newState: SortState) {
        guard let (tab, _) = tabManager.selectedTabAndIndex else { return }
        guard newState != tab.sortState else { return }

        if tab.tabType == .query {
            sortQueryResult(by: newState, tabId: tab.id)
            return
        }

        guard supportsColumnSort else { return }
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
            self.runQuery(viewport: .firstRow)
        }
    }
}
