import Foundation
import os
import SQLite3

// A store that replaced a damaged one is not the user's library for sync until a full fetch refills it.
extension SQLFavoriteStorage {
    private static let syncRefillLogger = Logger(subsystem: "com.TablePro", category: "SQLFavoriteSyncRefill")

    func isAwaitingSyncRefill() -> Bool {
        _ = db
        return syncRefillPending
    }

    func readAllFavoritesForSync() -> [SQLFavorite]? {
        isAwaitingSyncRefill() ? nil : readAllFavorites()
    }

    func readAllFoldersForSync() -> [SQLFavoriteFolder]? {
        isAwaitingSyncRefill() ? nil : readAllFolders()
    }

    func finishSyncRefill() {
        guard isAwaitingSyncRefill() else { return }
        guard run("DROP TABLE IF EXISTS sync_refill;") else {
            Self.syncRefillLogger.error("The saved queries refill marker could not be cleared; sync keeps waiting")
            return
        }
        syncRefillPending = false
    }

    func loadSyncRefillState(afterSetAside setAside: Bool) {
        guard setAside else {
            syncRefillPending = hasSyncRefillMarker()
            return
        }
        // Pending for this session even when the marker cannot be written.
        syncRefillPending = true
        let marked = run("CREATE TABLE IF NOT EXISTS sync_refill (id INTEGER PRIMARY KEY CHECK (id = 1));")
            && run("INSERT OR IGNORE INTO sync_refill (id) VALUES (1);")
        if !marked {
            Self.syncRefillLogger.fault("The saved queries refill marker could not be written")
        }
    }

    private func hasSyncRefillMarker() -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sync_refill LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
