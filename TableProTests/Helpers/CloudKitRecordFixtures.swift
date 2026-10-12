//
//  CloudKitRecordFixtures.swift
//  TableProTests
//

import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport

/// A record the way the server hands it back on a pull, with its fields set by key. The app's own
/// mappers write only fields verified in Production, so a record built through them cannot stand in
/// for one a device running a later schema pushed.
enum CloudKitRecordFixtures {
    static func serverRecord(
        type: SyncRecordType,
        id: String,
        in zoneID: CKRecordZone.ID,
        fields: [String: String]
    ) -> CKRecord {
        let record = CKRecord(
            recordType: type.rawValue,
            recordID: SyncRecordMapper.recordID(type: type, id: id, in: zoneID)
        )
        for (key, value) in fields {
            record.setValue(value, forKey: key)
        }
        return record
    }
}
