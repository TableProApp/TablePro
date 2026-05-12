//
//  QuickSwitcherViewModel.swift
//  TablePro
//

import Foundation
import Observation
import os

@MainActor
@Observable
internal final class QuickSwitcherViewModel {
    struct Group: Identifiable {
        let kind: QuickSwitcherItemKind
        let isRecent: Bool
        let items: [QuickSwitcherItem]

        var id: String {
            isRecent ? "recent" : "kind-\(kind.rawValue)"
        }
    }

    @ObservationIgnored private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "QuickSwitcherViewModel"
    )
    @ObservationIgnored private static let mruDefaultsKeyPrefix = "QuickSwitcher.mru."
    @ObservationIgnored private static let mruLimit = 10
    @ObservationIgnored private static let maxResults = 200
    @ObservationIgnored private static let filterDebounceNanoseconds: UInt64 = 40_000_000

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var allItems: [QuickSwitcherItem] = []
    @ObservationIgnored private var connectionId = UUID()
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadId = UUID()

    private(set) var groups: [Group] = []
    private(set) var flatItems: [QuickSwitcherItem] = []
    private(set) var isLoading = false
    var selectedItemId: String?

    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleFilter()
        }
    }

    init(services: AppServices, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
    }

    convenience init() {
        self.init(services: .live)
    }

    func loadItems(
        schemaProvider: SQLSchemaProvider,
        connectionId: UUID,
        databaseType: DatabaseType
    ) async {
        self.connectionId = connectionId
        isLoading = true

        let loadId = UUID()
        activeLoadId = loadId

        var items: [QuickSwitcherItem] = []

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
                subtitle: subtitle
            ))
        }

        if let driver = services.databaseManager.driver(for: connectionId) {
            do {
                let databases = try await driver.fetchDatabases()
                for db in databases {
                    items.append(QuickSwitcherItem(
                        id: "db_\(db)",
                        name: db,
                        kind: .database,
                        subtitle: String(localized: "Database")
                    ))
                }
            } catch {
                Self.logger.warning("Failed to fetch databases: \(error.localizedDescription, privacy: .public)")
            }

            if services.pluginManager.supportsSchemaSwitching(for: databaseType) {
                do {
                    let schemas = try await driver.fetchSchemas()
                    for schema in schemas {
                        items.append(QuickSwitcherItem(
                            id: "schema_\(schema)",
                            name: schema,
                            kind: .schema,
                            subtitle: String(localized: "Schema")
                        ))
                    }
                } catch {
                    Self.logger.warning("Failed to fetch schemas: \(error.localizedDescription, privacy: .public)")
                }
            }
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
                subtitle: entry.databaseName
            ))
        }

        guard activeLoadId == loadId, !Task.isCancelled else { return }

        allItems = items
        isLoading = false
        applyFilter()
    }

    func selectedItem() -> QuickSwitcherItem? {
        guard let id = selectedItemId else { return nil }
        return flatItems.first { $0.id == id }
    }

    func moveSelection(by delta: Int) {
        guard !flatItems.isEmpty else {
            selectedItemId = nil
            return
        }
        if let id = selectedItemId, let index = flatItems.firstIndex(where: { $0.id == id }) {
            let next = max(0, min(flatItems.count - 1, index + delta))
            selectedItemId = flatItems[next].id
        } else {
            selectedItemId = flatItems.first?.id
        }
    }

    func recordSelection(_ item: QuickSwitcherItem) {
        var mru = loadMRU()
        mru.removeAll { $0 == item.id }
        mru.insert(item.id, at: 0)
        if mru.count > Self.mruLimit {
            mru = Array(mru.prefix(Self.mruLimit))
        }
        defaults.set(mru, forKey: mruKey)
    }

    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.filterDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.applyFilter()
        }
    }

    private func applyFilter() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            groups = buildEmptyQueryGroups()
        } else {
            groups = buildFilteredGroups(for: trimmed)
        }
        flatItems = groups.flatMap(\.items)
        if let current = selectedItemId, flatItems.contains(where: { $0.id == current }) {
            return
        }
        selectedItemId = flatItems.first?.id
    }

    private func buildEmptyQueryGroups() -> [Group] {
        let mruList = loadMRU()
        let mruIds = Set(mruList)
        let mruOrder = Dictionary(uniqueKeysWithValues: mruList.enumerated().map { ($1, $0) })

        var result: [Group] = []

        let recent = allItems
            .filter { mruIds.contains($0.id) }
            .sorted { (mruOrder[$0.id] ?? 0) < (mruOrder[$1.id] ?? 0) }
        if !recent.isEmpty {
            result.append(Group(kind: .table, isRecent: true, items: recent))
        }

        let kindsOrder: [QuickSwitcherItemKind] = [.table, .view, .systemTable, .database, .schema, .queryHistory]
        for kind in kindsOrder {
            let items = allItems
                .filter { $0.kind == kind && !mruIds.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !items.isEmpty else { continue }
            result.append(Group(
                kind: kind,
                isRecent: false,
                items: Array(items.prefix(Self.maxResults))
            ))
        }
        return result
    }

    private func buildFilteredGroups(for query: String) -> [Group] {
        var scored = allItems.compactMap { item -> (QuickSwitcherItem, Int)? in
            let score = FuzzyMatcher.score(query: query, candidate: item.name)
            guard score > 0 else { return nil }
            return (item, score)
        }
        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let lOrder = kindSortOrder(lhs.0.kind)
            let rOrder = kindSortOrder(rhs.0.kind)
            if lOrder != rOrder { return lOrder < rOrder }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }
        let items = Array(scored.prefix(Self.maxResults).map(\.0))
        guard !items.isEmpty else { return [] }
        return [Group(kind: .table, isRecent: false, items: items)]
    }

    private func kindSortOrder(_ kind: QuickSwitcherItemKind) -> Int {
        switch kind {
        case .table: return 0
        case .view: return 1
        case .systemTable: return 2
        case .database: return 3
        case .schema: return 4
        case .queryHistory: return 5
        }
    }

    private var mruKey: String {
        Self.mruDefaultsKeyPrefix + connectionId.uuidString
    }

    private func loadMRU() -> [String] {
        defaults.stringArray(forKey: mruKey) ?? []
    }
}
