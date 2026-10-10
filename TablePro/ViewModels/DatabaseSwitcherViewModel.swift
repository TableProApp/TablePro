//
//  DatabaseSwitcherViewModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import SwiftUI

@MainActor
final class DatabaseSwitcherViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseSwitcherViewModel")

    @Published var databases: [DatabaseMetadata] = []
    @Published var searchText = "" {
        didSet { selectedDatabase = filteredDatabases.first?.name }
    }
    @Published var selectedDatabases: Set<String> = []

    /// The keyboard path (arrows, Return) drives one row at a time, so it reads and
    /// writes the selection as a single value while the mouse can extend it.
    var selectedDatabase: String? {
        get { selectedDatabases.count == 1 ? selectedDatabases.first : nil }
        set { selectedDatabases = newValue.map { [$0] } ?? [] }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showPreview = false

    let switchTarget: ContainerSwitchTarget

    private let connectionId: UUID
    private let currentDatabase: String?
    /// A schema name means something only inside one database, so schema mode reads the schema
    /// filter of the database its rows belong to. Nil leaves schema mode unfiltered.
    private let activeDatabase: String?
    private let databaseType: DatabaseType
    private let services: AppServices
    private let sidebarState: SharedSidebarState?
    private let keptSchemas: @MainActor (UUID, String) -> Set<String>?
    private var hasLoadedOnce = false
    private var loadToken: UUID?

    private var listedSections: DatabaseSwitchSections {
        DatabaseSwitchList.sections(
            databases: databases,
            selected: sidebarFilterSelection,
            activeDatabase: currentDatabase
        )
    }

    private var sidebarFilterSelection: Set<String> {
        switch switchTarget {
        case .database:
            return sidebarState?.databaseFilterSelected ?? []
        case .schema:
            guard let activeDatabase else { return [] }
            return keptSchemas(connectionId, activeDatabase) ?? []
        }
    }

    /// A search ranks within each section rather than across them, so a system database never
    /// outranks a user database on screen while the arrow keys walk the same order.
    var visibleSections: DatabaseSwitchSections {
        let listed = listedSections
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return listed }
        return DatabaseSwitchSections(
            user: Self.ranked(listed.user, matching: trimmed),
            system: Self.ranked(listed.system, matching: trimmed)
        )
    }

    var filteredDatabases: [DatabaseMetadata] {
        visibleSections.all
    }

    init(
        connectionId: UUID,
        currentDatabase: String?,
        databaseType: DatabaseType,
        switchTarget: ContainerSwitchTarget? = nil,
        activeDatabase: String? = nil,
        services: AppServices = .live,
        sidebarState: SharedSidebarState? = nil,
        keptSchemas: @escaping @MainActor (UUID, String) -> Set<String>? = { connectionId, database in
            SidebarSchemaFilter().keptSchemas(connectionId: connectionId, database: database)
        }
    ) {
        self.connectionId = connectionId
        self.currentDatabase = currentDatabase
        self.activeDatabase = activeDatabase
        self.databaseType = databaseType
        self.services = services
        self.sidebarState = sidebarState
        self.keptSchemas = keptSchemas
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
            let systemNames = services.pluginManager.systemContainerNames(for: databaseType, target: target)
            applyFetched(names.sorted().map { DatabaseMetadata.minimal(name: $0, isSystem: systemNames.contains($0)) })
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

    /// Through the container DDL path, like every other write. It used to call the driver straight
    /// from here, so a read-only connection still offered the row and Safe Mode's confirmation and
    /// Touch ID tiers never fired. The driver creates the database itself on the engines whose
    /// create is not a statement, so the gate is given the description rather than SQL.
    func createDatabase(name: String, values: [String: String]) async throws {
        guard let scope = services.databaseManager.resolvedScope(
            database: nil, schema: nil, for: connectionId
        ) else {
            throw DatabaseError.notConnected
        }
        let request = CreateDatabaseRequest(name: name, values: values)
        let entity = services.pluginManager.containerEntityName(for: databaseType)
        try await services.databaseManager.runContainerOperation(
            description: String(format: String(localized: "Create %1$@ \"%2$@\""), entity, name),
            kind: .schemaMutation,
            scope: scope,
            databaseType: databaseType,
            event: .changed(CatalogChange(connectionId: connectionId, kinds: .databases))
        ) { driver in
            try await driver.createDatabase(request)
        }
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

    /// A refresh can land after the user moved the selection, so it keeps theirs.
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

    private static func ranked(_ databases: [DatabaseMetadata], matching query: String) -> [DatabaseMetadata] {
        databases
            .compactMap { database -> (DatabaseMetadata, Int)? in
                guard let match = FuzzyMatcher.match(query: query, candidate: database.name) else { return nil }
                return (database, match.score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
            }
            .map(\.0)
    }
}
