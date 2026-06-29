//
//  TabPersistenceCoordinator.swift
//  TablePro
//

import Foundation
import Observation
import os

internal struct RestoreResult {
    let tabs: [QueryTab]
    let selectedTabId: UUID?
    let source: RestoreSource
    var lastActiveDatabase: String?
    var lastActiveSchema: String?

    enum RestoreSource {
        case disk
        case none
    }
}

@MainActor @Observable
internal final class TabPersistenceCoordinator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")
    let connectionId: UUID

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(connectionId: UUID) {
        self.connectionId = connectionId
    }

    // MARK: - Save

    internal func saveNow(tabs: [QueryTab], selectedTabId: UUID?) {
        saveNow(windowedTabs: tabs.map { (tab: $0, windowGroupIndex: 0) }, selectedTabId: selectedTabId)
    }

    internal func saveNow(windowedTabs: [(tab: QueryTab, windowGroupIndex: Int)], selectedTabId: UUID?) {
        guard !windowedTabs.isEmpty else {
            clearSavedState()
            return
        }
        let persisted = windowedTabs.map { $0.tab.toPersistedTab(windowGroupIndex: $0.windowGroupIndex) }
        let normalizedSelectedId = windowedTabs.contains(where: { $0.tab.id == selectedTabId })
            ? selectedTabId : windowedTabs.first?.tab.id
        let active = currentActiveDatabaseAndSchema()
        scheduleSave(
            tabs: persisted,
            selectedTabId: normalizedSelectedId,
            lastActiveDatabase: active.database,
            lastActiveSchema: active.schema
        )
    }

    internal func saveNowSync(tabs: [QueryTab], selectedTabId: UUID?) {
        saveNowSync(windowedTabs: tabs.map { (tab: $0, windowGroupIndex: 0) }, selectedTabId: selectedTabId)
    }

    internal func saveNowSync(windowedTabs: [(tab: QueryTab, windowGroupIndex: Int)], selectedTabId: UUID?) {
        guard !windowedTabs.isEmpty else {
            saveTask?.cancel()
            saveTask = nil
            TabDiskActor.clearSync(connectionId: connectionId)
            return
        }
        let persisted = windowedTabs.map { $0.tab.toPersistedTab(windowGroupIndex: $0.windowGroupIndex) }
        let normalizedSelectedId = windowedTabs.contains(where: { $0.tab.id == selectedTabId })
            ? selectedTabId : windowedTabs.first?.tab.id
        let active = currentActiveDatabaseAndSchema()
        TabDiskActor.saveSync(
            connectionId: connectionId,
            tabs: persisted,
            selectedTabId: normalizedSelectedId,
            lastActiveDatabase: active.database,
            lastActiveSchema: active.schema
        )
    }

    private func currentActiveDatabaseAndSchema() -> (database: String?, schema: String?) {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return (nil, nil) }
        return (session.currentDatabase, session.currentSchema)
    }

    // MARK: - Clear

    internal func clearSavedState() {
        saveTask?.cancel()
        saveTask = nil
        let connId = connectionId
        Task {
            await TabDiskActor.shared.clear(connectionId: connId)
        }
    }

    // MARK: - Private save scheduling

    private func scheduleSave(
        tabs: [PersistedTab],
        selectedTabId: UUID?,
        lastActiveDatabase: String?,
        lastActiveSchema: String?
    ) {
        saveTask?.cancel()
        let connId = connectionId
        let tabsCopy = tabs
        let selectedId = selectedTabId
        let activeDatabase = lastActiveDatabase
        let activeSchema = lastActiveSchema
        Self.logger.debug("[persist] saveNow queued tabCount=\(tabsCopy.count) connId=\(connId, privacy: .public)")

        saveTask = Task {
            guard !Task.isCancelled else { return }
            let t0 = Date()
            do {
                try await TabDiskActor.shared.save(
                    connectionId: connId,
                    tabs: tabsCopy,
                    selectedTabId: selectedId,
                    lastActiveDatabase: activeDatabase,
                    lastActiveSchema: activeSchema
                )
                Self.logger.debug("[persist] saveNow written tabCount=\(tabsCopy.count) connId=\(connId, privacy: .public) ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
            } catch is CancellationError {
                return
            } catch {
                Self.logger.fault("Failed to save tab state for connection \(connId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Restore

    internal func restoreFromDisk() async -> RestoreResult {
        guard let state = await TabDiskActor.shared.load(connectionId: connectionId) else {
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }

        guard !state.tabs.isEmpty else {
            return RestoreResult(tabs: [], selectedTabId: nil, source: .none)
        }

        let defaultPageSize = AppSettingsManager.shared.dataGrid.defaultPageSize
        var restoredTabs = state.tabs.map { QueryTab(from: $0, defaultPageSize: defaultPageSize) }
        for index in restoredTabs.indices {
            guard let url = restoredTabs[index].content.sourceFileURL else { continue }
            if let loaded = FileTextLoader.load(url) {
                restoredTabs[index].content.savedFileContent = loaded.content
                restoredTabs[index].content.loadMtime = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            }
        }
        return RestoreResult(
            tabs: restoredTabs,
            selectedTabId: state.selectedTabId,
            source: .disk,
            lastActiveDatabase: state.lastActiveDatabase,
            lastActiveSchema: state.lastActiveSchema
        )
    }
}
