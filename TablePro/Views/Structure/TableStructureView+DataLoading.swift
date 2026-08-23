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
    /// Runs once per session, not once per view. The view is rebuilt whenever the tab is deselected
    /// or switched to Data and back, and `loadSchemaForEditing` re-baselines the change manager,
    /// which clears every staged edit, its validation errors and its undo stack. So a rebuild reads
    /// what the session already holds rather than fetching over the top of the user's work.
    ///
    /// A genuine refresh still refetches, through `onRefreshData`, which asks before discarding.
    @Sendable
    func loadInitialData() async {
        guard !session.hasLoaded else {
            isInitialLoading = false
            isLoading = false
            return
        }
        await loadColumns()
        await loadTabDataIfNeeded(.indexes)
        await loadTabDataIfNeeded(.foreignKeys)
        loadSchemaForEditing()
        session.hasLoaded = true
        isInitialLoading = false
    }

    func loadColumns() async {
        isLoading = true
        errorMessage = nil

        do {
            columns = try await structureLoader.columns()
            tabData.markFetched(.columns)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadTabDataIfNeeded(_ tab: StructureTab) async {
        guard tabData.needsFetch(tab) else { return }
        await fetchTabData(tab)
    }

    func fetchTabData(_ tab: StructureTab) async {
        do {
            switch tab {
            case .columns:
                columns = try await structureLoader.columns()
            case .indexes:
                indexes = try await structureLoader.indexes()
            case .foreignKeys:
                foreignKeys = try await structureLoader.foreignKeys()
            case .ddl:
                let table = tableName
                ddlStatement = try await structureLoader.perform { driver in
                    let sequences = try await driver.fetchDependentSequences(forTable: table)
                    let enumTypes = try await driver.fetchDependentTypes(forTable: table)
                    let baseDDL = try await driver.fetchTableDDL(table: table)
                    if sequences.isEmpty && enumTypes.isEmpty {
                        return baseDDL
                    }
                    var preamble = ""
                    for seq in sequences {
                        preamble += seq.ddl + "\n\n"
                    }
                    for enumType in enumTypes {
                        let quotedName = "\"\(enumType.name.replacingOccurrences(of: "\"", with: "\"\""))\""
                        let quotedLabels = enumType.labels.map { "'\(SQLEscaping.escapeStringLiteral($0))'" }
                        preamble += "CREATE TYPE \(quotedName) AS ENUM (\(quotedLabels.joined(separator: ", ")));\n"
                    }
                    return preamble + "\n" + baseDDL
                }
            case .triggers:
                do {
                    triggers = try await structureLoader.triggers()
                } catch {
                    Self.logger.error("Failed to load triggers: \(error.localizedDescription, privacy: .public)")
                    triggers = []
                }
            case .parts:
                return
            }
            tabData.markFetched(tab)
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
            primaryKey: primaryKey
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
        guard !isReloadingAfterSave else {
            Self.logger.debug("Ignoring refresh notification - currently reloading after save")
            return
        }

        // Skip warning if we just saved (within 2 seconds)
        let justSaved = lastSaveTime.map { Date().timeIntervalSince($0) < 2.0 } ?? false

        if structureChangeManager.hasChanges && !justSaved {
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
        tabData.markAllStale()
        partsReloadToken += 1
        await reloadCoreTabs()
        if selectedTab == .ddl {
            await fetchTabData(.ddl)
        }
        if selectedTab == .triggers, connection.type.supportsTriggers {
            await fetchTabData(.triggers)
        }
    }

    /// Fetches columns, indexes and foreign keys together and commits them in a single
    /// synchronous block, so the segmented picker re-lays out once instead of per tab.
    func reloadCoreTabs() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let includesForeignKeys = connection.type.supportsForeignKeys
        do {
            let reloaded = try await structureLoader.coreTabs(includingForeignKeys: includesForeignKeys)

            columns = reloaded.columns
            indexes = reloaded.indexes
            tabData.markFetched(.columns)
            tabData.markFetched(.indexes)
            if includesForeignKeys {
                foreignKeys = reloaded.foreignKeys
                tabData.markFetched(.foreignKeys)
            }
        } catch {
            Self.logger.error("Failed to reload structure: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}
