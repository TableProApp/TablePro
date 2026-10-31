//
//  StructureEditingSession.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

// One table tab's structure: what was read, what is staged, and the commands that act on it. The coordinator
// holds it by tab id, so staged edits, the close prompt and Save work with no view mounted.
@MainActor
internal final class StructureEditingSession: ObservableObject {
    static let logger = Logger(subsystem: "com.TablePro", category: "StructureEditingSession")

    internal let identity: String

    internal let connection: DatabaseConnection
    internal let databaseName: String
    internal let schemaName: String?
    internal let isSessionBound: Bool
    internal let tableName: String

    internal let objectKind: TableInfo.TableType

    internal let changeManager = StructureChangeManager()
    internal let editor: StructureDefinitionEditor

    internal var scope: DatabaseScope {
        DatabaseScope(
            connectionId: connection.id, database: databaseName, schema: schemaName, isSessionBound: isSessionBound
        )
    }

    @Published internal var columns: [ColumnInfo] = []
    @Published internal var indexes: [IndexInfo] = []
    @Published internal var foreignKeys: [ForeignKeyInfo] = []
    @Published internal var checkConstraints: [CheckConstraintInfo] = []
    @Published internal var triggers: [TriggerInfo] = []
    @Published internal var ddlStatement: String = ""
    @Published internal var loadState = StructureLoadState()

    @Published internal var concurrentRefresh: MetadataLoadState<PluginConcurrentRefreshAvailability?> = .idle
    private var concurrentRefreshRequest = 0

    @Published internal private(set) var tableComment: MetadataLoadState<String?> = .idle

    internal var loadedTableComment: String? { tableComment.value ?? nil }

    @Published internal private(set) var tableOptions: MetadataLoadState<TableOptions?> = .idle

    internal var loadedTableOptions: TableOptions? { tableOptions.value ?? nil }

    // Leaves `.confirmed` when a save writes the counter and returns only on a read that lands, since the server may raise it.
    @Published internal private(set) var autoIncrementRead: AutoIncrementReadState = .confirmed

    @Published internal private(set) var tableOptionsCatalog: MetadataLoadState<TableOptionsCatalog?> = .idle
    internal var tableOptionsCatalogRead: Task<Void, Never>?

    @Published internal var pane: StructurePane = .definition
    @Published internal var partsReloadToken = 0

    @Published internal var serverSupport = StructureServerSupport.unrestricted {
        didSet {
            editor.serverSupport = serverSupport
            if !availablePanes.contains(pane) {
                pane = .definition
            }
        }
    }

    internal var availablePanes: [StructurePane] {
        StructurePane.allCases.filter { pane in
            switch pane {
            case .definition, .ddl: true
            case .triggers: connection.type.supportsTriggers
            case .parts: connection.type == .clickhouse
            }
        }
    }

    @Published internal var hasLoaded = false
    @Published internal var hasBaseline = false
    // The ER diagram's sessions watch this to learn a save landed.
    @Published internal private(set) var appliedVersion = 0
    @Published internal var isApplying = false
    @Published internal var lastAppliedAt: Date?

    internal var isReloadingAfterSave = false

    weak var coordinator: MainContentCoordinator? {
        didSet { editor.coordinator = coordinator }
    }

    internal var executionGate: any ExecutionGate = ExecutionGateProvider.shared

    private var cancellables: Set<AnyCancellable> = []

