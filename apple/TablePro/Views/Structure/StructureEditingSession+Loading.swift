//
//  StructureEditingSession+Loading.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

internal extension StructureEditingSession {
    var loader: TableStructureLoader {
        TableStructureLoader(scope: scope, tableName: tableName)
    }

    var offersTableComment: Bool {
        DatabaseObjectToolEligibility.Support.of(DatabaseManager.shared.driver(for: connection.id))
            .commentableTypes.contains(objectKind)
    }

    // A failed read ends the wait, so its section can show the error and Try Again; edits stay closed until a baseline.
    var isLoadingFirstTime: Bool {
        !hasBaseline && !editor.sections.contains { loadState.failure(StructureLoadState.Item($0)) != nil }
    }

    // Idempotent: a pane re-added after a connection switch restarts this, and only what is missing is read.
    func load() async {
        settleOwedRefetch()
        guard !hasLoaded else {
            await reloadConcurrentRefreshAvailability()
            await readTableOptionsCatalogIfNeeded()
            await loadPaneIfNeeded(pane)
            return
        }
        serverSupport = StructureServerSupport.forConnection(connection.id)
        await fetchDefinitionsNeedingFetch()
        guard !Task.isCancelled else { return }
        await loadTableComment()
        guard !Task.isCancelled else { return }
        await readTableOptions()
        guard !Task.isCancelled else { return }
        adoptIfCurrent()
        await reloadConcurrentRefreshAvailability()
        await readTableOptionsCatalogIfNeeded()
        await loadPaneIfNeeded(pane)
    }

    // Every offered section read since the last change; a baseline built from less would stage against a guess.
    var definitionsAreCurrent: Bool {
        editor.sections.allSatisfy { !loadState.needsFetch(StructureLoadState.Item($0)) }
    }

    func fetchDefinitionsNeedingFetch() async {
        for section in editor.sections where loadState.needsFetch(StructureLoadState.Item(section)) {
            guard !Task.isCancelled else { return }
            await fetch(StructureLoadState.Item(section))
        }
    }

    // A partial read still shows what it got, read-only, so a failed section never hides the ones that loaded.
    func adoptIfCurrent() {
        guard definitionsAreCurrent else {
            if !changeManager.hasChanges { loadDefinitionsIntoManager() }
            return
        }
        hasLoaded = true
        adoptFetchedBaseline()
    }

    func loadPaneIfNeeded(_ pane: StructurePane) async {
        switch pane {
        case .triggers:
            guard loadState.needsFetch(.triggers) else { return }
            await fetch(.triggers)
        case .ddl:
            guard loadState.needsFetch(.ddl) else { return }
            await fetch(.ddl)
        case .definition, .parts:
            return
        }
    }

    func fetch(_ item: StructureLoadState.Item) async {
        do {
            switch item {
            case .columns:
                columns = try await loader.columns()
            case .indexes:
                indexes = try await loader.indexes()
            case .foreignKeys:
                foreignKeys = try await loader.foreignKeys()
            case .checkConstraints:
                checkConstraints = try await loader.checkConstraints()
            case .triggers:
                triggers = try await loader.triggers()
            case .ddl:
                let table = tableName
                let schema = scope.schema
                ddlStatement = try await loader.perform { driver in
                    try await TableDDLComposer.fetchDDL(
                        for: table, using: driver, includesDependencies: true, schema: schema
                    )
                }
            }
            loadState.markFetched(item)
        } catch {
            guard let message = StructureFetchFailure(error, taskIsCancelled: Task.isCancelled).message else { return }
            Self.logger.error("Failed to load \(String(describing: item), privacy: .public): \(error.publicLogShape, privacy: .public)")
            loadState.markFailed(item, message: message)
        }
    }

    func retry(_ item: StructureLoadState.Item) {
        Task {
            switch item {
            case .columns, .indexes, .foreignKeys, .checkConstraints:
                await fetchDefinitionsNeedingFetch()
                adoptIfCurrent()
            case .triggers, .ddl:
                await fetch(item)
            }
        }
    }

    func loadTableComment() async {
        guard offersTableComment else { return }
        beginTableCommentLoad()
        let outcome: MetadataFetchOutcome<String?>
        do {
            outcome = .fetched(try await loader.tableComment())
        } catch {
            switch StructureFetchFailure(error, taskIsCancelled: Task.isCancelled) {
            case .cancelled:
                outcome = .cancelled
            case .failed(let message):
                Self.logger.error("Failed to load the table comment: \(error.publicLogShape, privacy: .public)")
                outcome = .failed(message)
            }
        }
        settleTableComment(outcome)
    }

