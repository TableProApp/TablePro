//
//  StructureEditingSession.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

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

    // Owned here, not by the view, so the grid the user types into and the edits the close prompt
    // reports are one object, and its model outlives every remount.
    internal let gridAdapter: StructureGridAdapter

    internal var gridModel: DataGridModel { gridAdapter.model }

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
    @Published internal var tabData = StructureTabDataState()

    @Published internal var concurrentRefresh: MetadataLoadState<PluginConcurrentRefreshAvailability?> = .idle
    private var concurrentRefreshRequest = 0

    @Published internal private(set) var tableComment: MetadataLoadState<String?> = .idle

    internal var loadedTableComment: String? { tableComment.value ?? nil }

    @Published internal private(set) var tableOptions: MetadataLoadState<TableOptions?> = .idle

    internal var loadedTableOptions: TableOptions? { tableOptions.value ?? nil }

    /// Leaves `.confirmed` when a save writes the counter and returns only on a read that lands, since the server may raise it.
    @Published internal private(set) var autoIncrementRead: AutoIncrementReadState = .confirmed

    @Published internal private(set) var tableOptionsCatalog: MetadataLoadState<TableOptionsCatalog?> = .idle
    internal var tableOptionsCatalogRead: Task<Void, Never>?

    @Published internal var selectedTab: StructureTab = .columns
    @Published internal var searchText = ""
    @Published internal var sortState = SortState()
    @Published internal var sortDescriptor: StructureSortDescriptor?
    @Published internal var columnLayouts: [StructureTab: ColumnLayoutState] = [:]

    @Published internal var serverSupport = StructureServerSupport.unrestricted {
        didSet {
            guard !availableTabs.contains(selectedTab) else { return }
            selectedTab = .columns
        }
    }

    internal var availableTabs: [StructureTab] {
        StructureTabAvailability.tabs(
            for: connection.type,
            serverSupport: serverSupport,
            offersTableOptions: offersTableOptionsTab
        )
    }

    internal var tabsFetchedOnMount: [StructureTab] {
        var tabs: [StructureTab] = [.columns, .indexes, .foreignKeys]
        if availableTabs.contains(.checkConstraints) {
            tabs.append(.checkConstraints)
        }
        if !tabs.contains(selectedTab) {
            tabs.append(selectedTab)
        }
        return tabs
    }

    @Published internal var footer = StructureFooterCapability()

    @Published internal var hasLoaded = false

    @Published internal private(set) var appliedVersion = 0

    @Published internal var isApplying = false

    @Published internal var lastAppliedAt: Date?

    internal var executionGate: any ExecutionGate = ExecutionGateProvider.shared

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
        self.serverSupport = serverSupport
        gridAdapter = StructureGridAdapter(
            structureChangeManager: changeManager,
            connection: connection,
            tableName: tableName,
            databaseName: databaseName,
            schemaName: schemaName,
            objectKind: objectKind,
            isSessionBound: isSessionBound
        )
        gridAdapter.session = self
        gridAdapter.store.session = self
    }

    internal func markApplied() {
        appliedVersion += 1
    }

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
        tabData.markAllStale()
        owesRefetch = false
    }

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

    // The mounted view installs closures that capture it, and it holds this session; called wherever a
    // session is dropped, never from `onDisappear`.
    internal func releaseViewWiring() {
        gridAdapter.releaseViewWiring()
    }
}

internal enum AutoIncrementReadState: Equatable {
    case confirmed
    case rereading
    /// The re-read failed or was cancelled, so the loaded counter may be one the server has moved past.
    case unconfirmed
}

extension StructureEditingSession: ActiveGridModelProviding {
    // The schema grid while a sub-tab shows one; Parts, Triggers and Options draw views of their own.
    var activeGridModel: DataGridModel? {
        switch selectedTab {
        case .columns, .indexes, .foreignKeys, .checkConstraints:
            return gridModel
        case .ddl, .parts, .triggers, .options:
            return nil
        }
    }
}

internal struct StructureFooterCapability: Equatable {
    internal var canAdd = false
    internal var canRemove = false
    internal var addLabel = ""
    internal var removeLabel = ""

    internal var unavailableReason: String?

    internal var isActive: Bool {
        !addLabel.isEmpty
    }
}
