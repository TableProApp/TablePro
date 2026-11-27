import Foundation
import TableProSyncTransport

nonisolated enum ConnectionListState: Equatable, Sendable {
    case loading
    case failed
    case checkingICloud
    case iCloudUnavailable(SyncError)
    case empty(syncsWithICloud: Bool)
    case content(syncProblem: SyncError?)

    static func resolve(
        loadStatus: LoadStatus,
        hasLibraryItems: Bool,
        hasActiveProject: Bool,
        isSyncEnabled: Bool,
        syncStatus: SyncStatus,
        hasCompletedFirstSync: Bool
    ) -> ConnectionListState {
        switch loadStatus {
        case .failed:
            return .failed
        case .loading:
            return .loading
        case .ready:
            break
        }
        let syncError = isSyncEnabled ? syncStatus.error : nil
        // The first run offers the sample database, which lands in no project, so a project shows its own empty list.
        if hasLibraryItems || hasActiveProject {
            return .content(syncProblem: syncError)
        }
        guard isSyncEnabled, !hasCompletedFirstSync else {
            return .empty(syncsWithICloud: isSyncEnabled)
        }
        if let syncError {
            return .iCloudUnavailable(syncError)
        }
        return syncStatus == .syncing ? .checkingICloud : .empty(syncsWithICloud: true)
    }
}
