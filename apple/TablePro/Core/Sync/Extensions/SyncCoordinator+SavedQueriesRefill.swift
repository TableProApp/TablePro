import CloudKit
import Foundation
import os
import TableProSyncTransport

// A replaced saved queries store refills only from a full fetch: a delta never resends what this Mac pulled.
extension SyncCoordinator {
    private static let refillLogger = Logger(subsystem: "com.TablePro", category: "SyncSavedQueriesRefill")

    func clearTokenForSavedQueriesRefill(settings: SyncSettings) async {
        guard settings.syncSQLFavorites, await services.sqlFavoriteManager.isAwaitingSyncRefill() else { return }
        metadataStorage.saveToken(nil)
        Self.refillLogger.info("Saved queries were set aside as damaged: cleared sync token for full fetch")
    }

    // A saved query the fetch could not read never reached the store, so the refill waits for the next full fetch.
    func finishSavedQueriesRefill(after result: PullResult, settings: SyncSettings) async {
        guard settings.syncSQLFavorites else { return }
        let leftSavedQueriesUnread = result.unreadRecordIDs.contains { recordID in
            guard let type = SyncRecordMapper.parse(recordName: recordID.recordName)?.type else { return false }
            return type == .favorite || type == .favoriteFolder
        }
        guard !leftSavedQueriesUnread else {
            Self.refillLogger.info("A full fetch left saved queries unread: the refill waits for the next one")
            return
        }
        await services.sqlFavoriteManager.finishSyncRefill()
    }
}
