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
    @ObservationIgnored private let frecencyStore: QuickSwitcherFrecencyStore

    @ObservationIgnored internal var allItems: [QuickSwitcherItem] = [] {
        didSet { scheduleFilter(debounced: false) }
    }
    @ObservationIgnored internal var crossConnectionItems: [QuickSwitcherItem] = [] {
        didSet { scheduleFilter(debounced: false) }
    }
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadId = UUID()
    @ObservationIgnored private var activeCrossConnectionLoadId = UUID()
    @ObservationIgnored private var loadedCrossConnectionVersion: Int?

    private(set) var groups: [Group] = []
    private(set) var isLoading = true
    private(set) var isLoadingCrossConnections = false
    var selectedItemId: String?

    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            selectedItemId = nil
            scheduleFilter(debounced: true)
        }
    }

    var scope: QuickSwitcherScope = .all {
        didSet {
            guard oldValue != scope else { return }
            selectedItemId = nil
            scheduleFilter(debounced: false)
        }
    }

    var flatItems: [QuickSwitcherItem] {
        groups.flatMap(\.items)
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

    func loadCrossConnectionItems() async {
        let version = services.databaseManager.connectionStatusVersion
        guard loadedCrossConnectionVersion != version else { return }

        let loadId = UUID()
        activeCrossConnectionLoadId = loadId
        isLoadingCrossConnections = true
        defer {
            if activeCrossConnectionLoadId == loadId {
                isLoadingCrossConnections = false
            }
        }

        let sessions = services.databaseManager.activeSessions.values
            .filter { $0.isConnected && $0.driver != nil }
            .sorted { lhs, rhs in
                lhs.connection.name.localizedStandardCompare(rhs.connection.name) == .orderedAscending
            }
        var items: [QuickSwitcherItem] = []

        for session in sessions {
            guard !Task.isCancelled else { return }
            guard let driver = session.driver else { continue }

            var tables = services.schemaService.allLoadedTables(for: session.id)
            if tables.isEmpty {
                let provider = services.schemaProviderRegistry.getOrCreate(for: session.id)
                if await !provider.isSchemaLoaded() {
                    await provider.loadSchema(using: driver, connection: session.connection)
                }
                tables = await provider.getTables()
            }

            guard let currentSession = services.databaseManager.session(for: session.id),
                  currentSession.isConnected,
                  currentSession.resolvedBrowseDatabase == session.resolvedBrowseDatabase,
                  currentSession.browseSchema == session.browseSchema else { continue }

            let databaseName = session.resolvedBrowseDatabase.isEmpty ? nil : session.resolvedBrowseDatabase
            let schemaName = session.browseSchema?.isEmpty == false ? session.browseSchema : nil
            let target = QuickSwitcherObjectTarget(
                connectionId: session.id,
                connectionName: session.connection.name,
                databaseName: databaseName,
                schemaName: schemaName,
                databaseDisplayName: Self.databaseDisplayName(
                    databaseName,
                    pathFieldRole: session.connection.type.pathFieldRole
                )
            )
            items.append(contentsOf: Self.makeCrossConnectionItems(tables: tables, target: target))
        }

        guard activeCrossConnectionLoadId == loadId, !Task.isCancelled else { return }
        loadedCrossConnectionVersion = version
        crossConnectionItems = items
    }

    nonisolated static func makeCrossConnectionItems(
        tables: [TableInfo],
        target: QuickSwitcherObjectTarget
    ) -> [QuickSwitcherItem] {
        tables.map { table in
            let presentation = tablePresentation(for: table.type)
            let resolvedTarget = QuickSwitcherObjectTarget(
                connectionId: target.connectionId,
                connectionName: target.connectionName,
                databaseName: target.databaseName,
                schemaName: table.schema ?? target.schemaName,
                databaseDisplayName: target.databaseDisplayName
            )
            return QuickSwitcherItem(
                id: "connection_\(target.connectionId.uuidString)_\(table.id)",
                name: table.name,
                kind: presentation.kind,
                subtitle: objectPath(for: resolvedTarget),
                isReadOnly: !table.type.allowsRowEditing,
                objectTarget: resolvedTarget
            )
        }
    }

    func canOpenStructure(_ item: QuickSwitcherItem) -> Bool {
        guard let target = item.objectTarget else { return true }
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
        frecencyStore.recordAccess(itemId: item.id, at: date)
    }

    private func scheduleFilter(debounced: Bool) {
        filterTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            filterTask = nil
            groups = buildEmptyQueryGroups()
            reconcileSelection()
            return
        }
        let items = scopedItems()
        let frecencyScores = frecencyStore.scores()
        filterTask = Task { @MainActor [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: Self.filterDebounceNanoseconds)
                guard !Task.isCancelled else { return }
            }
            let groups = await Self.filteredGroups(items: items, query: query, frecencyScores: frecencyScores)
            guard !Task.isCancelled, let self else { return }
            self.groups = groups
            self.reconcileSelection()
        }
    }

    private func reconcileSelection() {
        let items = flatItems
        if let current = selectedItemId, items.contains(where: { $0.id == current }) {
            return
        }
        selectedItemId = items.first?.id
    }

    private func scopedItems() -> [QuickSwitcherItem] {
        if scope == .connections {
            return crossConnectionItems
        }
        guard let includedKinds = scope.includedKinds else { return allItems }
        return allItems.filter { includedKinds.contains($0.kind) }
    }

    private func buildEmptyQueryGroups() -> [Group] {
        let scoped = scopedItems()
        let recentIds = frecencyStore.recentItemIds(limit: Self.recentLimit)
        let recentIdSet = Set(recentIds)
        let recentOrder = Dictionary(uniqueKeysWithValues: recentIds.enumerated().map { ($1, $0) })

        var result: [Group] = []

        let recent = scoped
            .filter { recentIdSet.contains($0.id) }
            .sorted { (recentOrder[$0.id] ?? 0) < (recentOrder[$1.id] ?? 0) }
        if !recent.isEmpty {
            result.append(Group(id: "recent", header: String(localized: "Recent"), items: recent))
        }

        if scope == .connections {
            return result + buildConnectionGroups(items: scoped, excluding: recentIdSet)
        }

        guard scope != .all else { return result }

        for kind in QuickSwitcherItemKind.displayOrder {
            let items = scoped
                .filter { $0.kind == kind && !recentIdSet.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !items.isEmpty else { continue }
            result.append(Group(
                id: "kind-\(kind.rawValue)",
                header: kind.sectionTitle,
                items: Array(items.prefix(QuickSwitcherRanking.maxResults))
            ))
        }
        return result
    }

    private func buildConnectionGroups(
        items: [QuickSwitcherItem],
        excluding excludedIds: Set<String>
    ) -> [Group] {
        let excludedCount = items.lazy.filter { excludedIds.contains($0.id) }.count
        let availableCount = max(0, QuickSwitcherRanking.maxResults - excludedCount)
        let sortedItems = items
            .filter { !excludedIds.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsConnection = lhs.objectTarget?.connectionName ?? ""
                let rhsConnection = rhs.objectTarget?.connectionName ?? ""
                let connectionOrder = lhsConnection.localizedStandardCompare(rhsConnection)
                if connectionOrder != .orderedSame { return connectionOrder == .orderedAscending }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(availableCount)

        var order: [UUID] = []
        var grouped: [UUID: [QuickSwitcherItem]] = [:]
        var names: [UUID: String] = [:]
        for item in sortedItems {
            guard let target = item.objectTarget else { continue }
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
        let subtitleWeight = item.kind == .savedQuery
            ? QuickSwitcherRanking.keywordMatchWeight
            : QuickSwitcherRanking.subtitleMatchPenalty
        var subtitleScore: Double?
        if !item.subtitle.isEmpty, let subtitleMatch = FuzzyMatcher.match(query: query, candidate: item.subtitle) {
            subtitleScore = Double(subtitleMatch.score) * subtitleWeight
        }

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

    nonisolated private static func objectPath(for target: QuickSwitcherObjectTarget) -> String {
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
