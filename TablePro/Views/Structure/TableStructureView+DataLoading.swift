//
//  TableStructureView+DataLoading.swift
//  TablePro
//
//  Data loading and lifecycle callbacks for table structure
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

// MARK: - Data Loading

extension TableStructureView {
    @Sendable
    func loadInitialData() async {
        await loadColumns()
        await loadTabDataIfNeeded(.indexes)
        await loadTabDataIfNeeded(.foreignKeys)
        loadSchemaForEditing()
        isInitialLoading = false
    }

    func loadColumns() async {
        isLoading = true
        errorMessage = nil

        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            errorMessage = String(localized: "Not connected")
            isLoading = false
            return
        }

        do {
            columns = try await driver.fetchColumns(table: tableName)
            loadedTabs.insert(.columns)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadTabDataIfNeeded(_ tab: StructureTab) async {
        guard !loadedTabs.contains(tab) else { return }
        await fetchTabData(tab)
    }

    func fetchTabData(_ tab: StructureTab) async {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return }

        do {
            switch tab {
            case .columns:
                columns = try await driver.fetchColumns(table: tableName)
            case .indexes:
                indexes = try await driver.fetchIndexes(table: tableName)
            case .foreignKeys:
                foreignKeys = try await driver.fetchForeignKeys(table: tableName)
            case .ddl:
                let sequences = try await driver.fetchDependentSequences(forTable: tableName)
                let enumTypes = try await driver.fetchDependentTypes(forTable: tableName)
                let baseDDL = try await driver.fetchTableDDL(table: tableName)
                if sequences.isEmpty && enumTypes.isEmpty {
                    ddlStatement = baseDDL
                } else {
                    var preamble = ""
                    for seq in sequences {
                        preamble += seq.ddl + "\n\n"
                    }
                    for enumType in enumTypes {
                        let quotedName = "\"\(enumType.name.replacingOccurrences(of: "\"", with: "\"\""))\""
                        let quotedLabels = enumType.labels.map { "'\(SQLEscaping.escapeStringLiteral($0))'" }
                        preamble += "CREATE TYPE \(quotedName) AS ENUM (\(quotedLabels.joined(separator: ", ")));\n"
                    }
                    ddlStatement = preamble + "\n" + baseDDL
                }
            case .parts:
                return
            }
            loadedTabs.insert(tab)
        } catch {
            Self.logger.error("Failed to load \(tab.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadSchemaForEditing() {
        let pkFromIndexes = indexes.first(where: { $0.isPrimary })?.columns ?? []
        let pkFromColumns = columns.filter { $0.isPrimaryKey }.map { $0.name }
        let primaryKey = pkFromIndexes.isEmpty ? pkFromColumns : pkFromIndexes

        structureChangeManager.loadSchema(
            tableName: tableName,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            primaryKey: primaryKey,
            databaseType: connection.type
        )
    }

    // MARK: - Lifecycle Callbacks

    func onSelectedTabChanged(_ new: StructureTab) {
        searchText = ""
        structureSortDescriptor = nil
        sortState = SortState()
        selectedRows = []
        displayVersion += 1
        Task {
            await loadTabDataIfNeeded(new)
        }
    }

    func onColumnsChanged() {
        guard !isReloadingAfterSave, !isInitialLoading else { return }
        loadSchemaForEditing()
    }

    func onIndexesChanged() {
        guard !isReloadingAfterSave, !isInitialLoading else { return }
        loadSchemaForEditing()
    }

    func onForeignKeysChanged() {
        guard !isReloadingAfterSave, !isInitialLoading else { return }
        loadSchemaForEditing()
    }

    func onRefreshData() {
        // Ignore refresh notifications while we're in the middle of our own save/reload
        guard !isReloadingAfterSave else {
            Self.logger.debug("Ignoring refresh notification - currently reloading after save")
            return
        }

        // Skip warning if we just saved (within 2 seconds)
        let justSaved = lastSaveTime.map { Date().timeIntervalSince($0) < 2.0 } ?? false

        // Check for unsaved changes before refreshing
        if structureChangeManager.hasChanges && !justSaved {
            // Show confirmation dialog
            Task { @MainActor in
                let window = coordinator?.contentWindow
                let confirmed = await AlertHelper.confirmDestructive(
                    title: String(localized: "Discard Changes?"),
                    message: String(localized: "You have unsaved changes to the table structure. Refreshing will discard these changes."),
                    confirmButton: String(localized: "Discard"),
                    cancelButton: String(localized: "Cancel"),
                    window: window
                )

                if confirmed {
                    discardChanges()
                    await reloadAllTabs()
                }
            }
            // If cancelled, do nothing
        } else {
            Task { @MainActor in
                await reloadAllTabs()
            }
        }
    }

    private func reloadAllTabs() async {
        await loadColumns()
        await fetchTabData(.indexes)
        if connection.type.supportsForeignKeys {
            await fetchTabData(.foreignKeys)
        }
        if selectedTab == .ddl {
            await fetchTabData(.ddl)
        }
    }
}
