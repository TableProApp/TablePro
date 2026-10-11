//
//  VersionHistoryFactory.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal enum VersionHistoryFactory {
    static func makeViewModel(for subject: VersionHistorySubject) -> VersionHistoryViewModel {
        let viewModel: VersionHistoryViewModel
        switch subject {
        case .savedQuery(let id):
            viewModel = VersionHistoryViewModel(
                subject: subject,
                provider: SavedQueryVersionHistoryProvider(favoriteId: id, manager: .shared),
                refreshSignal: AppEvents.shared.sqlFavoritesDidUpdate.map { _ in () }.eraseToAnyPublisher()
            )
        case .linkedFile(let url):
            viewModel = VersionHistoryViewModel(
                subject: subject,
                provider: LinkedFileVersionHistoryProvider(fileURL: url),
                refreshSignal: AppEvents.shared.linkedSQLFoldersDidUpdate.map { _ in () }
                    .merge(with: LinkedFolderGitStatusStore.shared.$snapshots.dropFirst().map { _ in () })
                    .eraseToAnyPublisher()
            )
            viewModel.onRestored = {
                MainContentCoordinator.reloadUnmodifiedFileTabs(at: url)
                LinkedFolderGitStatusStore.shared.scheduleRefresh(after: .zero)
            }
            viewModel.confirmReplacingUncommittedChanges = {
                await AlertHelper.confirmDestructive(
                    title: String(format: String(localized: "Restore this version of \"%@\"?"), url.lastPathComponent),
                    message: String(localized: "The file has uncommitted changes. Restoring this version replaces them, and you can't undo this action."),
                    confirmButton: String(localized: "Restore")
                )
            }
        }
        viewModel.reportRestoreFailure = { message in
            AlertHelper.showErrorSheet(
                title: String(localized: "Couldn't Restore Version"),
                message: message,
                window: nil
            )
        }
        return viewModel
    }
}
