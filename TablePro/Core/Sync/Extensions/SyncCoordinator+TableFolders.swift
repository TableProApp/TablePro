//
//  SyncCoordinator+TableFolders.swift
//  TablePro
//

import CloudKit
import Foundation
import os
import TableProSyncTransport

extension SyncCoordinator {
    func tableFolderSyncIds() -> (folders: [String], items: [String]) {
        let storage = services.tableFolderStorage
        return (storage.allFolders().map(\.id.uuidString), storage.allItems().map(\.syncId))
    }

    /// Applied as one batch after the pull's own loop, because a pull carries no order and a
    /// placement can arrive before the folder it names. A record this Mac changed or deleted and
    /// has not pushed yet is skipped: the local edit goes up next and wins, where applying the pull
    /// first would have pushed the remote value back over it and lost the edit.
    func applyRemoteTableFolderRecords(_ records: [CKRecord]) {
        guard !records.isEmpty, let excluded = folderPullExclusions() else { return }
        let pendingFolders = unpushedIds(of: .tableFolder)
        let pendingItems = unpushedIds(of: .tableFolderItem)
        var folders: [TableFolder] = []
        var items: [TableFolderItem] = []
        for record in records {
            do {
                if record.recordType == SyncRecordType.tableFolder.rawValue {
                    let folder = try SyncRecordMapper.tableFolder(from: record)
                    guard !pendingFolders.contains(folder.id.uuidString) else { continue }
                    folders.append(folder)
                } else {
                    let item = try SyncRecordMapper.tableFolderItem(from: record)
                    guard !pendingItems.contains(item.syncId) else { continue }
                    items.append(item)
                }
            } catch {
                Self.logger.error(
                    "Skipping remote table folder record \(record.recordID.recordName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)"
                )
            }
        }
        services.tableFolderStorage.applyRemote(folders: folders, items: items, excluding: excluded)
    }

    /// A deletion loses to a change this Mac has not pushed yet, the same way a remote edit does. A
    /// folder restored by Undo while its own deletion was on the way up would otherwise be deleted
    /// again by the echo of that deletion.
    func applyRemoteTableFolderDeletions(folderIds: Set<UUID>, itemSyncIds: Set<String>) {
        guard !folderIds.isEmpty || !itemSyncIds.isEmpty, let excluded = folderPullExclusions() else { return }
        let dirtyFolders = changeTracker.dirtyRecords(for: .tableFolder)
        services.tableFolderStorage.removeRemote(
            folderIds: folderIds.filter { !dirtyFolders.contains($0.uuidString) },
            itemSyncIds: itemSyncIds.subtracting(changeTracker.dirtyRecords(for: .tableFolderItem)),
            excluding: excluded
        )
    }

    private func unpushedIds(of type: SyncRecordType) -> Set<String> {
        Set(metadataStorage.tombstones(for: type).map(\.id)).union(changeTracker.dirtyRecords(for: type))
    }

    /// Nil when the connection store could not be read, and then no pulled folder change is applied:
    /// nothing can say which connections are kept off iCloud.
    private func folderPullExclusions() -> Set<UUID>? {
        syncBoundary(settings: services.appSettingsStorage.loadSync()).excludedConnectionIds
    }
}