    internal init(
        identity: String,
        connection: DatabaseConnection,
        databaseName: String,
        schemaName: String?,
        isSessionBound: Bool = false,
        tableName: String,
        objectKind: TableInfo.TableType = .table,
        serverSupport: StructureServerSupport = .unrestricted
    ) {
        self.identity = identity
        self.connection = connection
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.isSessionBound = isSessionBound
        self.tableName = tableName
        self.objectKind = objectKind
        editor = StructureDefinitionEditor(
            manager: changeManager,
            context: .existingTable(
                connection: connection,
                databaseName: databaseName,
                schemaName: schemaName,
                tableName: tableName,
                objectKind: objectKind,
                isSessionBound: isSessionBound
            )
        )
        self.serverSupport = serverSupport
        editor.serverSupport = serverSupport
        // Nothing is editable before the table's definitions are read.
        editor.isAwaitingBaseline = true
        editor.characterSetContextProvider = { [weak self] in
            ColumnCharacterSetMenus.Context(
                catalog: self?.tableOptionsCatalog ?? .idle,
                tableCharacterSet: self?.changeManager.tableOptions.current?.characterSet
            )
        }
        editor.characterSetCatalogReader = { [weak self] in
            guard let self else { return }
            switch tableOptionsCatalog {
            case .idle, .failed:
                Task { await self.readTableOptionsCatalog() }
            case .loading, .loaded:
                break
            }
        }
        editor.moveColumnHandler = { [weak self] from, to in
            self?.beginColumnReorder(fromIndex: from, toIndex: to)
        }
        changeManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        $tableOptionsCatalog
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.editor.refresh() }
            .store(in: &cancellables)
    }

    // A tab's session reads the table again at once; a diagram's has no view to show it and is dropped instead.
    internal func markApplied() {
        appliedVersion += 1
        guard coordinator != nil else { return }
        editor.isAwaitingBaseline = true
        Task { await refreshAfterApply() }
    }

    // MARK: - Staleness

    internal private(set) var owesRefetch = false

    internal func markStructureStale() {
        guard !changeManager.hasChanges else {
            owesRefetch = true
            return
        }
        markEveryTabStale()
        hasLoaded = false
    }

    @discardableResult
    internal func settleOwedRefetch() -> Bool {
        guard owesRefetch, !changeManager.hasChanges else { return false }
        markStructureStale()
        return true
    }

    internal func markEveryTabStale() {
        loadState.markAllStale()
        owesRefetch = false
    }

    // MARK: - Table comment and options

    internal func beginTableCommentLoad() {
        tableComment = tableComment.enteringLoad
    }

    internal func adoptWrittenTableComment(from changes: [SchemaChange]) {
        for case .modifyTableComment(_, let new) in changes {
            tableComment = .loaded(new)
        }
    }

    internal func settleTableComment(_ outcome: MetadataFetchOutcome<String?>) {
        tableComment = tableComment.settled(by: outcome, discardingValue: false)
    }

    internal func beginTableOptionsLoad() {
        tableOptions = tableOptions.enteringLoad
        if autoIncrementRead == .unconfirmed {
            autoIncrementRead = .rereading
        }
    }

    internal func adoptWrittenTableOptions(from changes: [SchemaChange]) {
        for change in changes {
            switch change {
            case .modifyTableCharacterSet(_, let written):
                guard let loaded = loadedTableOptions else { continue }
                tableOptions = .loaded(loaded.adoptingCharacterSet(of: written))
            case .modifyAutoIncrement:
                autoIncrementRead = .rereading
            default:
                continue
            }
        }
    }

    internal func settleTableOptions(_ outcome: MetadataFetchOutcome<TableOptions?>) {
        tableOptions = tableOptions.settled(by: outcome, discardingValue: false)
        if outcome.didFetch {
            autoIncrementRead = .confirmed
        } else if autoIncrementRead == .rereading {
            autoIncrementRead = .unconfirmed
        }
    }

    internal func beginTableOptionsCatalogLoad() {
        tableOptionsCatalog = tableOptionsCatalog.enteringLoad
    }

    internal func settleTableOptionsCatalog(_ outcome: MetadataFetchOutcome<TableOptionsCatalog?>) {
        tableOptionsCatalog = tableOptionsCatalog.settled(by: outcome, discardingValue: false)
    }

    internal func reloadConcurrentRefreshAvailability(
        provider: any ScopedMetadataProviding = DatabaseManager.shared
    ) async {
        guard objectKind == .materializedView else { return }
        concurrentRefreshRequest += 1
        let request = concurrentRefreshRequest
        concurrentRefresh = concurrentRefresh.enteringLoad
        let loader = TableStructureLoader(scope: scope, tableName: tableName, provider: provider)
        let outcome: MetadataFetchOutcome<PluginConcurrentRefreshAvailability?>
        do {
            outcome = .fetched(try await loader.concurrentRefreshAvailability())
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            Self.logger.error(
                "Concurrent refresh check failed: \(error.publicLogShape, privacy: .public)"
            )
            outcome = .failed(error.localizedDescription)
        }
        guard request == concurrentRefreshRequest else { return }
        concurrentRefresh = concurrentRefresh.settled(by: outcome, discardingValue: true)
    }

    // Called wherever a session is dropped, never from `onDisappear`.
    internal func releaseViewWiring() {
        coordinator = nil
    }
}

internal enum AutoIncrementReadState: Equatable {
    case confirmed
    case rereading
    // The re-read failed or was cancelled, so the loaded counter may be one the server has moved past.
    case unconfirmed
}

extension StructureEditingSession: ActiveGridModelProviding {
    // The section that holds the selection while the Definition page is on screen; the other panes draw no grid.
    var activeGridModel: DataGridModel? {
        guard pane == .definition else { return nil }
        return editor.focusedModel ?? editor.adapter(for: .columns).model
    }
}
