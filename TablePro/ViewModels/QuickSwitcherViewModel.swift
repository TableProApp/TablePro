//
//  QuickSwitcherViewModel.swift
//  TablePro
//

import Foundation
import Observation
import os

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
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadId = UUID()

    private(set) var groups: [Group] = []
    private(set) var isLoading = true
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
            let kind: QuickSwitcherItemKind
            let subtitle: String
            switch table.type {
            case .table:
                kind = .table
                subtitle = ""
            case .view:
                kind = .view
                subtitle = String(localized: "View")
            case .materializedView:
                kind = .view
                subtitle = String(localized: "Materialized View")
            case .foreignTable:
                kind = .table
                subtitle = String(localized: "Foreign Table")
            case .systemTable:
                kind = .systemTable
                subtitle = String(localized: "System")
            }
            items.append(QuickSwitcherItem(
                id: "table_\(table.name)_\(table.type.rawValue)",
                name: table.name,
                kind: kind,
                subtitle: subtitle,
                isOpenInTab: openTableNames.contains(table.name)
            ))
        }

        let switchTarget = services.pluginManager.containerSwitchTarget(for: databaseType)
        let databaseFilter = SharedSidebarState.forConnection(connectionId).databaseFilterSelected
        let visibleDatabaseNames = switchTarget == .database
            ? Set(
                DatabaseTreeVisibility.visible(
                    databases: DatabaseTreeMetadataService.shared.databases(for: connectionId),
                    selected: databaseFilter
                ).map(\.name)
            )
            : []
        do {
            let databases = try await services.databaseManager.withMetadataDriver(connectionId: connectionId) { driver in
                try await driver.fetchDatabases()
            }
            let databaseSubtitle = switchTarget == .database
                ? services.pluginManager.containerEntityName(for: databaseType)
                : String(localized: "Database")
            for db in databases {
                if switchTarget == .database {
                    if !visibleDatabaseNames.isEmpty {
                        if !visibleDatabaseNames.contains(db) { continue }
                    } else if !databaseFilter.isEmpty, !databaseFilter.contains(db) {
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
                let schemas = try await services.databaseManager.withMetadataDriver(connectionId: connectionId) { driver in
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
