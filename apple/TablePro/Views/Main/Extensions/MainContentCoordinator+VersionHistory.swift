//
//  MainContentCoordinator+VersionHistory.swift
//  TablePro
//

import Foundation
import os

extension MainContentCoordinator {
    private static let versionHistoryLogger = Logger(subsystem: "com.TablePro", category: "VersionHistory")

    func showVersionHistory(of favorite: SQLFavorite) {
        openVersionHistory(subject: .savedQuery(id: favorite.id), name: favorite.name)
    }

    func showVersionHistory(of linked: LinkedSQLFavorite) {
        openVersionHistory(subject: .linkedFile(url: linked.fileURL), name: linked.fileURL.lastPathComponent)
    }

    func showVersionHistory(ofQueryTab tabId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.tabType == .query else { return }
        openVersionHistory(subject: .queryTab(id: tabId), name: tab.title)
    }

    func revertQueryTab(_ tabId: UUID, toVersion versionId: Int64) {
        let provider = queryTabVersionProvider(for: tabId)
        Task {
            do {
                try await provider.prepareRestore(.tabVersion(id: versionId)).apply()
            } catch {
                Self.versionHistoryLogger.error("Reverting a query tab failed: \(error.publicLogShape, privacy: .public)")
                presentError(String(localized: "Couldn't Restore Version"), error.localizedDescription, contentWindow)
            }
        }
    }

    func queryTabVersionProvider(for tabId: UUID) -> QueryTabVersionHistoryProvider {
        let recorder = tabVersions
        return QueryTabVersionHistoryProvider(
            tabId: tabId,
            storage: recorder.storage,
            liveTab: { [weak self] in self?.liveQueryTab(tabId) },
            write: { [weak self] text in self?.replaceQueryText(inTab: tabId, with: text, recording: nil) ?? false },
            isCapturePaused: recorder.isCapturePaused
        )
    }

    // The History tab can outlive a move of the tab it shows, so each call finds the tab's current owner.
    static func hostedQueryTabVersionProvider(for tabId: UUID) -> QueryTabVersionHistoryProvider {
        QueryTabVersionHistoryProvider(
            tabId: tabId,
            storage: .shared,
            liveTab: { Self.owner(ofQueryTab: tabId)?.liveQueryTab(tabId) },
            write: { text in
                Self.owner(ofQueryTab: tabId)?.replaceQueryText(inTab: tabId, with: text, recording: nil) ?? false
            }
        )
    }

    func liveQueryTab(_ tabId: UUID) -> LiveQueryTab? {
        flushEditorText(forTab: tabId)
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.tabType == .query else { return nil }
        return LiveQueryTab(connectionId: connectionId, text: tab.content.query)
    }

    private static func owner(ofQueryTab tabId: UUID) -> MainContentCoordinator? {
        HostedTabRouting.live.allCoordinators().first { coordinator in
            coordinator.tabManager.tabs.contains { $0.id == tabId && $0.tabType == .query }
        }
    }

    func openVersionInEditor(_ content: String) {
        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .query,
            databaseName: browseDatabaseName,
            initialQuery: content,
            skipAutoExecute: true
        )
        WindowManager.shared.openTab(payload: payload)
    }

    func discardChanges(to linked: LinkedSQLFavorite, confirm: () async -> Bool) async {
        do {
            let plan = try await LinkedFileVersionHistoryProvider(fileURL: linked.fileURL).prepareDiscard()
            guard await confirm() else { return }
            try await plan.apply()
            Self.reloadUnmodifiedFileTabs(at: linked.fileURL)
            LinkedFolderGitStatusStore.shared.scheduleRefresh(after: .zero)
        } catch {
            Self.versionHistoryLogger.error("Discarding changes failed: \(error.publicLogShape, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Couldn't Discard Changes"),
                message: error.localizedDescription,
                window: nil
            )
        }
    }

    static func reloadUnmodifiedFileTabs(at url: URL) {
        let target = url.standardizedFileURL
        for coordinator in activeCoordinators.values {
            for tab in coordinator.tabManager.tabs
            where tab.content.sourceFileURL?.standardizedFileURL == target && !tab.content.isFileDirty {
                coordinator.commandActions?.reloadFileFromDisk(tabId: tab.id, url: url)
            }
        }
    }

    private func openVersionHistory(subject: VersionHistorySubject, name: String) {
        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .versionHistory,
            databaseName: browseDatabaseName,
            versionHistorySubject: subject,
            tabTitle: QueryTabManager.versionHistoryTitle(for: name)
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
