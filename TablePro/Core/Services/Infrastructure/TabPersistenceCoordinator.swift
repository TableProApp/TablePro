//
//  TabPersistenceCoordinator.swift
//  TablePro
//
//  Explicit-save coordinator for tab state persistence.
//  Replaces debounced/flag-based TabPersistenceService with direct save calls.
//

import Foundation
import Observation

/// Result of tab restoration from disk
internal struct RestoreResult {
    let tabs: [QueryTab]
    let selectedTabId: UUID?
    let source: RestoreSource

    enum RestoreSource {
        case disk
        case none
    }
}

/// Coordinator for persisting and restoring tab state.
/// All saves are explicit: no debounce timers, no onChange-driven saves,
/// no isDismissing/isRestoringTabs flag state machine.
@MainActor @Observable
internal final class TabPersistenceCoordinator {
    let connectionId: UUID

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    // MARK: - Save

    /// Save tab state to disk. Called explicitly at named business events
    /// (tab switch, window close, quit, etc.).
    internal func saveNow(tabs: [QueryTab], selectedTabId: UUID?) {
        let nonPreviewTabs = tabs.filter { !$0.isPreview }
        guard !nonPreviewTabs.isEmpty else {
            clearSavedState()
            return
        }
        let persisted = nonPreviewTabs.map { convertToPersistedTab($0) }
        let connId = connectionId
        let normalizedSelectedId = nonPreviewTabs.contains(where: { $0.id == selectedTabId })
            ? selectedTabId : nonPreviewTabs.first?.id

        Task {
            do {
                try await TabDiskActor.shared.save(connectionId: connId, tabs: persisted, selectedTabId: normalizedSelectedId)
            } catch {
                TabDiskActor.logSaveError(connectionId: connId, error: error)
            }
        }
    }

    /// Save pre-aggregated tabs for the quit path, where the caller has already
    /// collected and converted tabs from all windows for this connection.
    internal func saveNow(persistedTabs: [PersistedTab], selectedTabId: UUID?) {
        let connId = connectionId
        let selectedId = selectedTabId

        Task {
            do {
                try await TabDiskActor.shared.save(connectionId: connId, tabs: persistedTabs, selectedTabId: selectedId)
            } catch {
                TabDiskActor.logSaveError(connectionId: connId, error: error)
            }
        }
    }

    /// Synchronous save for `applicationWillTerminate` where no run loop
    /// remains to service async Tasks. Bypasses the actor and writes directly.
    internal func saveNowSync(tabs: [QueryTab], selectedTabId: UUID?) {
        let nonPreviewTabs = tabs.filter { !$0.isPreview }
        guard !nonPreviewTabs.isEmpty else {
            TabDiskActor.saveSync(connectionId: connectionId, tabs: [], selectedTabId: nil)
            return
        }
        let persisted = nonPreviewTabs.map { convertToPersistedTab($0) }
        let normalizedSelectedId = nonPreviewTabs.contains(where: { $0.id == selectedTabId })
            ? selectedTabId : nonPreviewTabs.first?.id
        TabDiskActor.saveSync(connectionId: connectionId, tabs: persisted, selectedTabId: normalizedSelectedId)
    }

    // MARK: - Clear

    /// Clear all saved state for this connection (user closed all tabs).
    internal func clearSavedState() {
        let connId = connectionId
        Task {
            await TabDiskActor.shared.clear(connectionId: connId)
        }
    }

    // MARK: - Restore

    /// Restore tabs from disk. Called once at window creation.
    internal func restoreFromDisk() async -> RestoreResult {
        guard let state = await TabDiskActor.shared.load(connectionId: connectionId) else {
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }

        guard !state.tabs.isEmpty else {
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }

        let restoredTabs = state.tabs.map { QueryTab(from: $0) }
        return RestoreResult(
            tabs: restoredTabs,
            selectedTabId: state.selectedTabId,
            source: .disk
        )
    }

    // MARK: - Last Query

    /// Save the editor's last query text for this connection.
    internal func saveLastQuery(_ query: String) {
        let connId = connectionId
        Task {
            await TabDiskActor.shared.saveLastQuery(query, for: connId)
        }
    }

    /// Load the editor's last query text for this connection.
    internal func loadLastQuery() async -> String? {
        await TabDiskActor.shared.loadLastQuery(for: connectionId)
    }

    // MARK: - Private

    private func convertToPersistedTab(_ tab: QueryTab) -> PersistedTab {
        let persistedQuery: String
        if (tab.query as NSString).length > QueryTab.maxPersistableQuerySize {
            persistedQuery = ""
        } else {
            persistedQuery = tab.query
        }

        return PersistedTab(
            id: tab.id,
            title: tab.title,
            query: persistedQuery,
            tabType: tab.tabType,
            tableName: tab.tableName,
            isView: tab.isView,
            databaseName: tab.databaseName,
            sourceFileURL: tab.sourceFileURL
        )
    }
}
