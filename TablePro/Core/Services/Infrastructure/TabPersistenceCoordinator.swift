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
        let nonPreviewTabs = tabs.filter { !$0.isPreview }
        guard !nonPreviewTabs.isEmpty else {
            clearSavedState()
            return
        }
        let persisted = nonPreviewTabs.map { convertToPersistedTab($0) }
        let normalizedSelectedId = nonPreviewTabs.contains(where: { $0.id == selectedTabId })
            ? selectedTabId : nonPreviewTabs.first?.id
        scheduleSave(tabs: persisted, selectedTabId: normalizedSelectedId)
    }

    internal func saveNowSync(tabs: [QueryTab], selectedTabId: UUID?) {
        let nonPreviewTabs = tabs.filter { !$0.isPreview }
        guard !nonPreviewTabs.isEmpty else {
            saveTask?.cancel()
            saveTask = nil
            TabDiskActor.clearSync(connectionId: connectionId)
            return
        }
        let persisted = nonPreviewTabs.map { convertToPersistedTab($0) }
        let normalizedSelectedId = nonPreviewTabs.contains(where: { $0.id == selectedTabId })
            ? selectedTabId : nonPreviewTabs.first?.id
        TabDiskActor.saveSync(connectionId: connectionId, tabs: persisted, selectedTabId: normalizedSelectedId)
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

    private func scheduleSave(tabs: [PersistedTab], selectedTabId: UUID?) {
        saveTask?.cancel()
        let connId = connectionId
        let tabsCopy = tabs
        let selectedId = selectedTabId
        Self.logger.debug("[persist] saveNow queued tabCount=\(tabsCopy.count) connId=\(connId, privacy: .public)")

        saveTask = Task {
            guard !Task.isCancelled else { return }
            let t0 = Date()
            do {
                try await TabDiskActor.shared.save(connectionId: connId, tabs: tabsCopy, selectedTabId: selectedId)
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

        var restoredTabs = state.tabs.map { QueryTab(from: $0) }
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
            source: .disk
        )
    }

    // MARK: - Private

    private func convertToPersistedTab(_ tab: QueryTab) -> PersistedTab {
        let persistedQuery: String
        if (tab.content.query as NSString).length > TabQueryContent.maxPersistableQuerySize {
            persistedQuery = ""
        } else {
            persistedQuery = tab.content.query
        }

        return PersistedTab(
            id: tab.id,
            title: tab.title,
            query: persistedQuery,
            tabType: tab.tabType,
            tableName: tab.tableContext.tableName,
            isView: tab.tableContext.isView,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            sourceFileURL: tab.content.sourceFileURL
        )
    }
}
