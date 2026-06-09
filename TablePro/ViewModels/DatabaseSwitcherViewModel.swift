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
    private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseSwitcherViewModel")

    var databases: [DatabaseMetadata] = []
    var searchText = "" {
        didSet { selectedDatabase = filteredDatabases.first?.name }
    }
    var selectedDatabase: String?
    var isLoading = false
    var errorMessage: String?
    var showPreview = false

    private let connectionId: UUID
    private let currentDatabase: String?
    private let databaseType: DatabaseType
    @ObservationIgnored private let services: AppServices

    var filteredDatabases: [DatabaseMetadata] {
        if searchText.isEmpty {
            return databases
        }
        return databases.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    init(
        connectionId: UUID,
        currentDatabase: String?,
        databaseType: DatabaseType,
        services: AppServices = .live
    ) {
        self.connectionId = connectionId
        self.currentDatabase = currentDatabase
        self.databaseType = databaseType
        self.services = services
    }

    func fetchDatabases() async {
        isLoading = true
        errorMessage = nil

        do {
            let dbNames = try await services.databaseManager.withMetadataDriver(connectionId: connectionId) { driver in
                try await driver.fetchDatabases()
            }
            databases = dbNames.sorted().map { name in
                DatabaseMetadata.minimal(name: name, isSystem: isSystemItem(name))
            }

            preselectDatabase()

            isLoading = false
            do {
                let metadataList = try await services.databaseManager.withMetadataDriver(connectionId: connectionId, workload: .bulk) { driver in
                    try await driver.fetchAllDatabaseMetadata()
                }
                databases = metadataList.sorted { $0.name < $1.name }
                preselectDatabase()
            } catch {
                Self.logger.error("Failed to fetch database metadata: \(error)")
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
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

    func dropDatabase(name: String) async throws {
        guard let driver = services.databaseManager.driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        try await driver.dropDatabase(name: name)
    }

    func moveUp() {
        let items = filteredDatabases
        guard !items.isEmpty else { return }
        guard let current = selectedDatabase,
              let index = items.firstIndex(where: { $0.name == current }),
              index > 0
        else { return }
        selectedDatabase = items[index - 1].name
    }

    func moveDown() {
        let items = filteredDatabases
        guard !items.isEmpty else { return }
        if let current = selectedDatabase,
           let index = items.firstIndex(where: { $0.name == current }),
           index < items.count - 1
        {
            selectedDatabase = items[index + 1].name
        } else if selectedDatabase == nil {
            selectedDatabase = items.first?.name
        }
    }

    private func preselectDatabase() {
        if let current = currentDatabase, databases.contains(where: { $0.name == current }) {
            selectedDatabase = current
        } else {
            selectedDatabase = databases.first?.name
        }
    }

    private func isSystemItem(_ name: String) -> Bool {
        services.pluginManager.systemDatabaseNames(for: databaseType).contains(name)
    }
}
