import CloudKit
import Foundation

public struct SyncConflict: Identifiable, Sendable {
    public let id: UUID
    public let recordType: SyncRecordType
    public let entityName: String
    public let localRecord: CKRecord
    public let localModifiedAt: Date
    public let serverModifiedAt: Date
    public let serverRecord: CKRecord

    public init(
        recordType: SyncRecordType,
        entityName: String,
        localRecord: CKRecord,
        serverRecord: CKRecord,
        localModifiedAt: Date,
        serverModifiedAt: Date
    ) {
        self.id = UUID()
        self.recordType = recordType
        self.entityName = entityName
        self.localRecord = localRecord
        self.localModifiedAt = localModifiedAt
        self.serverModifiedAt = serverModifiedAt
        self.serverRecord = serverRecord
    }

    public init(
        recordType: SyncRecordType,
        entityName: String,
        localModifiedAt: Date,
        serverModifiedAt: Date,
        serverRecord: CKRecord
    ) {
        self.init(
            recordType: recordType,
            entityName: entityName,
            localRecord: serverRecord,
            serverRecord: serverRecord,
            localModifiedAt: localModifiedAt,
            serverModifiedAt: serverModifiedAt
        )
    }
}
