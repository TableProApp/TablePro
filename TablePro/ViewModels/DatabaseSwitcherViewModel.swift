//
//  DatabaseSwitcherViewModel.swift
//  TablePro
//
//  ViewModel for DatabaseSwitcherSheet.
//  Handles database fetching, metadata loading, recent tracking, and switching logic.
//

import Foundation
import Observation
import os
import SwiftUI

@MainActor @Observable
final class DatabaseSwitcherViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseSwitcherViewModel")

    // MARK: - Mode

    enum Mode: Hashable {
        case database
        case schema
    }

    // MARK: - Published State

    var databases: [DatabaseMetadata] = []
    var searchText = "" {
        didSet { selectedDatabase = filteredDatabases.first?.name }
    }
    var selectedDatabase: String?
    var isLoading = false
    var errorMessage: String?
    var showPreview = false
    var mode: Mode

    /// Whether we're switching schemas (Redshift or PostgreSQL in schema mode)
    var isSchemaMode: Bool { mode == .schema }

    // MARK: - Dependencies

    private let connectionId: UUID
    private let currentDatabase: String?
    private let currentSchema: String?
    private let databaseType: DatabaseType

    // MARK: - Computed Properties

    var filteredDatabases: [DatabaseMetadata] {
        if searchText.isEmpty {
            return databases
        }
        return databases.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Initialization

    init(
        connectionId: UUID, currentDatabase: String?, currentSchema: String?,
        databaseType: DatabaseType
    ) {
        self.connectionId = connectionId
        self.currentDatabase = currentDatabase
        self.currentSchema = currentSchema
        self.databaseType = databaseType
        self.mode = PluginManager.shared.supportsSchemaSwitching(for: databaseType) ? .schema : .database
    }

    // MARK: - Public Methods

    /// Fetch databases (or schemas for Redshift) and their metadata
    func fetchDatabases() async {
        isLoading = true
        errorMessage = nil

        do {
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                errorMessage = String(localized: "No active connection")
                isLoading = false
                return
            }

            if isSchemaMode {
                // Redshift: fetch schemas instead of databases
                let schemaNames = try await driver.fetchSchemas()
                databases = schemaNames.map { name in
                    DatabaseMetadata.minimal(name: name, isSystem: isSystemItem(name))
                }
            } else {
                // MySQL/MariaDB/PostgreSQL: fetch databases with metadata
                // Show database names immediately, then load metadata
                let dbNames = try await driver.fetchDatabases()
                databases = dbNames.sorted().map { name in
                    DatabaseMetadata.minimal(name: name, isSystem: isSystemItem(name))
                }

                // Pre-select before metadata loads so the UI is interactive immediately
                preselectDatabase()

                // Fetch all metadata in a single batched query
                isLoading = false
                do {
                    let metadataList = try await driver.fetchAllDatabaseMetadata()
                    databases = metadataList.sorted { $0.name < $1.name }
                    preselectDatabase()
                } catch {
                    Self.logger.error("Failed to fetch database metadata: \(error)")
                }
                return
            }

            isLoading = false

            // Pre-select current database/schema or first item
            let current = isSchemaMode ? currentSchema : currentDatabase
            if let current, databases.contains(where: { $0.name == current }) {
                selectedDatabase = current
            } else {
                selectedDatabase = databases.first?.name
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Refresh database list
    func refreshDatabases() async {
        await fetchDatabases()
    }

    /// Create a new database
    func createDatabase(name: String, charset: String, collation: String?) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        try await driver.createDatabase(name: name, charset: charset, collation: collation)
    }

    // MARK: - Keyboard Navigation

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

    // MARK: - Private Methods

    private func preselectDatabase() {
        if let current = currentDatabase, databases.contains(where: { $0.name == current }) {
            selectedDatabase = current
        } else {
            selectedDatabase = databases.first?.name
        }
    }

    private func isSystemItem(_ name: String) -> Bool {
        if isSchemaMode {
            let schemaNames = PluginManager.shared.systemSchemaNames(for: databaseType)
            return schemaNames.contains(name)
        }
        let dbNames = PluginManager.shared.systemDatabaseNames(for: databaseType)
        return dbNames.contains(name)
    }
}
