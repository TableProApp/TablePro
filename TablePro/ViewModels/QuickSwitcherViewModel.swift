//
//  QuickSwitcherViewModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

internal enum QuickSwitcherRanking {
    static let maxResults = 200
    static let recentLimit = 10
    static let localHistoryLimit = 50
    static let subtitleMatchPenalty = 0.6
    static let keywordMatchWeight = 1.0
    static let frecencyBoost = 0.5
    static let openTabBoost = 1.2
    static let containerMatchWeight = 0.5
    static let otherSchemaWeight = 0.97
}

@MainActor
internal final class QuickSwitcherViewModel: ObservableObject {
    struct CrossConnectionCatalogVersion: Hashable {
        struct Entry: Hashable {
            let connectionId: UUID
            let browseScope: DatabaseScope
            let loadedScope: DatabaseScope?
            let schemaGeneration: Int
            let isRefreshing: Bool
        }

        let connectionStatusVersion: Int
        let entries: [Entry]
    }

    /// Deliberately not keyed on `connectionStatusVersion`: that counter bumps on every write to
    /// `activeSessions`, including activity timestamps, so keying on it re-read every favorite and
    /// history row while the panel sat open. The connected set and the content revision are what
    /// this list actually depends on.
    struct CrossConnectionQueryVersion: Hashable {
        let connectedConnectionIds: [UUID]
        let contentRevision: Int
    }

    struct Group: Identifiable, Sendable {
        let id: String
        let header: String?
        let items: [QuickSwitcherItem]
    }

    /// What the panel's own connection is browsing, which is what its table rows are built for.
    struct TableSource {
        let database: String?
        let connectionSwitchesDatabases: Bool
        let browseSchema: String?
        let openTables: Set<QuickSwitcherOpenTable>
        let grouping: GroupingStrategy

        var listsTablesPerSchema: Bool {
            DatabaseTreeMetadataService.listsTablesPerSchema(grouping)
        }
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "QuickSwitcherViewModel")
    private static let filterDebounceNanoseconds: UInt64 = 40_000_000

    private let services: AppServices
    private let connectionId: UUID
    private let defaults: UserDefaults
    private let frecencyStore: QuickSwitcherFrecencyStore
    private let catalogStore: QuickSwitcherCatalogStore

    /// The catalog arriving is what ends the load, so this owns `isLoading` rather than the one
    /// call site that happened to fetch it. A load that is superseded or cancelled after it has
    /// already delivered its items cannot then strand the panel on a spinner.
    internal var allItems: [QuickSwitcherItem] = [] {
        didSet {
            isLoading = false
            scheduleFilter(debounced: false)
        }
    }
    internal var crossConnectionItems: [QuickSwitcherItem] = [] {
        didSet { scheduleFilter(debounced: false) }
    }
    internal var crossConnectionQueryItems: [QuickSwitcherItem] = [] {
        didSet { scheduleFilter(debounced: false) }
    }
    private var baseItems: [QuickSwitcherItem]?
    private var tableItems: [QuickSwitcherItem] = []
    private var tableSource: TableSource?
    private var tableSourceObservations: [AnyCancellable] = []
    private var listingDemand = AllSchemaTablesDemand()
    private var filterTask: Task<Void, Never>?
    private var selectionQuery: String?
    private var selectionScope: QuickSwitcherScope?
    private var activeLoadId = UUID()
    private var activeCrossConnectionLoadId = UUID()
    private var activeCrossConnectionQueryLoadId = UUID()
    private var loadedCrossConnectionVersion: CrossConnectionCatalogVersion?
    private var loadedCrossConnectionQueryVersion: CrossConnectionQueryVersion?

    @Published private(set) var groups: [Group] = []
    @Published private(set) var isLoading = true
    /// Ranking the scoped catalog runs off the main actor behind a debounce, so `groups` is empty
    /// for a beat after the catalog arrives. Without this the panel calls that emptiness "no
    /// results" and says so, for the whole first sort.
    @Published private(set) var isFiltering = false
    /// The tables of schemas other than the browsed one arrive after the rest of the catalog, so a
    /// search that finds nothing yet is still loading rather than a miss.
    @Published private(set) var isLoadingTables = false
    @Published private(set) var isLoadingCrossConnections = false
    @Published private(set) var isLoadingCrossConnectionQueries = false
    @Published private(set) var crossConnectionQueryContentRevision = 0
    @Published var selectedItemId: String?