    func readTableOptionsCatalogIfNeeded() async {
        guard needsTableOptionsCatalog else { return }
        await readTableOptionsCatalog()
    }

    // MARK: - Baseline

    func adoptLoadedBaseline() {
        loadDefinitionsIntoManager()
        hasBaseline = true
        editor.isAwaitingBaseline = false
    }

    // PostgreSQL leaves `isPrimaryKey` false on every column, so the primary index decides first.
    private func loadDefinitionsIntoManager() {
        let pkFromIndexes = indexes.first(where: { $0.isPrimary })?.columns ?? []
        let pkFromColumns = columns.filter { $0.isPrimaryKey }.map { $0.name }
        let primaryKey = pkFromIndexes.isEmpty ? pkFromColumns : pkFromIndexes

        changeManager.loadSchema(
            tableName: tableName,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            checkConstraints: checkConstraints,
            primaryKey: primaryKey,
            tableComment: loadedTableComment,
            tableOptions: loadedTableOptions,
            autoIncrementConfirmed: autoIncrementRead == .confirmed
        )
        editor.refresh()
    }

    func adoptFetchedBaseline() {
        guard !changeManager.hasChanges else {
            markStructureStale()
            return
        }
        adoptLoadedBaseline()
    }

    func rebaselineUnlessEdited() {
        guard !isReloadingAfterSave, hasLoaded else { return }
        adoptFetchedBaseline()
    }

    // Reads what the Structure tab's first mount reads, so an edit staged without the tab composes the statements
    // the tab would.
    func loadEditingBaseline(provider: any ScopedMetadataProviding = DatabaseManager.shared) async throws {
        let loader = TableStructureLoader(scope: scope, tableName: tableName, provider: provider)
        serverSupport = StructureServerSupport.forConnection(connection.id)
        columns = try await loader.columns()
        indexes = try await loader.indexes()
        foreignKeys = try await loader.foreignKeys()
        if editor.offers(.checkConstraints) {
            checkConstraints = try await loader.checkConstraints()
        }
        adoptLoadedBaseline()
        hasLoaded = true
    }

    // MARK: - Reload

    func reloadDefinitions() async {
        let includesForeignKeys = editor.offers(.foreignKeys)
        let offersTableOptions = offersTableOptionsTab
        do {
            let reloaded = try await loader.coreTabs(
                includingForeignKeys: includesForeignKeys,
                includingTableComment: offersTableComment,
                includingTableOptions: offersTableOptions
            )
            if let comment = reloaded.tableComment {
                settleTableComment(comment)
            }
            // A save never adopts the counter it wrote: the server raises a low value, so this read is what shows.
            if let options = reloaded.tableOptions {
                settleTableOptions(options)
            }
            columns = reloaded.columns
            indexes = reloaded.indexes
            loadState.markFetched(.columns)
            loadState.markFetched(.indexes)
            if includesForeignKeys {
                foreignKeys = reloaded.foreignKeys
                loadState.markFetched(.foreignKeys)
            }
        } catch {
            if offersTableOptions {
                settleTableOptions(.cancelled)
            }
            if let message = StructureFetchFailure(error, taskIsCancelled: Task.isCancelled).message {
                Self.logger.error("Failed to reload structure: \(error.publicLogShape, privacy: .public)")
                loadState.markFailed(.columns, message: message)
            }
        }
        if editor.offers(.checkConstraints) {
            await fetch(.checkConstraints)
        }
        await reloadConcurrentRefreshAvailability()
    }

    // A failed read keeps the save's tables closed to edits until Try Again reads them.
    func refreshAfterApply() async {
        isReloadingAfterSave = true
        await reloadDefinitions()
        isReloadingAfterSave = false
        adoptIfCurrent()
        await loadPaneIfNeeded(pane)
    }

    // Refresh reads everything again; staged edits are discarded first, after asking.
    func refresh() {
        guard !isReloadingAfterSave else { return }
        let justSaved = lastAppliedAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false
        guard changeManager.hasChanges, !justSaved else {
            Task { await reloadEverything() }
            return
        }
        Task {
            guard await confirmDiscard(
                message: String(localized: "Refreshing reads the table structure again and discards the changes you have not saved.")
            ) else { return }
            discardChanges()
            await reloadEverything()
        }
    }

    private func reloadEverything() async {
        markEveryTabStale()
        editor.referenceMenus.invalidateTableLists()
        partsReloadToken &+= 1
        await reloadDefinitions()
        adoptIfCurrent()
        await loadPaneIfNeeded(pane)
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
