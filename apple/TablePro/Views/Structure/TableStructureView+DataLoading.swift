//
//  TableStructureView+DataLoading.swift
//  TablePro
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
        session.settleOwedRefetch()
        guard !session.hasLoaded else {
            isInitialLoading = false
            isLoading = false
            await session.reloadConcurrentRefreshAvailability()
            await loadTableOptionsCatalogIfNeeded()
            return
        }
        await loadColumns()
        for tab in session.tabsFetchedOnMount where tab != .columns {
            guard !Task.isCancelled else { break }
            await loadTabDataIfNeeded(tab)
        }
        // A workspace switch cancels this task and restarts it on return, so a cut-short load must not count.
        guard !Task.isCancelled else { return }
        await loadTableComment()
        guard !Task.isCancelled else { return }
        await session.readTableOptions()
        guard !Task.isCancelled else { return }
        adoptFetchedBaseline()
        session.hasLoaded = true
        isInitialLoading = false
        // After the baseline, so the columns are editable while the catalog is read.
        await loadTableOptionsCatalogIfNeeded()
    }

    func loadColumns() async {
        isLoading = true
        errorMessage = nil

        do {
            columns = try await structureLoader.columns()
            tabData.markFetched(.columns)
        } catch {
            if let message = fetchFailure(error).message {
                errorMessage = message
            }
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
                await session.reloadConcurrentRefreshAvailability()
            case .foreignKeys:
                foreignKeys = try await structureLoader.foreignKeys()
            case .checkConstraints:
                checkConstraints = try await structureLoader.checkConstraints()
            case .ddl:
                let table = tableName
                let schema = structureLoader.scope.schema
                ddlStatement = try await structureLoader.perform { driver in
                    try await TableDDLComposer.fetchDDL(
                        for: table, using: driver, includesDependencies: true, schema: schema
                    )
                }
            case .triggers:
                do {
                    triggers = try await structureLoader.triggers()
                } catch {
                    guard fetchFailure(error) != .cancelled else { return }
                    Self.logger.error("Failed to load triggers: \(error.publicLogShape, privacy: .public)")
                    triggers = []
                }
            case .parts, .options:
                return
            }
            tabData.markFetched(tab)
        } catch {
            guard let message = fetchFailure(error).message else { return }
            Self.logger.error("Failed to load \(tab.rawValue, privacy: .public): \(error.publicLogShape, privacy: .public)")
            errorMessage = message
        }
    }

    private func fetchFailure(_ error: any Error) -> StructureFetchFailure {
        StructureFetchFailure(error, taskIsCancelled: Task.isCancelled)
    }

    func loadSchemaForEditing() {
        session.adoptLoadedBaseline()
    }

    // MARK: - Lifecycle Callbacks

    func onSelectedTabChanged(_ new: StructureTab) {
        searchText = ""
        structureSortDescriptor = nil
        sortState = SortState()
        gridAdapter.refresh()
        Task {
            await loadTabDataIfNeeded(new)
        }
    }

    func adoptFetchedBaseline() {
        guard !structureChangeManager.hasChanges else {
            session.markStructureStale()
            return
        }
        loadSchemaForEditing()
    }

    func rebaselineUnlessEdited() {
        guard !isReloadingAfterSave, !isInitialLoading else { return }
        adoptFetchedBaseline()
    }

    func onColumnsChanged() {
        rebaselineUnlessEdited()
    }

    func onIndexesChanged() {
        rebaselineUnlessEdited()
    }

    func onCheckConstraintsChanged() {
        rebaselineUnlessEdited()
    }

    func onForeignKeysChanged() {
        rebaselineUnlessEdited()
    }

    func onRefreshData() {
        guard !isReloadingAfterSave else {
            Self.logger.debug("Ignoring refresh notification - currently reloading after save")
            return
        }

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
        } else {
            Task { @MainActor in
                await reloadAllTabs()
            }
        }
    }

    private func reloadAllTabs() async {
        session.markEveryTabStale()
        gridAdapter.referenceMenus.invalidateTableLists()
        partsReloadToken += 1
        await reloadCoreTabs()
        switch selectedTab {
        case .ddl:
            await fetchTabData(.ddl)
        case .triggers where connection.type.supportsTriggers:
            await fetchTabData(.triggers)
        case .columns, .indexes, .foreignKeys, .checkConstraints, .triggers, .options, .parts:
            break
        }
    }

    func reloadCoreTabs() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let includesForeignKeys = connection.type.supportsForeignKeys
        let offersTableOptions = session.offersTableOptionsTab
        do {
            let reloaded = try await structureLoader.coreTabs(
                includingForeignKeys: includesForeignKeys,
                includingTableComment: offersTableComment,
                includingTableOptions: offersTableOptions
            )

            if let comment = reloaded.tableComment {
                session.settleTableComment(comment)
            }
            // A save never adopts the counter it wrote: the server raises a low value, so this read is what shows.
            if let options = reloaded.tableOptions {
                session.settleTableOptions(options)
            }
            columns = reloaded.columns
            indexes = reloaded.indexes
            tabData.markFetched(.columns)
            tabData.markFetched(.indexes)
            if includesForeignKeys {
                foreignKeys = reloaded.foreignKeys
                tabData.markFetched(.foreignKeys)
            }
            await session.reloadConcurrentRefreshAvailability()
        } catch {
            // A counter re-read the save started ends unconfirmed, keeping the options already on screen.
            if offersTableOptions {
                session.settleTableOptions(.cancelled)
            }
            guard let message = fetchFailure(error).message else { return }
            Self.logger.error("Failed to reload structure: \(error.publicLogShape, privacy: .public)")
            errorMessage = message
        }
    }
}

internal enum StructureFetchFailure: Equatable {
    case cancelled
    case failed(String)

    internal init(_ error: any Error, taskIsCancelled: Bool) {
        if error is CancellationError || taskIsCancelled {
            self = .cancelled
        } else {
            self = .failed(error.localizedDescription)
        }
    }

    internal var message: String? {
        switch self {
        case .cancelled: nil
        case .failed(let message): message
        }
    }
}
