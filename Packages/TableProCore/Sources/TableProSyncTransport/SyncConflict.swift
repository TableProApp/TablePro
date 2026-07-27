import CloudKit
import Foundation

public struct SyncConflict: Identifiable, Sendable {
    public let id: UUID
    public let recordType: SyncRecordType
    public let entityName: String
    public let localModifiedAt: Date
    public let serverModifiedAt: Date
    public let serverRecord: CKRecord

    public init(
        recordType: SyncRecordType,
        entityName: String,
        localModifiedAt: Date,
        serverModifiedAt: Date,
        serverRecord: CKRecord
    ) {
        self.id = UUID()
        self.recordType = recordType
        self.entityName = entityName
        self.localModifiedAt = localModifiedAt
        self.serverModifiedAt = serverModifiedAt
        self.serverRecord = serverRecord
    }
}

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case error(String)
}
