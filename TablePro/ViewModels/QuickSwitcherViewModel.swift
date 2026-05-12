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
        let id: String
        let header: String?
        let items: [QuickSwitcherItem]
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "QuickSwitcherViewModel")
    private static let mruDefaultsKeyPrefix = "QuickSwitcher.mru."
    private static let mruLimit = 10
    private static let maxResults = 200
    private static let filterDebounceNanoseconds: UInt64 = 40_000_000

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connectionId: UUID

    @ObservationIgnored internal var allItems: [QuickSwitcherItem] = [] {
        didSet { applyFilter() }
    }
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadId = UUID()

    private(set) var groups: [Group] = []
    private(set) var isLoading = false
    var selectedItemId: String?

    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleFilter()
        }
    }

    var flatItems: [QuickSwitcherItem] {
        groups.flatMap(\.items)
    }

    init(connectionId: UUID, services: AppServices, defaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.services = services
        self.defaults = defaults
    }

    convenience init(connectionId: UUID = UUID()) {
        self.init(connectionId: connectionId, services: .live)
    }

    func loadItems(
        schemaProvider: SQLSchemaProvider,
        databaseType: DatabaseType
    ) async {
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
        groups = trimmed.isEmpty
            ? buildEmptyQueryGroups()
            : buildFilteredGroups(for: trimmed)
        let items = flatItems
        if let current = selectedItemId, items.contains(where: { $0.id == current }) {
            return
        }
        selectedItemId = items.first?.id
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
            result.append(Group(id: "recent", header: String(localized: "Recent"), items: recent))
        }

        for kind in QuickSwitcherItemKind.displayOrder {
            let items = allItems
                .filter { $0.kind == kind && !mruIds.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !items.isEmpty else { continue }
            result.append(Group(
                id: "kind-\(kind.rawValue)",
                header: kind.sectionTitle,
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
            let lOrder = QuickSwitcherItemKind.displayOrder.firstIndex(of: lhs.0.kind) ?? Int.max
            let rOrder = QuickSwitcherItemKind.displayOrder.firstIndex(of: rhs.0.kind) ?? Int.max
            if lOrder != rOrder { return lOrder < rOrder }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }
        let items = Array(scored.prefix(Self.maxResults).map(\.0))
        guard !items.isEmpty else { return [] }
        return [Group(id: "results", header: nil, items: items)]
    }

    private var mruKey: String {
        Self.mruDefaultsKeyPrefix + connectionId.uuidString
    }

    private func loadMRU() -> [String] {
        defaults.stringArray(forKey: mruKey) ?? []
    }
}

private extension QuickSwitcherItemKind {
    static let displayOrder: [QuickSwitcherItemKind] = [
        .table, .view, .systemTable, .database, .schema, .queryHistory
    ]

    var sectionTitle: String {
        switch self {
        case .table: return String(localized: "Tables")
        case .view: return String(localized: "Views")
        case .systemTable: return String(localized: "System Tables")
        case .database: return String(localized: "Databases")
        case .schema: return String(localized: "Schemas")
        case .queryHistory: return String(localized: "Recent Queries")
        }
    }
}
