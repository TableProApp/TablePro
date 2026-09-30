//
//  SyncTableFolderTests.swift
//  TableProTests
//

import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncTableFolderTests {
    private static let zoneID = CKRecordZone.ID(zoneName: "TableProSync", ownerName: CKCurrentUserDefaultName)

    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

    private func settings(syncTableFolders: Bool) -> SyncSettings {
        SyncSettings(
            enabled: true,
            syncConnections: true,
            syncGroupsAndTags: true,
            syncSettings: true,
            syncTableFolders: syncTableFolders
        )
    }

    private func serverRecord(type: SyncRecordType, id: String, fields: [String: String]) -> CKRecord {
        CloudKitRecordFixtures.serverRecord(type: type, id: id, in: Self.zoneID, fields: fields)
    }

    @Test("A folder deleted elsewhere is applied only while Table Folders sync is on")
    func deletionsFollowTheToggle() {
        let folderId = UUID()
        let itemId = TableFolderItemKey(scope: scope, name: "orders").syncId
        let ids = [
            SyncRecordMapper.recordID(type: .tableFolder, id: folderId.uuidString, in: Self.zoneID),
            SyncRecordMapper.recordID(type: .tableFolderItem, id: itemId, in: Self.zoneID)
        ]

        let on = SyncPendingDeletions.parse(ids, settings: settings(syncTableFolders: true))
        let off = SyncPendingDeletions.parse(ids, settings: settings(syncTableFolders: false))

        #expect(on.tableFolders == [folderId])
        #expect(on.tableFolderItems == [itemId])
        #expect(off.tableFolders.isEmpty)
        #expect(off.tableFolderItems.isEmpty)
    }

    @Test("A folder record from the server decodes into the folder it names")
    func folderRecordDecodes() throws {
        let id = UUID()
        let record = serverRecord(type: .tableFolder, id: id.uuidString, fields: [
            "folderId": id.uuidString,
            "connectionId": scope.connectionId.uuidString,
            "database": "shop",
            "schema": "public",
            "name": "Billing"
        ])

        let folder = try SyncRecordMapper.tableFolder(from: record)

        #expect(folder.id == id)
        #expect(folder.scope == scope)
        #expect(folder.name == "Billing")
    }

    @Test("A placement record from the server decodes into the object and its folder")
    func itemRecordDecodes() throws {
        let folderId = UUID()
        let key = TableFolderItemKey(scope: scope, name: "orders")
        let record = serverRecord(type: .tableFolderItem, id: key.syncId, fields: [
            "connectionId": scope.connectionId.uuidString,
            "database": "shop",
            "schema": "public",
            "name": "orders",
            "folderId": folderId.uuidString
        ])

        let item = try SyncRecordMapper.tableFolderItem(from: record)

        #expect(item.key == key)
        #expect(item.folderId == folderId)
    }

    @Test("A placement record naming no folder is refused")
    func itemWithoutFolderIsRefused() {
        let record = serverRecord(type: .tableFolderItem, id: "x", fields: [
            "connectionId": scope.connectionId.uuidString,
            "database": "shop",
            "name": "orders"
        ])

        #expect(throws: SyncDecodeError.self) { try SyncRecordMapper.tableFolderItem(from: record) }
    }

    @Test(
        "A folder and a placement survive a trip through their records",
        .enabled(if: TableFolderSyncField.allCases.allSatisfy(\.isWritable)
            && TableFolderItemSyncField.allCases.allSatisfy(\.isWritable))
    )
    func recordsRoundTrip() throws {
        let folder = TableFolder(scope: scope, name: "Billing")
        let item = TableFolderItem(scope: scope, name: "orders", folderId: folder.id)

        let decodedFolder = try SyncRecordMapper.tableFolder(
            from: SyncRecordMapper.toCKRecord(tableFolder: folder, in: Self.zoneID)
        )
        let decodedItem = try SyncRecordMapper.tableFolderItem(
            from: SyncRecordMapper.toCKRecord(tableFolderItem: item, in: Self.zoneID)
        )

        #expect(decodedFolder.id == folder.id)
        #expect(decodedFolder.scope == folder.scope)
        #expect(decodedFolder.name == folder.name)
        #expect(decodedItem == item)
    }
}
