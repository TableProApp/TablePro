//
//  SyncCoordinator+TableFolders.swift
//  TablePro
//

import CloudKit
import Foundation
import os
import TableProSyncTransport

/// Table folders and the objects filed in them, as two record types.
///
/// Only the folders of a connection this Mac syncs go up: one it holds, that is not Local only and
/// not the sample. The rest are skipped rather than discarded, the way database favorites are, so
/// they stay dirty and go up the moment the connection is included in sync. Tombstones are not
/// filtered: a deletion only ever removes something.
extension SyncCoordinator {
    func collectTableFolders(snapshot: SyncEditSnapshot, into batch: inout SyncPushBatch, zoneID: CKRecordZone.ID) {
        appendTombstones(of: .tableFolder, to: &batch, zoneID: zoneID)
        appendTombstones(of: .tableFolderItem, to: &batch, zoneID: zoneID)

        let dirtyFolderIds = snapshot.dirtyIds(for: .tableFolder)
        let dirtyItemIds = snapshot.dirtyIds(for: .tableFolderItem)
        guard !dirtyFolderIds.isEmpty || !dirtyItemIds.isEmpty,
              let connections = folderSyncConnections() else { return }
        let storage = services.tableFolderStorage
        for folder in storage.allFolders()
        where dirtyFolderIds.contains(folder.id.uuidString) && connections.synced.contains(folder.scope.connectionId) {
            batch.records.append(SyncRecordMapper.toCKRecord(tableFolder: folder, in: zoneID))
        }
        for item in storage.allItems()
        where dirtyItemIds.contains(item.syncId) && connections.synced.contains(item.scope.connectionId) {
            batch.records.append(SyncRecordMapper.toCKRecord(tableFolderItem: item, in: zoneID))
        }
    }

    func tableFolderSyncIds() -> (folders: [String], items: [String]) {
        let storage = services.tableFolderStorage
        return (storage.allFolders().map(\.id.uuidString), storage.allItems().map(\.syncId))
    }

    /// Applied as one batch after the pull's own loop, because a pull carries no order and a
    /// placement can arrive before the folder it names. A record this Mac changed or deleted and
    /// has not pushed yet is skipped: the local edit goes up next and wins, where applying the pull
    /// first would have pushed the remote value back over it and lost the edit.
    func applyRemoteTableFolderRecords(_ records: [CKRecord]) {
        guard !records.isEmpty, let connections = folderSyncConnections() else { return }
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
        services.tableFolderStorage.applyRemote(folders: folders, items: items, excluding: connections.keptLocal)
    }

    /// A deletion loses to a change this Mac has not pushed yet, the same way a remote edit does. A
    /// folder restored by Undo while its own deletion was on the way up would otherwise be deleted
    /// again by the echo of that deletion.
    func applyRemoteTableFolderDeletions(folderIds: Set<UUID>, itemSyncIds: Set<String>) {
        guard !folderIds.isEmpty || !itemSyncIds.isEmpty, let connections = folderSyncConnections() else { return }
        let dirtyFolders = changeTracker.dirtyRecords(for: .tableFolder)
        services.tableFolderStorage.removeRemote(
            folderIds: folderIds.filter { !dirtyFolders.contains($0.uuidString) },
            itemSyncIds: itemSyncIds.subtracting(changeTracker.dirtyRecords(for: .tableFolderItem)),
            excluding: connections.keptLocal
        )
    }

    private func unpushedIds(of type: SyncRecordType) -> Set<String> {
        Set(metadataStorage.tombstones(for: type).map(\.id)).union(changeTracker.dirtyRecords(for: type))
    }

    /// Nil when the connection store could not be read, which holds folders back in both directions:
    /// nothing can then say which connections are kept Local only.
    private func folderSyncConnections() -> (synced: Set<UUID>, keptLocal: Set<UUID>)? {
        let connections = services.connectionStorage.loadConnections()
        guard !services.connectionStorage.lastLoadFailed else { return nil }
        return (
            synced: Set(connections.filter { !$0.localOnly && !$0.isSample }.map(\.id)),
            keptLocal: Set(connections.filter(\.localOnly).map(\.id))
        )
    }
}
