//
//  QuickSwitcherViewModel.swift
//  TablePro
//
//  ViewModel for the quick switcher palette
//

import Foundation
import Observation
import os

/// ViewModel managing quick switcher search, filtering, and keyboard navigation
@MainActor @Observable
internal final class QuickSwitcherViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QuickSwitcherViewModel")

    // MARK: - State

    var searchText = "" {
        didSet { updateFilter() }
    }

    var allItems: [QuickSwitcherItem] = [] {
        didSet { applyFilter() }
    }
    private(set) var filteredItems: [QuickSwitcherItem] = []
    var selectedItemId: String?
    var isLoading = false

    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadId = UUID()

    /// Maximum number of results to display
    private let maxResults = 100

    // MARK: - Loading

    /// Load all searchable items from the database schema, databases, schemas, and history
    func loadItems(
        schemaProvider: SQLSchemaProvider,
        connectionId: UUID,
        databaseType: DatabaseType
    ) async {
        isLoading = true
        let loadId = UUID()
        activeLoadId = loadId
        var items: [QuickSwitcherItem] = []

        // Tables, views, system tables from cached schema
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

        // Databases
        if let driver = DatabaseManager.shared.driver(for: connectionId) {
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
                Self.logger.debug("Failed to fetch databases for quick switcher: \(error.localizedDescription, privacy: .public)")
            }

            // Schemas (only for databases that support them)
            let supportsSchemas = [DatabaseType.postgresql, .redshift, .oracle, .mssql]
            if supportsSchemas.contains(databaseType) {
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
                    Self.logger.debug("Failed to fetch schemas for quick switcher: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Recent query history (last 50)
        let historyEntries = await QueryHistoryStorage.shared.fetchHistory(
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

        guard activeLoadId == loadId, !Task.isCancelled else {
            isLoading = false
            return
        }

        allItems = items
        isLoading = false
    }

    // MARK: - Filtering

    /// Debounced filter update
    func updateFilter() {
        filterTask?.cancel()
        filterTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            applyFilter()
        }
    }

    private func applyFilter() {
        if searchText.isEmpty {
            // Show all items grouped by kind: tables, views, system tables, databases, schemas, history
            filteredItems = allItems.sorted { a, b in
                let aOrder = kindSortOrder(a.kind)
                let bOrder = kindSortOrder(b.kind)
                if aOrder != bOrder { return aOrder < bOrder }
                return a.name < b.name
            }
            if filteredItems.count > maxResults {
                filteredItems = Array(filteredItems.prefix(maxResults))
            }
        } else {
            filteredItems = allItems.compactMap { item in
                let matchScore = FuzzyMatcher.score(query: searchText, candidate: item.name)
                guard matchScore > 0 else { return nil }
                var scored = item
                scored.score = matchScore
                return scored
            }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                let aOrder = kindSortOrder(a.kind)
                let bOrder = kindSortOrder(b.kind)
                if aOrder != bOrder { return aOrder < bOrder }
                return a.name < b.name
            }

            if filteredItems.count > maxResults {
                filteredItems = Array(filteredItems.prefix(maxResults))
            }
        }

        selectedItemId = filteredItems.first?.id
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

    // MARK: - Navigation

    func moveUp() {
        guard let currentId = selectedItemId,
              let currentIndex = filteredItems.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0
        else { return }
        selectedItemId = filteredItems[currentIndex - 1].id
    }

    func moveDown() {
        guard let currentId = selectedItemId,
              let currentIndex = filteredItems.firstIndex(where: { $0.id == currentId }),
              currentIndex < filteredItems.count - 1
        else { return }
        selectedItemId = filteredItems[currentIndex + 1].id
    }

    var selectedItem: QuickSwitcherItem? {
        guard let selectedItemId else { return nil }
        return filteredItems.first { $0.id == selectedItemId }
    }

    /// Items grouped by kind for sectioned display
    var groupedItems: [(kind: QuickSwitcherItemKind, items: [QuickSwitcherItem])] {
        var groups: [QuickSwitcherItemKind: [QuickSwitcherItem]] = [:]
        for item in filteredItems {
            groups[item.kind, default: []].append(item)
        }
        return groups.sorted { kindSortOrder($0.key) < kindSortOrder($1.key) }
            .map { (kind: $0.key, items: $0.value) }
    }
}
