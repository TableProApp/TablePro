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
