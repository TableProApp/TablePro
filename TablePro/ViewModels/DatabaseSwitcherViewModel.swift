//
//  DatabaseSwitcherViewModel.swift
//  TablePro
//

import Foundation
import Observation
import os
import SwiftUI

@MainActor @Observable
final class DatabaseSwitcherViewModel {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseSwitcherViewModel")

    var databases: [DatabaseMetadata] = []
    var searchText = "" {
        didSet { selectedDatabase = filteredDatabases.first?.name }
    }
    var selectedDatabases: Set<String> = []

    /// The keyboard path (arrows, Return) drives one row at a time, so it reads and
    /// writes the selection as a single value while the mouse can extend it.
    var selectedDatabase: String? {
        get { selectedDatabases.count == 1 ? selectedDatabases.first : nil }
        set { selectedDatabases = newValue.map { [$0] } ?? [] }
    }
    var isLoading = false
    var errorMessage: String?
    var showPreview = false

    let switchTarget: ContainerSwitchTarget

    private let connectionId: UUID
    private let currentDatabase: String?
    private let databaseType: DatabaseType
    @ObservationIgnored private let services: AppServices
    private let sidebarState: SharedSidebarState?
    @ObservationIgnored private var hasLoadedOnce = false
    @ObservationIgnored private var loadToken: UUID?

    private var treeVisibleDatabases: [DatabaseMetadata] {
        guard switchTarget == .database else { return databases }
        return DatabaseTreeVisibility.visible(
            databases: databases,
            selected: sidebarState?.databaseFilterSelected ?? [],
            activeDatabase: currentDatabase
        )
    }

    var filteredDatabases: [DatabaseMetadata] {
        let visible = treeVisibleDatabases
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return visible }
        return visible
            .compactMap { database -> (DatabaseMetadata, Int)? in
                guard let match = FuzzyMatcher.match(query: trimmed, candidate: database.name) else { return nil }
                return (database, match.score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    init(
        connectionId: UUID,
        currentDatabase: String?,
        databaseType: DatabaseType,
        switchTarget: ContainerSwitchTarget? = nil,
        services: AppServices = .live,
        sidebarState: SharedSidebarState? = nil
    ) {
        self.connectionId = connectionId
        self.currentDatabase = currentDatabase
        self.databaseType = databaseType
        self.services = services
        self.sidebarState = sidebarState
        self.switchTarget = switchTarget
            ?? services.pluginManager.containerSwitchTarget(for: databaseType)
            ?? .database
    }

    /// A refresh never blanks the list it is refreshing, and a failed one never replaces data the
    /// popover is still showing. Only a load that has nothing to fall back on reports either state.
    func fetchDatabases() async {
        let token = UUID()
        loadToken = token
        if !hasLoadedOnce {
            isLoading = true
        }

        do {
            let target = switchTarget
            let names = try await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { driver in
                switch target {
                case .database: try await driver.fetchDatabases()
                case .schema: try await driver.fetchSchemas()
                }
            }
            guard loadToken == token else { return }
            applyFetched(names.sorted().map { DatabaseMetadata.minimal(name: $0, isSystem: isSystemItem($0)) })

            guard switchTarget == .database else { return }
            do {
                let metadataList = try await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId, workload: .bulk) { driver in
                    try await driver.fetchAllDatabaseMetadata()
                }
                guard loadToken == token else { return }
                applyFetched(metadataList.sorted { $0.name < $1.name })
            } catch {
                Self.logger.error("Failed to fetch database metadata: \(error)")
            }
        } catch {
            guard loadToken == token else { return }
            isLoading = false
            guard !hasLoadedOnce else {
                Self.logger.error("Failed to refresh databases: \(error)")
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func applyFetched(_ metadata: [DatabaseMetadata]) {
        databases = metadata
        hasLoadedOnce = true
        errorMessage = nil
        isLoading = false
        reconcileSelection()
    }

    func refreshDatabases() async {
        await fetchDatabases()
    }

    func loadCreateDatabaseForm() async throws -> CreateDatabaseFormSpec? {
        guard let driver = services.databaseManager.driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        return try await driver.createDatabaseFormSpec()
    }

    func createDatabase(name: String, values: [String: String]) async throws {
        guard let driver = services.databaseManager.driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        let request = CreateDatabaseRequest(name: name, values: values)
        try await driver.createDatabase(request)
    }

    /// The selected row the keyboard acts from, in the order the list shows them.
    var primarySelection: String? {
        filteredDatabases.first { selectedDatabases.contains($0.name) }?.name
    }

    var selectedMetadata: [DatabaseMetadata] {
        filteredDatabases.filter { selectedDatabases.contains($0.name) }
    }

    func moveUp() {
        let items = filteredDatabases
        guard !items.isEmpty else { return }
        guard let current = primarySelection,
              let index = items.firstIndex(where: { $0.name == current }),
              index > 0
        else { return }
        selectedDatabase = items[index - 1].name
    }

    func moveDown() {
        let items = filteredDatabases
        guard !items.isEmpty else { return }
        if let current = primarySelection,
           let index = items.firstIndex(where: { $0.name == current }),
           index < items.count - 1
        {
            selectedDatabase = items[index + 1].name
        } else if primarySelection == nil {
            selectedDatabase = items.first?.name
        }
    }

    /// A selection the user made outlives a refresh. The slow bulk metadata pass lands well after
    /// the list is interactive, so resetting the selection there took the row out from under them.
    private func reconcileSelection() {
        selectedDatabases.formIntersection(Set(filteredDatabases.map(\.name)))
        guard selectedDatabases.isEmpty else { return }
        preselectDatabase()
    }

    /// The selection has to be a row the list actually shows, because `primarySelection` and the
    /// arrow keys all resolve it through `filteredDatabases`. Preselecting a hidden row left Return
    /// doing nothing at all.
    private func preselectDatabase() {
        let items = filteredDatabases
        if let current = currentDatabase, items.contains(where: { $0.name == current }) {
            selectedDatabase = current
        } else {
            selectedDatabase = items.first?.name
        }
    }

    private func isSystemItem(_ name: String) -> Bool {
        switch switchTarget {
        case .database: services.pluginManager.systemDatabaseNames(for: databaseType).contains(name)
        case .schema: services.pluginManager.systemSchemaNames(for: databaseType).contains(name)
        }
    }
}
