//
//  QuickSwitcherViewModel.swift
//  TablePro
//

import Foundation
import Observation
import os
import TableProPluginKit

private enum QuickSwitcherRanking {
    static let maxResults = 200
    static let subtitleMatchPenalty = 0.6
    static let keywordMatchWeight = 1.0
    static let frecencyBoost = 0.5
    static let openTabBoost = 1.2
}

@MainActor
@Observable
internal final class QuickSwitcherViewModel {
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

    private static let logger = Logger(subsystem: "com.TablePro", category: "QuickSwitcherViewModel")
    private static let recentLimit = 10
    private static let filterDebounceNanoseconds: UInt64 = 40_000_000

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let connectionId: UUID
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let frecencyStore: QuickSwitcherFrecencyStore

    @ObservationIgnored internal var allItems: [QuickSwitcherItem] = [] {
        didSet { scheduleFilter(debounced: false) }
    }
    @ObservationIgnored internal var crossConnectionItems: [QuickSwitcherItem] = [] {
        didSet { scheduleFilter(debounced: false) }
    }
    @ObservationIgnored internal var crossConnectionQueryItems: [QuickSwitcherItem] = [] {
        didSet { scheduleFilter(debounced: false) }
    }
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadId = UUID()
    @ObservationIgnored private var activeCrossConnectionLoadId = UUID()
    @ObservationIgnored private var activeCrossConnectionQueryLoadId = UUID()
    @ObservationIgnored private var loadedCrossConnectionVersion: CrossConnectionCatalogVersion?
    @ObservationIgnored private var loadedCrossConnectionQueryVersion: CrossConnectionQueryVersion?