    @Published var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleFilter(debounced: true)
        }
    }

    @Published var scope: QuickSwitcherScope = .all {
        didSet {
            guard oldValue != scope else { return }
            scheduleFilter(debounced: false)
        }
    }

    var flatItems: [QuickSwitcherItem] {
        groups.flatMap(\.items)
    }

    /// Whether the panel is still fetching the results it is being asked to show.
    ///
    /// The All scope with an empty search lists nothing but Recent, and the user has not asked for
    /// anything yet, so a spinner there would fire on every presentation for a list nobody is
    /// waiting on. Every other combination is showing, or about to show, something the catalog has
    /// to arrive for, and reporting it is what keeps a search that is about to succeed from
    /// rendering as "No results".
    ///
    /// `isFiltering` is the half that cannot be replaced by testing `allItems`: that property is
    /// ``, so nothing re-renders when it changes, and its `didSet` only
    /// schedules the filter. `groups` is committed an await later, so between the catalog landing
    /// and the filter committing there is a frame with nothing to show and no load in flight.
    var isLoadingResults: Bool {
        if scope.usesCrossConnectionCatalog {
            return isLoadingCrossConnections
        }
        if scope.usesCrossConnectionQueries {
            return isLoadingCrossConnectionQueries
        }
        guard scope != .all || !trimmedSearchText.isEmpty else { return false }
        let awaitsTables = isLoadingTables && scope.includedKinds.map { $0.contains(.table) } ?? true
        return isLoading || isFiltering || awaitsTables
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Nil outside the cross-connection scope, so a panel showing one connection's objects
    /// never observes every session's schema state and never reloads on their activity.
    var crossConnectionLoadVersion: CrossConnectionCatalogVersion? {
        guard scope.usesCrossConnectionCatalog else { return nil }
        return crossConnectionCatalogVersion
    }

    var crossConnectionQueryLoadVersion: CrossConnectionQueryVersion? {
        guard scope.usesCrossConnectionQueries else { return nil }
        return crossConnectionQueryVersion
    }

    func listHeight(rowHeight: CGFloat, headerHeight: CGFloat, maxVisibleRows: Int) -> CGFloat {
        let headerCount = groups.filter { $0.header != nil }.count
        let naturalHeight = CGFloat(flatItems.count) * rowHeight + CGFloat(headerCount) * headerHeight
        let maxHeight = CGFloat(maxVisibleRows) * rowHeight
        return min(naturalHeight, maxHeight)
    }

    init(
        connectionId: UUID,
        services: AppServices,
        defaults: UserDefaults = .standard,
        catalogStore: QuickSwitcherCatalogStore = .shared
    ) {
        self.connectionId = connectionId
        self.services = services
        self.defaults = defaults
        self.catalogStore = catalogStore
        self.frecencyStore = QuickSwitcherFrecencyStore(connectionId: connectionId, defaults: defaults)
    }

    convenience init(connectionId: UUID = UUID()) {
        self.init(connectionId: connectionId, services: .live)
    }

    /// Tables are not part of the cached catalog. They are merged in from the services that own
    /// them, every time either one changes while the panel is open, so a list the sidebar loads or
    /// the all-schema listing arriving after the panel opened still reaches it.
    func loadItems(
        databaseType: DatabaseType,
        openTables: Set<QuickSwitcherOpenTable> = [],
        browseSchema: String? = nil
    ) async {
        isLoading = true

        let loadId = UUID()
        activeLoadId = loadId

        let tableSource = TableSource(
            database: services.databaseManager.browseScope(for: connectionId)?.database,
            connectionSwitchesDatabases: services.pluginManager.supportsDatabaseSwitching(for: databaseType),
            browseSchema: browseSchema,
            openTables: openTables,
            grouping: services.pluginManager.databaseGroupingStrategy(for: databaseType)
        )
        self.tableSource = tableSource
        observeTableSources()
        async let tablesLoaded: Void = loadTables(from: tableSource, loadId: loadId)

        /// Read once and used both to key the catalog and to build it. Reading it again after the
        /// awaits below let the two disagree: the items were filtered by whatever the sidebar held
        /// when the fetches finished, and stored under whatever it held when they started.
        let databaseFilter = SharedSidebarState.forConnection(connectionId).databaseFilterSelected
        let catalogVersion = self.catalogVersion(databaseFilter: databaseFilter)
        if let cached = catalogStore.catalog(for: connectionId, version: catalogVersion) {
            baseItems = cached
        } else {
            let catalog = await loadBaseCatalog(databaseType: databaseType, databaseFilter: databaseFilter)
            guard activeLoadId == loadId, !Task.isCancelled else { return }
            if catalog.isComplete {
                catalogStore.store(catalog.items, for: connectionId, version: catalogVersion)
            }
            baseItems = catalog.items
        }
        tableItems = currentTableItems()
        publishItems()
        await tablesLoaded
    }

    /// Everything but the tables, which is what the catalog store keeps. Incomplete when a fetch
    /// failed, and then it is not stored: a cached catalog is served without fetching anything, so
    /// a schema list that timed out once would have stayed missing on every reopen.
    private func loadBaseCatalog(
        databaseType: DatabaseType,
        databaseFilter: Set<String>
    ) async -> (items: [QuickSwitcherItem], isComplete: Bool) {
        var items: [QuickSwitcherItem] = []
        var isComplete = true

        let switchTarget = services.pluginManager.containerSwitchTarget(for: databaseType)
        let activeDatabase = services.databaseManager.session(for: connectionId)
            .map { services.databaseManager.browseDatabaseName(for: $0.connection) }
        let qualifier = QuickSwitcherFrecencyKey.DatabaseQualifier(
            database: activeDatabase,
            connectionSwitchesDatabases: services.pluginManager.supportsDatabaseSwitching(for: databaseType)
        )
        /// A schema-only engine has no database to switch to, and its driver answers
        /// `fetchDatabases()` with its schema list, so listing them here showed every schema
        /// twice and the copy labelled "Database" failed with the driver's own error (#2262).
        if switchTarget != .schema {
            do {
                let databases = try await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { driver in
                    try await driver.fetchDatabases()
                }
                let databaseSubtitle = switchTarget == .database
                    ? services.pluginManager.containerEntityName(for: databaseType)
                    : String(localized: "Database")
                let listed = switchTarget == .database
                    ? DatabaseSwitchList.sections(
                        names: databases,
                        systemNames: Set(services.pluginManager.systemDatabaseNames(for: databaseType)),
                        selected: databaseFilter,
                        activeDatabase: activeDatabase
                    ).all.map(\.name)
                    : databases
                for db in listed {
                    items.append(QuickSwitcherItem(
                        frecencyKey: QuickSwitcherFrecencyKey.database(db),
                        name: db,
                        kind: .database,
                        subtitle: databaseSubtitle
                    ))
                }
            } catch {
                isComplete = false
                Self.logger.warning("Failed to fetch databases: \(error.publicLogShape, privacy: .public)")
            }
        }

        if services.pluginManager.supportsSchemaSwitching(for: databaseType) {
            do {
                let schemas = try await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { driver in
                    try await driver.fetchSchemas()
                }
                let schemaSubtitle = switchTarget == .schema
                    ? services.pluginManager.containerEntityName(for: databaseType)
                    : String(localized: "Schema")
                for schema in schemas {
                    items.append(QuickSwitcherItem(
                        frecencyKey: QuickSwitcherFrecencyKey.schema(schema, in: qualifier),
                        name: schema,
                        kind: .schema,
                        subtitle: schemaSubtitle
                    ))
                }
            } catch {
                isComplete = false
                Self.logger.warning("Failed to fetch schemas: \(error.publicLogShape, privacy: .public)")
            }
        }

        items += routineItems(connectionId: connectionId, database: activeDatabase, qualifier: qualifier)
        items += triggerItems(connectionId: connectionId, database: activeDatabase, qualifier: qualifier)
        items += userTypeItems(connectionId: connectionId, database: activeDatabase, qualifier: qualifier)

        let favorites = await services.sqlFavoriteManager.fetchFavorites(connectionId: connectionId)
        for favorite in favorites {
            items.append(QuickSwitcherItem(
                frecencyKey: QuickSwitcherFrecencyKey.savedQuery(favorite.id),
                name: favorite.name,
                kind: .savedQuery,
                subtitle: favorite.keyword ?? "",
                keyword: favorite.keyword,
                payload: favorite.query
            ))
        }

        let historyEntries = await services.queryHistoryManager.fetch(
            QueryHistoryFilter(scope: .connection(connectionId), sources: QueryHistorySource.userAuthored),
            limit: 200
        ).entries
        items += Self.makeHistoryItems(historyEntries)

        return (items, isComplete)
    }

    /// The catalog is a function of these, so a presentation that finds them unchanged can serve
    /// the previous one instead of re-running its fetches. Favorites and query history move without
    /// any of the rest moving, which is what `contentRevision` covers.
    private func catalogVersion(databaseFilter: Set<String>) -> QuickSwitcherCatalogStore.Version {
        QuickSwitcherCatalogStore.Version(
            browseScope: services.databaseManager.browseScope(for: connectionId),
            schemaGeneration: services.schemaService.generationToken(for: connectionId),
            isRefreshing: services.schemaService.isRefreshing(connectionId: connectionId),
            databaseFilter: databaseFilter.sorted(),
            contentRevision: catalogStore.contentRevision(for: connectionId),
            containerNames: knownContainerNames(),
            sessionEpoch: catalogStore.sessionEpoch(for: connectionId)
        )
    }

    /// Every database the connection knows about, and the schemas of the one being browsed. Dropping
    /// or creating either refreshes `DatabaseTreeMetadataService`, which is what makes this move.
    private func knownContainerNames() -> [String] {
        let metadata = DatabaseTreeMetadataService.shared
        var names = metadata.databases(for: connectionId).map { "database:\($0.name)" }.sorted()
        guard let database = services.databaseManager.browseScope(for: connectionId)?.database else {
            return names
        }
        let schemas = metadata.schemas(connectionId: connectionId, database: database)
        names.append(contentsOf: schemas.map { "schema:\($0)" }.sorted())
        return names
    }

    /// The browse schema's tables come from the schema service, which the sidebar loaded on
    /// connect; every other schema's come from the all-schema listing, which is asked for here.
    private func loadTables(from source: TableSource, loadId: UUID) async {
        isLoadingTables = true
        defer {
            if activeLoadId == loadId { isLoadingTables = false }
        }
        _ = await services.schemaRefreshService.loadBrowseCatalogs(connectionIds: [connectionId])
        guard activeLoadId == loadId else { return }
        mergeTableItems()
        guard source.listsTablesPerSchema, let database = source.database else { return }
        let service = DatabaseTreeMetadataService.shared
        listingDemand.noteRequested(connectionId: connectionId, database: database, service: service)
        await service.loadAllSchemaTables(connectionId: connectionId, database: database)
        guard activeLoadId == loadId else { return }
        mergeTableItems()
    }

    /// A change to either source while the panel is open reaches it. A change that leaves the
    /// tables as they were costs a comparison and no refilter. A catalog change or a reconnect
    /// while it is open asks for the listing again.
    private func observeTableSources() {
        tableSourceObservations = [
            services.schemaService.onMainActorChange { [weak self] in self?.mergeTableItems() },
            DatabaseTreeMetadataService.shared.onMainActorChange { [weak self] in
                self?.requestListingIfStale()
                self?.mergeTableItems()
            },
            services.databaseManager.onMainActorChange { [weak self] in self?.requestListingIfStale() }
        ]
    }

    private func requestListingIfStale() {
        guard let tableSource, tableSource.listsTablesPerSchema, let database = tableSource.database else { return }
        listingDemand.requestIfNeeded(
            connectionId: connectionId,
            database: database,
            isConnected: services.databaseManager.session(for: connectionId)?.status == .connected,
            service: DatabaseTreeMetadataService.shared
        )
    }

    private func mergeTableItems() {
        let items = currentTableItems()
        guard items != tableItems else { return }
        tableItems = items
        publishItems()
    }

    private func currentTableItems() -> [QuickSwitcherItem] {
        guard let tableSource else { return [] }
        let listing = tableSource.database.flatMap { database -> [TableInfo]? in
            guard tableSource.listsTablesPerSchema else { return nil }
            return DatabaseTreeMetadataService.shared
                .allSchemaTablesLoadState(connectionId: connectionId, database: database).value?.tables
        }
        let loadedScope = services.schemaService.loadedScope(for: connectionId)
        let tables = Self.mergedTables(
            local: services.schemaService.allLoadedTables(for: connectionId),
            loadedFrom: loadedScope?.database,
            coveredSchemas: coveredSchemas(loadedScope: loadedScope, grouping: tableSource.grouping),
            listing: listing,
            browsing: tableSource.database,
            grouping: tableSource.grouping
        )
        return Self.makeTableItems(
            tables,
            database: tableSource.database,
            connectionSwitchesDatabases: tableSource.connectionSwitchesDatabases,
            browseSchema: tableSource.browseSchema,
            openTables: tableSource.openTables
        )
    }

    /// Nothing is shown before the rest of the catalog has arrived, as before tables were merged
    /// separately: assigning `allItems` is what ends the load.
    private func publishItems() {
        guard let baseItems else { return }
        allItems = tableItems + baseItems
    }

    /// Loading is keyed on a version of the world, so it must always record the version it
    /// settled on. Leaving the version unrecorded because one connection failed re-arms the
    /// task that drives this, and the refresh it just ran has already moved the version, so
    /// the panel refreshes that connection forever.
    func loadCrossConnectionItems() async {
        guard scope.usesCrossConnectionCatalog else { return }
        guard loadedCrossConnectionVersion != crossConnectionCatalogVersion else { return }

        let loadId = UUID()
        activeCrossConnectionLoadId = loadId
        isLoadingCrossConnections = true
        defer {
            if activeCrossConnectionLoadId == loadId {
                isLoadingCrossConnections = false
            }
        }

        let loadedConnectionIds = await services.schemaRefreshService.loadBrowseCatalogs(
            connectionIds: connectedSessions().map(\.id)
        )
        guard activeCrossConnectionLoadId == loadId, !Task.isCancelled else { return }

        let sessions = connectedSessions()
        let unavailableCount = sessions.count - loadedConnectionIds.count
        if unavailableCount > 0 {
            Self.logger.warning(
                "[quickswitcher] cross-connection catalog omits \(unavailableCount, privacy: .public) of \(sessions.count, privacy: .public) connections"
            )
        }

        loadedCrossConnectionVersion = crossConnectionCatalogVersion
        crossConnectionItems = crossConnectionItems(for: sessions, loaded: loadedConnectionIds)
    }

    func invalidateCrossConnectionQueryItems() {
        crossConnectionQueryContentRevision &+= 1
    }

    func loadCrossConnectionQueryItems() async {
        guard scope.usesCrossConnectionQueries else { return }

        let version = crossConnectionQueryVersion
        guard loadedCrossConnectionQueryVersion != version else { return }

        let loadId = UUID()
        activeCrossConnectionQueryLoadId = loadId
        isLoadingCrossConnectionQueries = true
        defer {
            if activeCrossConnectionQueryLoadId == loadId {
                isLoadingCrossConnectionQueries = false
            }
        }

        let targets = queryTargets()
        async let favorites = services.sqlFavoriteManager.fetchFavorites(
            allowedConnectionIds: Set(targets.keys)
        )
        async let historyEntries = recentHistory(forConnections: Array(targets.keys))
        let (loadedFavorites, loadedHistoryEntries) = await (favorites, historyEntries)

        guard activeCrossConnectionQueryLoadId == loadId,
              !Task.isCancelled,
              version == crossConnectionQueryVersion else { return }

        loadedCrossConnectionQueryVersion = version
        crossConnectionQueryItems = Self.makeCrossConnectionQueryItems(
            favorites: loadedFavorites,
            historyEntries: loadedHistoryEntries,
            targets: targets,
            currentConnectionId: connectionId
        )
    }

    /// The panel's own connection stays listed while its session is reconnecting. Saved queries and
    /// history are stored locally, so a session that dropped is no reason to hide the queries the
    /// panel was opened next to, and the All scope keeps showing them either way.
    private func queryTargets() -> [UUID: QuickSwitcherTarget] {
        var targets = Dictionary(
            connectedSessions().map { ($0.id, queryTarget(for: $0)) },
            uniquingKeysWith: { _, latest in latest }
        )
        if targets[connectionId] == nil,
           let session = services.databaseManager.session(for: connectionId) {
            targets[connectionId] = queryTarget(for: session)
        }
        return targets
    }

    /// One busy connection must not crowd every other one out of the list. A single query capped at
    /// `maxResults` and ordered by recency returns nothing but the connection that ran the most
    /// statements today, so each connection is read separately and the union is interleaved.
    private func recentHistory(forConnections connectionIds: [UUID]) async -> [QueryHistoryEntry] {
        let manager = services.queryHistoryManager
        let limit = QuickSwitcherRanking.maxResults
        let perConnection = await withTaskGroup(of: [QueryHistoryEntry].self) { group in
            for id in connectionIds {
                group.addTask {
                    await manager.fetch(
                        QueryHistoryFilter(scope: .connection(id), sources: QueryHistorySource.userAuthored),
                        limit: limit
                    ).entries
                }
            }
            var collected: [[QueryHistoryEntry]] = []
            for await entries in group {
                collected.append(entries)
            }
            return collected
        }
        return Self.interleaveByConnection(perConnection, limit: limit)
    }

    private func connectedSessions() -> [ConnectionSession] {
        services.databaseManager.activeSessions.values
            .filter { $0.isConnected && $0.driver != nil }
            .sorted { lhs, rhs in
                lhs.connection.name.localizedStandardCompare(rhs.connection.name) == .orderedAscending
            }
    }

    private func queryTarget(for session: ConnectionSession) -> QuickSwitcherTarget {
        let scope = services.databaseManager.browseScope(for: session.id)
        let databaseName = scope.flatMap { $0.database.isEmpty ? nil : $0.database }
        let pathFieldRole = session.connection.type.pathFieldRole
        return QuickSwitcherTarget(
            connectionId: session.id,
            connectionName: session.connection.name,
            databaseName: databaseName,
            schemaName: scope?.schema,
            databaseDisplayName: Self.databaseDisplayName(
                databaseName,
                pathFieldRole: pathFieldRole
            ),
            pathFieldRole: pathFieldRole
        )
    }

    private func crossConnectionItems(
        for sessions: [ConnectionSession],
        loaded loadedConnectionIds: Set<UUID>
    ) -> [QuickSwitcherItem] {
        sessions
            .filter { loadedConnectionIds.contains($0.id) }
            .flatMap { session -> [QuickSwitcherItem] in
                guard let scope = services.databaseManager.browseScope(for: session.id) else { return [] }
                let databaseName = scope.database.isEmpty ? nil : scope.database
                let pathFieldRole = session.connection.type.pathFieldRole
                let target = QuickSwitcherTarget(
                    connectionId: session.id,
                    connectionName: session.connection.name,
                    databaseName: databaseName,
                    schemaName: scope.schema,
                    databaseDisplayName: Self.databaseDisplayName(
                        databaseName,
                        pathFieldRole: pathFieldRole
                    ),
                    pathFieldRole: pathFieldRole
                )
                return Self.makeCrossConnectionItems(
                    tables: services.schemaService.allLoadedTables(for: session.id),
                    target: target,
                    connectionSwitchesDatabases: services.pluginManager.supportsDatabaseSwitching(
                        for: session.connection.type
                    )
                )
            }
    }

    private var crossConnectionCatalogVersion: CrossConnectionCatalogVersion {
        let entries = services.databaseManager.activeSessions.values
            .filter { $0.isConnected && $0.driver != nil }
            .compactMap { session -> CrossConnectionCatalogVersion.Entry? in
                guard let scope = services.databaseManager.browseScope(for: session.id) else { return nil }
                return CrossConnectionCatalogVersion.Entry(
                    connectionId: session.id,
                    browseScope: scope,
                    loadedScope: services.schemaService.loadedScope(for: session.id),
                    schemaGeneration: services.schemaService.generationToken(for: session.id),
                    isRefreshing: services.schemaService.isRefreshing(connectionId: session.id)
                )
            }
            .sorted { $0.connectionId.uuidString < $1.connectionId.uuidString }
        return CrossConnectionCatalogVersion(
            connectionStatusVersion: services.databaseManager.connectionStatusVersion,
            entries: entries
        )
    }

    /// The schema service answers for every schema it holds a list of, because it refreshes that
    /// list the moment the catalog changes. The all-schema listing fills in the schemas it does not
    /// hold, and may be a read behind for those until it is next asked.
    ///
    /// The schema service keeps its lists until a reload replaces them, so while a database switch
    /// settles it still holds the old database's tables, which would open against the new one.
    /// They count only once the database they were loaded from is the one being browsed.
    ///
    /// `coveredSchemas` names the schemas the schema service answers for even when it found them
    /// empty. Judged from its rows alone, a schema whose last table was dropped would have no rows,
    /// so no say, and the listing's stale copy of that table would come back.
    ///
    /// A hierarchical engine is the exception. Its per-schema lists are keyed by schema alone and
    /// keep the rows of a database the connection has just switched away from until each one
    /// reloads, so once the listing, which is keyed by database, has arrived it answers for every
    /// schema, and the schema service only stands in until then.
    nonisolated static func mergedTables(
        local loaded: [TableInfo],
        loadedFrom loadedDatabase: String?,
        coveredSchemas: Set<String>,
        listing: [TableInfo]?,
        browsing database: String?,
        grouping: GroupingStrategy
    ) -> [TableInfo] {
        let listingAnswersAll = grouping == .hierarchicalSchema && listing != nil
        let isCurrent = loadedDatabase == database && !listingAnswersAll
        let local = isCurrent ? loaded : []
        let authoritative = (isCurrent ? coveredSchemas : []).union(local.map { $0.schema ?? "" })
        var seen: Set<TableIdentity> = []
        return (local + (listing ?? []).filter { !authoritative.contains($0.schema ?? "") })
            .filter { seen.insert(TableIdentity(schema: $0.schema ?? "", name: $0.name)).inserted }
    }

    /// The schemas the schema service holds an answer for. On a schema-grouped engine its flat list
    /// is the browsed schema's; on a hierarchical one each schema keeps a list of its own, and the
    /// flat list is empty whatever the browsed schema holds.
    private func coveredSchemas(loadedScope: DatabaseScope?, grouping: GroupingStrategy) -> Set<String> {
        var covered = services.schemaService.schemasWithLoadedTables(for: connectionId)
        if grouping != .hierarchicalSchema,
           services.schemaService.hasLoadedContent(for: connectionId),
           let schema = loadedScope?.schema {
            covered.insert(schema)
        }
        return covered
    }

    private struct TableIdentity: Hashable {
        let schema: String
        let name: String
    }

    /// A table outside the browsed schema names its schema, and one inside it does not, the way
    /// SQL written against the browsed schema would spell them.
    nonisolated static func makeTableItems(
        _ tables: [TableInfo],
        database: String?,
        connectionSwitchesDatabases: Bool,
        browseSchema: String?,
        openTables: Set<QuickSwitcherOpenTable>
    ) -> [QuickSwitcherItem] {
        let qualifier = QuickSwitcherFrecencyKey.DatabaseQualifier(
            database: database,
            connectionSwitchesDatabases: connectionSwitchesDatabases
        )
        var listedKeys: Set<String> = []
        return tables.compactMap { table in
            let frecencyKey = QuickSwitcherFrecencyKey.table(
                name: table.name, schema: table.schema ?? browseSchema, in: qualifier
            )
            guard listedKeys.insert(frecencyKey).inserted else { return nil }
            let presentation = tablePresentation(for: table.type)
            let otherSchema = SchemaQualifiedName.explicitSchema(table.schema, implicitSchemaName: browseSchema)
            let subtitle = [otherSchema, presentation.subtitle]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
            return QuickSwitcherItem(
                frecencyKey: frecencyKey,
                name: table.name,
                kind: presentation.kind,
                subtitle: subtitle,
                isOpenInTab: openTables.contains(
                    QuickSwitcherOpenTable(schema: table.schema, name: table.name, browsing: browseSchema)
                ),
                isReadOnly: !table.type.allowsRowEditing,
                schemaName: table.schema,
                databaseName: database,
                tableType: table.type,
                isOutsideBrowsedSchema: otherSchema != nil
            )
        }
    }

    nonisolated static func makeCrossConnectionItems(
        tables: [TableInfo],
        target: QuickSwitcherTarget,
        connectionSwitchesDatabases: Bool
    ) -> [QuickSwitcherItem] {
        let qualifier = QuickSwitcherFrecencyKey.DatabaseQualifier(
            database: target.databaseName,
            connectionSwitchesDatabases: connectionSwitchesDatabases
        )
        var listedKeys: Set<String> = []
        return tables.compactMap { table in
            let resolvedTarget = QuickSwitcherTarget(
                connectionId: target.connectionId,
                connectionName: target.connectionName,
                databaseName: target.databaseName,
                schemaName: table.schema ?? target.schemaName,
                databaseDisplayName: target.databaseDisplayName,
                pathFieldRole: target.pathFieldRole
            )
            let frecencyKey = QuickSwitcherFrecencyKey.table(
                name: table.name, schema: resolvedTarget.schemaName, in: qualifier
            )
            guard listedKeys.insert(frecencyKey).inserted else { return nil }
            let presentation = tablePresentation(for: table.type)
            return QuickSwitcherItem(
                frecencyKey: frecencyKey,
                name: table.name,
                kind: presentation.kind,
                subtitle: connectionPath(for: resolvedTarget),
                isReadOnly: !table.type.allowsRowEditing,
                target: resolvedTarget,
                tableType: table.type
            )
        }
    }

    func canOpenStructure(_ item: QuickSwitcherItem) -> Bool {
        guard let target = item.target else { return true }
        return target.connectionId == connectionId
    }

    func selectedItem() -> QuickSwitcherItem? {
        guard let id = selectedItemId else { return nil }
        return flatItems.first { $0.id == id }
    }

    func moveSelection(by delta: Int) {
        let items = flatItems
        guard !items.isEmpty else {
            selectedItemId = nil
            return
        }
        if let id = selectedItemId, let index = items.firstIndex(where: { $0.id == id }) {
            let next = max(0, min(items.count - 1, index + delta))
            selectedItemId = items[next].id
        } else {
            selectedItemId = items.first?.id
        }
    }

    func recordSelection(_ item: QuickSwitcherItem, at date: Date = Date()) {
        frecencyStore(for: item).recordAccess(itemId: item.frecencyKey, at: date)
    }

    /// A result from another connection is recorded against that connection. The store is keyed per
    /// connection and the Recent section resolves its ids against the scope on screen, so recording
    /// a foreign id here holds one of ten slots with something this connection can never show.
    private func frecencyStore(for item: QuickSwitcherItem) -> QuickSwitcherFrecencyStore {
        guard let target = item.target, target.connectionId != connectionId else { return frecencyStore }
        return QuickSwitcherFrecencyStore(connectionId: target.connectionId, defaults: defaults)
    }

    /// Grouping sorts the whole scoped catalog, which across every open connection runs to
    /// tens of thousands of localized comparisons. Both the empty-query and the query path
    /// build off the main actor so neither can stall the panel while it is being typed into.
    private func scheduleFilter(debounced: Bool) {
        filterTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let items = scopedItems()
        let scope = scope
        let connectionId = connectionId
        let frecencyScores = frecencyStore.scores()
        let recentKeys = frecencyStore.recentItemIds()
        isFiltering = true
        filterTask = Task { @MainActor [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: Self.filterDebounceNanoseconds)
                guard !Task.isCancelled else { return }
            }
            let groups = query.isEmpty
                ? await Self.emptyQueryGroups(
                    items: items, scope: scope, recentKeys: recentKeys, connectionId: connectionId
                )
                : await Self.filteredGroups(
                    items: items, query: query, frecencyScores: frecencyScores, connectionId: connectionId
                )
            guard !Task.isCancelled, let self else { return }
            self.groups = groups
            self.isFiltering = false
            self.reconcileSelection(query: query, scope: scope)
        }
    }

    /// Commits the pending refilter now instead of waiting out its debounce, so a Return typed
    /// straight after the last keystroke commits the result for what was typed rather than
    /// finding no selection and doing nothing.
    func flushPendingFilter() async {
        guard filterTask != nil else { return }
        scheduleFilter(debounced: false)
        await filterTask?.value
    }

    /// A refilter the user did not ask for keeps their selection; a new query moves it to the best
    /// match. Surviving the refilter is not evidence that the old row is still what the user wants:
    /// `bestMatch` falls back to the subtitle, and every Connections-scope subtitle carries the
    /// connection path, so a query matches most of the catalog through that path alone. The old row
    /// therefore almost always survived, the highlight stayed on it while the ranked list moved
    /// underneath, and Return opened something the user had stopped searching for.
    private func reconcileSelection(query: String, scope: QuickSwitcherScope) {
        let items = flatItems
        let isSameSearch = query == selectionQuery && scope == selectionScope
        selectionQuery = query
        selectionScope = scope
        if isSameSearch, let current = selectedItemId, items.contains(where: { $0.id == current }) {
            return
        }
        selectedItemId = items.first?.id
    }

    private func scopedItems() -> [QuickSwitcherItem] {
        let source: [QuickSwitcherItem]
        if scope.usesCrossConnectionCatalog {
            source = crossConnectionItems
        } else if scope.usesCrossConnectionQueries {
            source = crossConnectionQueryItems
        } else {
            source = allItems
        }
        guard let includedKinds = scope.includedKinds else { return source }
        return source.filter { includedKinds.contains($0.kind) }
    }

    nonisolated private static func emptyQueryGroups(
        items: [QuickSwitcherItem],
        scope: QuickSwitcherScope,
        recentKeys: [String],
        connectionId: UUID
    ) async -> [Group] {
        let recent = recentItems(in: items, keys: recentKeys, ownedBy: connectionId)
        let recentKeySet = Set(recent.map(\.frecencyKey))
        let isRecent: (QuickSwitcherItem) -> Bool = { item in
            item.belongs(to: connectionId) && recentKeySet.contains(item.frecencyKey)
        }

        var result: [Group] = []

        if !recent.isEmpty {
            result.append(Group(id: "recent", header: String(localized: "Recent"), items: recent))
        }

        if scope.usesCrossConnectionCatalog {
            return result + connectionGroups(items: items, excluding: isRecent)
        }

        guard scope != .all else { return result }

        for kind in QuickSwitcherItemKind.displayOrder {
            let kindItems = items
                .filter { $0.kind == kind && !isRecent($0) }
                .sorted { lhs, rhs in
                    if lhs.isOutsideBrowsedSchema != rhs.isOutsideBrowsedSchema { return rhs.isOutsideBrowsedSchema }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            guard !kindItems.isEmpty else { continue }
            result.append(Group(
                id: "kind-\(kind.rawValue)",
                header: kind.sectionTitle,
                items: Array(kindItems.prefix(QuickSwitcherRanking.maxResults))
            ))
        }
        return result
    }

    nonisolated private static func recentItems(
        in items: [QuickSwitcherItem],
        keys recentKeys: [String],
        ownedBy connectionId: UUID
    ) -> [QuickSwitcherItem] {
        let rank = Dictionary(recentKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var rankedItems: [Int: QuickSwitcherItem] = [:]
        for item in items where item.belongs(to: connectionId) {
            guard let position = rank[item.frecencyKey], rankedItems[position] == nil else { continue }
            rankedItems[position] = item
        }
        return rankedItems
            .sorted { $0.key < $1.key }
            .prefix(QuickSwitcherRanking.recentLimit)
            .map(\.value)
    }

    nonisolated private static func connectionGroups(
        items: [QuickSwitcherItem],
        excluding isExcluded: (QuickSwitcherItem) -> Bool
    ) -> [Group] {
        let excludedCount = items.reduce(into: 0) { count, item in
            if isExcluded(item) { count += 1 }
        }
        let availableCount = max(0, QuickSwitcherRanking.maxResults - excludedCount)
        let sortedItems = items
            .filter { !isExcluded($0) }
            .sorted { lhs, rhs in
                let lhsConnection = lhs.target?.connectionName ?? ""
                let rhsConnection = rhs.target?.connectionName ?? ""
                let connectionOrder = lhsConnection.localizedStandardCompare(rhsConnection)
                if connectionOrder != .orderedSame { return connectionOrder == .orderedAscending }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(availableCount)

        var order: [UUID] = []
        var grouped: [UUID: [QuickSwitcherItem]] = [:]
        var names: [UUID: String] = [:]
        for item in sortedItems {
            guard let target = item.target else { continue }
            if grouped[target.connectionId] == nil {
                order.append(target.connectionId)
                names[target.connectionId] = target.connectionName
            }
            grouped[target.connectionId, default: []].append(item)
        }

        return order.compactMap { connectionId in
            guard let items = grouped[connectionId], let name = names[connectionId] else { return nil }
            return Group(id: "connection-\(connectionId.uuidString)", header: name, items: items)
        }
    }

    nonisolated private static func filteredGroups(
        items: [QuickSwitcherItem],
        query: String,
        frecencyScores: [String: Double],
        connectionId: UUID
    ) async -> [Group] {
        let qualified = QualifiedSearchQuery(query)
        let prefersShorterNames = qualified.map { !$0.name.isEmpty } ?? true
        var ranked = items.compactMap { item -> (item: QuickSwitcherItem, rank: Double)? in
            guard let (matchScore, matchedIndices) = bestMatch(for: item, query: query, qualified: qualified) else {
                return nil
            }
            var matched = item
            matched.matchedIndices = matchedIndices
            let recalled = item.belongs(to: connectionId) ? frecencyScores[item.frecencyKey] ?? 0 : 0
            let frecency = 1 + recalled * QuickSwitcherRanking.frecencyBoost
            let openBoost = item.isOpenInTab ? QuickSwitcherRanking.openTabBoost : 1
            let location = item.isOutsideBrowsedSchema ? QuickSwitcherRanking.otherSchemaWeight : 1
            return (matched, matchScore * item.kind.rankWeight * frecency * openBoost * location)
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            let lhsOrder = QuickSwitcherItemKind.displayOrder.firstIndex(of: lhs.item.kind) ?? Int.max
            let rhsOrder = QuickSwitcherItemKind.displayOrder.firstIndex(of: rhs.item.kind) ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let lhsLength = (lhs.item.name as NSString).length
            let rhsLength = (rhs.item.name as NSString).length
            if prefersShorterNames, lhsLength != rhsLength { return lhsLength < rhsLength }
            return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }
        let items = Array(ranked.prefix(QuickSwitcherRanking.maxResults).map(\.item))
        guard !items.isEmpty else { return [] }
        return [Group(id: "results", header: nil, items: items)]
    }

    /// A dotted query is read both ways and the better reading wins: as a path, and as plain text,
    /// which is what still finds a table literally named `b.c` and a connection path in a subtitle.
    nonisolated private static func bestMatch(
        for item: QuickSwitcherItem,
        query: String,
        qualified: QualifiedSearchQuery?
    ) -> (score: Double, matchedIndices: [Int])? {
        let plain = plainMatch(for: item, query: query)
        guard let qualified, let path = pathMatch(for: item, query: qualified) else { return plain }
        guard let plain, plain.score >= path.score else { return path }
        return plain
    }

    /// Each container the query names has to match the part of the item's location it lines up
    /// with, and the name has to match the item's name. An empty name, `attendance.`, takes every
    /// item in the matched container.
    nonisolated static func pathMatch(
        for item: QuickSwitcherItem,
        query: QualifiedSearchQuery
    ) -> (score: Double, matchedIndices: [Int])? {
        guard let pairs = query.containerPairs(with: item.searchLocation) else { return nil }
        var containerScore = 0.0
        for pair in pairs {
            guard let match = FuzzyMatcher.match(query: pair.query, candidate: pair.candidate) else { return nil }
            containerScore += Double(match.score)
        }
        let weightedContainers = containerScore * QuickSwitcherRanking.containerMatchWeight
        guard !query.name.isEmpty else { return (weightedContainers, []) }
        guard let nameMatch = FuzzyMatcher.match(query: query.name, candidate: item.name) else { return nil }
        return (Double(nameMatch.score) + weightedContainers, nameMatch.matchedIndices)
    }

    nonisolated private static func plainMatch(
        for item: QuickSwitcherItem,
        query: String
    ) -> (score: Double, matchedIndices: [Int])? {
        let nameMatch = FuzzyMatcher.match(query: query, candidate: item.name)
        var secondaryScores: [Double] = []
        if let keyword = item.keyword,
           !keyword.isEmpty,
           let keywordMatch = FuzzyMatcher.match(query: query, candidate: keyword) {
            secondaryScores.append(Double(keywordMatch.score) * QuickSwitcherRanking.keywordMatchWeight)
        }
        if !item.subtitle.isEmpty, let subtitleMatch = FuzzyMatcher.match(query: query, candidate: item.subtitle) {
            secondaryScores.append(Double(subtitleMatch.score) * QuickSwitcherRanking.subtitleMatchPenalty)
        }
        let subtitleScore = secondaryScores.max()

        switch (nameMatch, subtitleScore) {
        case let (match?, score?) where score > Double(match.score):
            return (score, [])
        case let (match?, _):
            return (Double(match.score), match.matchedIndices)
        case let (nil, score?):
            return (score, [])
        case (nil, nil):
            return nil
        }
    }

    nonisolated private static func tablePresentation(
        for type: TableInfo.TableType
    ) -> (kind: QuickSwitcherItemKind, subtitle: String) {
        switch type {
        case .table:
            return (.table, "")
        case .view:
            return (.view, String(localized: "View"))
        case .materializedView:
            return (.view, String(localized: "Materialized View"))
        case .foreignTable:
            return (.table, String(localized: "Foreign Table"))
        case .systemTable:
            return (.systemTable, String(localized: "System"))
        case .partitionedTable:
            return (.table, String(localized: "Partitioned Table"))
        case .externalTable:
            return (.table, String(localized: "External Table"))
        case .sequence:
            return (.table, String(localized: "Sequence"))
        }
    }

    nonisolated static func connectionPath(for target: QuickSwitcherTarget) -> String {
        var components = [target.connectionName]
        if let databaseDisplayName = target.databaseDisplayName ?? target.databaseName,
           !databaseDisplayName.isEmpty {
            components.append(databaseDisplayName)
        }
        if let schemaName = target.schemaName,
           !schemaName.isEmpty,
           schemaName != target.databaseName {
            components.append(schemaName)
        }
        return components.joined(separator: " / ")
    }

    private var crossConnectionQueryVersion: CrossConnectionQueryVersion {
        CrossConnectionQueryVersion(
            connectedConnectionIds: queryTargets().keys.sorted { $0.uuidString < $1.uuidString },
            contentRevision: crossConnectionQueryContentRevision
        )
    }

    /// Reads the sidebar's own cache rather than querying. The switcher opens over a connection
    /// whose objects the tree has already loaded, and a fresh catalog read per keystroke session
    /// would make opening the panel wait on the server.
    private func routineItems(
        connectionId: UUID,
        database: String?,
        qualifier: QuickSwitcherFrecencyKey.DatabaseQualifier
    ) -> [QuickSwitcherItem] {
        let routines = SchemaService.shared.routines(for: connectionId)
        let labels = RoutineDisplayLabel.labels(for: routines)
        return routines.map { routine in
            QuickSwitcherItem(
                frecencyKey: QuickSwitcherFrecencyKey.routine(routine.id, in: qualifier),
                name: labels[routine.id] ?? routine.name,
                kind: routine.kind == .procedure ? .procedure : .function,
                subtitle: routine.schema ?? database ?? "",
                schemaName: routine.schema,
                objectRef: DatabaseObjectRef(routine: routine, database: database ?? ""),
                databaseName: database
            )
        }
    }

    private func triggerItems(
        connectionId: UUID,
        database: String?,
        qualifier: QuickSwitcherFrecencyKey.DatabaseQualifier
    ) -> [QuickSwitcherItem] {
        SchemaService.shared.triggers(for: connectionId).map { trigger in
            QuickSwitcherItem(
                frecencyKey: QuickSwitcherFrecencyKey.trigger(trigger.id, in: qualifier),
                name: trigger.name,
                kind: .trigger,
                subtitle: trigger.table ?? trigger.schema ?? database ?? "",
                schemaName: trigger.schema,
                objectRef: DatabaseObjectRef(trigger: trigger, database: database ?? ""),
                databaseName: database
            )
        }
    }

    private func userTypeItems(
        connectionId: UUID,
        database: String?,
        qualifier: QuickSwitcherFrecencyKey.DatabaseQualifier
    ) -> [QuickSwitcherItem] {
        SchemaService.shared.userDefinedTypes(for: connectionId).map { type in
            QuickSwitcherItem(
                frecencyKey: QuickSwitcherFrecencyKey.userType(type.id, in: qualifier),
                name: type.name,
                kind: .userType,
                subtitle: type.schema ?? database ?? "",
                schemaName: type.schema,
                objectRef: DatabaseObjectRef(userType: type, database: database ?? ""),
                databaseName: database
            )
        }
    }

    nonisolated static func databaseDisplayName(
        _ databaseName: String?,
        pathFieldRole: PathFieldRole
    ) -> String? {
        guard let databaseName, !databaseName.isEmpty else { return nil }
        guard pathFieldRole == .filePath else { return databaseName }
        return (databaseName as NSString).abbreviatingWithTildeInPath
    }
}

private extension QuickSwitcherItemKind {
    static let displayOrder: [QuickSwitcherItemKind] = [
        .table, .view, .systemTable, .database, .schema,
        .procedure, .function, .trigger, .userType, .savedQuery, .queryHistory
    ]

    var rankWeight: Double {
        switch self {
        case .table: return 1.0
        case .view: return 0.98
        case .systemTable: return 0.85
        case .database: return 0.95
        case .schema: return 0.93
        case .procedure: return 0.92
        case .function: return 0.92
        case .trigger: return 0.91
        case .userType: return 0.91
        case .savedQuery: return 0.9
        case .queryHistory: return 0.7
        }
    }

    var sectionTitle: String {
        switch self {
        case .table: return String(localized: "Tables")
        case .view: return String(localized: "Views")
        case .systemTable: return String(localized: "System Tables")
        case .database: return String(localized: "Databases")
        case .schema: return String(localized: "Schemas")
        case .procedure: return String(localized: "Procedures")
        case .function: return String(localized: "Functions")
        case .trigger: return String(localized: "Triggers")
        case .userType: return String(localized: "Types")
        case .savedQuery: return String(localized: "Saved Queries")
        case .queryHistory: return String(localized: "Recent Queries")
        }
    }
}
