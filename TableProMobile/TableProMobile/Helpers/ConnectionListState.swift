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
        if hasLibraryItems {
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

nonisolated private extension SyncStatus {
    var error: SyncError? {
        guard case .error(let error) = self else { return nil }
        return error
    }
}