    private(set) var groups: [Group] = []
    private(set) var isLoading = true
    private(set) var isLoadingCrossConnections = false
    private(set) var isLoadingCrossConnectionQueries = false
    private(set) var crossConnectionQueryContentRevision = 0
    var selectedItemId: String?

    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleFilter(debounced: true)
        }
    }

    var scope: QuickSwitcherScope = .all {
        didSet {
            guard oldValue != scope else { return }
            scheduleFilter(debounced: false)
        }
    }

    var flatItems: [QuickSwitcherItem] {
        groups.flatMap(\.items)
    }

    var isLoadingResults: Bool {
        if scope.usesCrossConnectionCatalog {
            return isLoadingCrossConnections
        }
        return scope.usesCrossConnectionQueries && isLoadingCrossConnectionQueries
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

    init(connectionId: UUID, services: AppServices, defaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.services = services
        self.defaults = defaults
        self.frecencyStore = QuickSwitcherFrecencyStore(connectionId: connectionId, defaults: defaults)
    }

    convenience init(connectionId: UUID = UUID()) {
        self.init(connectionId: connectionId, services: .live)
    }

    func loadItems(
        schemaProvider: SQLSchemaProvider,
        databaseType: DatabaseType,
        openTableNames: Set<String> = []
    ) async {
        isLoading = true

        let loadId = UUID()
        activeLoadId = loadId

        var items: [QuickSwitcherItem] = []

        if await !schemaProvider.isSchemaLoaded(),
           let driver = services.databaseManager.driver(for: connectionId) {
            let connection = services.databaseManager.session(for: connectionId)?.connection
            await schemaProvider.loadSchema(using: driver, connection: connection)
        }

        let tables = await schemaProvider.getTables()
        for table in tables {
            let presentation = Self.tablePresentation(for: table.type)
            items.append(QuickSwitcherItem(
                id: "table_\(table.name)_\(table.type.rawValue)",
                name: table.name,
                kind: presentation.kind,
                subtitle: presentation.subtitle,
                isOpenInTab: openTableNames.contains(table.name),
                isReadOnly: !table.type.allowsRowEditing
            ))
        }

        let switchTarget = services.pluginManager.containerSwitchTarget(for: databaseType)
        let databaseFilter = SharedSidebarState.forConnection(connectionId).databaseFilterSelected
        let activeDatabase = services.databaseManager.session(for: connectionId)
            .map { services.databaseManager.browseDatabaseName(for: $0.connection) }
        let visibleDatabaseNames = switchTarget == .database
            ? Set(
                DatabaseTreeVisibility.visible(
                    databases: DatabaseTreeMetadataService.shared.databases(for: connectionId),
                    selected: databaseFilter,
                    activeDatabase: activeDatabase
                ).map(\.name)
            )
            : []
        do {
            let databases = try await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { driver in
                try await driver.fetchDatabases()
            }
            let databaseSubtitle = switchTarget == .database
                ? services.pluginManager.containerEntityName(for: databaseType)
                : String(localized: "Database")
            for db in databases {
                if switchTarget == .database {
                    if !visibleDatabaseNames.isEmpty {
                        if !visibleDatabaseNames.contains(db) { continue }
                    } else if !databaseFilter.isEmpty, db != activeDatabase, !databaseFilter.contains(db) {
                        continue
                    }
                }
                items.append(QuickSwitcherItem(
                    id: "db_\(db)",
                    name: db,
                    kind: .database,
                    subtitle: databaseSubtitle
                ))
            }
        } catch {
            Self.logger.warning("Failed to fetch databases: \(error.localizedDescription, privacy: .public)")
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
                        id: "schema_\(schema)",
                        name: schema,
                        kind: .schema,
                        subtitle: schemaSubtitle
                    ))
                }
            } catch {
                Self.logger.warning("Failed to fetch schemas: \(error.localizedDescription, privacy: .public)")
            }
        }

        let favorites = await services.sqlFavoriteManager.fetchFavorites(connectionId: connectionId)
        for favorite in favorites {
            items.append(QuickSwitcherItem(
                id: "favorite_\(favorite.id.uuidString)",
                name: favorite.name,
                kind: .savedQuery,
                subtitle: favorite.keyword ?? "",
                keyword: favorite.keyword,
                payload: favorite.query
            ))
        }

        let historyEntries = await services.queryHistoryManager.fetchHistory(
            limit: 50,
            connectionId: connectionId
        )
        for entry in historyEntries {
            items.append(QuickSwitcherItem(
                id: "history_\(entry.id.uuidString)",
                name: entry.queryPreview,
                kind: .queryHistory,
                subtitle: entry.databaseName,
                payload: entry.query
            ))
        }

        guard activeLoadId == loadId, !Task.isCancelled else { return }

        isLoading = false
        allItems = items
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
                    await manager.fetchHistory(limit: limit, connectionId: id)
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

    nonisolated static func interleaveByConnection(
        _ perConnection: [[QueryHistoryEntry]],
        limit: Int
    ) -> [QueryHistoryEntry] {
        var queues = perConnection.filter { !$0.isEmpty }
        var merged: [QueryHistoryEntry] = []
        var queueIndex = 0
        while merged.count < limit, !queues.isEmpty {
            if queueIndex >= queues.count { queueIndex = 0 }
            merged.append(queues[queueIndex].removeFirst())
            if queues[queueIndex].isEmpty {
                queues.remove(at: queueIndex)
            } else {
                queueIndex += 1
            }
        }
        return merged.sorted { $0.executedAt > $1.executedAt }
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
                    target: target
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

    nonisolated static func makeCrossConnectionItems(
        tables: [TableInfo],
        target: QuickSwitcherTarget
    ) -> [QuickSwitcherItem] {
        tables.map { table in
            let presentation = tablePresentation(for: table.type)
            let resolvedTarget = QuickSwitcherTarget(
                connectionId: target.connectionId,
                connectionName: target.connectionName,
                databaseName: target.databaseName,
                schemaName: table.schema ?? target.schemaName,
                databaseDisplayName: target.databaseDisplayName,
                pathFieldRole: target.pathFieldRole
            )
            return QuickSwitcherItem(
                id: "connection_\(target.connectionId.uuidString)_\(table.id)",
                name: table.name,
                kind: presentation.kind,
                subtitle: connectionPath(for: resolvedTarget),
                isReadOnly: !table.type.allowsRowEditing,
                target: resolvedTarget
            )
        }
    }

    nonisolated static func makeCrossConnectionQueryItems(
        favorites: [SQLFavorite],
        historyEntries: [QueryHistoryEntry],
        targets: [UUID: QuickSwitcherTarget],
        currentConnectionId: UUID
    ) -> [QuickSwitcherItem] {
        let favoriteItems = favorites.compactMap { favorite -> QuickSwitcherItem? in
            let targetConnectionId = favorite.connectionId ?? currentConnectionId
            guard let target = targets[targetConnectionId] else { return nil }
            let subtitle = [favorite.keyword, connectionPath(for: target)]
                .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
                .joined(separator: " · ")
            return QuickSwitcherItem(
                id: "favorite_\(favorite.id.uuidString)",
                name: favorite.name,
                kind: .savedQuery,
                subtitle: subtitle,
                keyword: favorite.keyword,
                payload: favorite.query,
                target: target
            )
        }

        let historyItems = historyEntries.compactMap { entry -> QuickSwitcherItem? in
            guard let baseTarget = targets[entry.connectionId] else { return nil }
            let databaseName = entry.databaseName.isEmpty ? nil : entry.databaseName
            let target = QuickSwitcherTarget(
                connectionId: baseTarget.connectionId,
                connectionName: baseTarget.connectionName,
                databaseName: databaseName,
                schemaName: nil,
                databaseDisplayName: databaseDisplayName(
                    databaseName,
                    pathFieldRole: baseTarget.pathFieldRole
                )
            )
            return QuickSwitcherItem(
                id: "history_\(entry.id.uuidString)",
                name: entry.queryPreview,
                kind: .queryHistory,
                subtitle: [connectionPath(for: target), entry.formattedExecutionTime]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                payload: entry.query,
                target: target
            )
        }

        return Array((favoriteItems + historyItems).prefix(QuickSwitcherRanking.maxResults))
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
        frecencyStore(for: item).recordAccess(itemId: item.id, at: date)
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
        let frecencyScores = frecencyStore.scores()
        let recentIds = frecencyStore.recentItemIds(limit: Self.recentLimit)
        filterTask = Task { @MainActor [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: Self.filterDebounceNanoseconds)
                guard !Task.isCancelled else { return }
            }
            let groups = query.isEmpty
                ? await Self.emptyQueryGroups(items: items, scope: scope, recentIds: recentIds)
                : await Self.filteredGroups(items: items, query: query, frecencyScores: frecencyScores)
            guard !Task.isCancelled, let self else { return }
            self.groups = groups
            self.reconcileSelection()
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

    private func reconcileSelection() {
        let items = flatItems
        if let current = selectedItemId, items.contains(where: { $0.id == current }) {
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
        recentIds: [String]
    ) async -> [Group] {
        let recentIdSet = Set(recentIds)
        let recentOrder = Dictionary(uniqueKeysWithValues: recentIds.enumerated().map { ($1, $0) })

        var result: [Group] = []

        let recent = items
            .filter { recentIdSet.contains($0.id) }
            .sorted { (recentOrder[$0.id] ?? 0) < (recentOrder[$1.id] ?? 0) }
        if !recent.isEmpty {
            result.append(Group(id: "recent", header: String(localized: "Recent"), items: recent))
        }

        if scope.usesCrossConnectionCatalog {
            return result + connectionGroups(items: items, excluding: recentIdSet)
        }

        guard scope != .all else { return result }

        for kind in QuickSwitcherItemKind.displayOrder {
            let kindItems = items
                .filter { $0.kind == kind && !recentIdSet.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !kindItems.isEmpty else { continue }
            result.append(Group(
                id: "kind-\(kind.rawValue)",
                header: kind.sectionTitle,
                items: Array(kindItems.prefix(QuickSwitcherRanking.maxResults))
            ))
        }
        return result
    }

    nonisolated private static func connectionGroups(
        items: [QuickSwitcherItem],
        excluding excludedIds: Set<String>
    ) -> [Group] {
        let excludedCount = items.lazy.filter { excludedIds.contains($0.id) }.count
        let availableCount = max(0, QuickSwitcherRanking.maxResults - excludedCount)
        let sortedItems = items
            .filter { !excludedIds.contains($0.id) }
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
        frecencyScores: [String: Double]
    ) async -> [Group] {
        var ranked = items.compactMap { item -> (item: QuickSwitcherItem, rank: Double)? in
            guard let (matchScore, matchedIndices) = bestMatch(for: item, query: query) else { return nil }
            var matched = item
            matched.matchedIndices = matchedIndices
            let frecency = 1 + (frecencyScores[item.id] ?? 0) * QuickSwitcherRanking.frecencyBoost
            let openBoost = item.isOpenInTab ? QuickSwitcherRanking.openTabBoost : 1
            return (matched, matchScore * item.kind.rankWeight * frecency * openBoost)
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            let lhsOrder = QuickSwitcherItemKind.displayOrder.firstIndex(of: lhs.item.kind) ?? Int.max
            let rhsOrder = QuickSwitcherItemKind.displayOrder.firstIndex(of: rhs.item.kind) ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let lhsLength = (lhs.item.name as NSString).length
            let rhsLength = (rhs.item.name as NSString).length
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }
        let items = Array(ranked.prefix(QuickSwitcherRanking.maxResults).map(\.item))
        guard !items.isEmpty else { return [] }
        return [Group(id: "results", header: nil, items: items)]
    }

    nonisolated private static func bestMatch(
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
        }
    }

    nonisolated private static func connectionPath(for target: QuickSwitcherTarget) -> String {
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
        .table, .view, .systemTable, .database, .schema, .savedQuery, .queryHistory
    ]

    var rankWeight: Double {
        switch self {
        case .table: return 1.0
        case .view: return 0.98
        case .systemTable: return 0.85
        case .database: return 0.95
        case .schema: return 0.93
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
        case .savedQuery: return String(localized: "Saved Queries")
        case .queryHistory: return String(localized: "Recent Queries")
        }
    }
}
