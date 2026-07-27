import CloudKit
import Foundation

public struct SyncItemFailure: Sendable {
    public let code: CKError.Code
    public let serverRecord: CKRecord?
    public let clientRecord: CKRecord?
    public let message: String

    public init(code: CKError.Code, serverRecord: CKRecord?, clientRecord: CKRecord?, message: String) {
        self.code = code
        self.serverRecord = serverRecord
        self.clientRecord = clientRecord
        self.message = message
    }

    public init(error: Error) {
        let ckError = error as? CKError
        self.code = ckError?.code ?? .internalError
        self.serverRecord = ckError?.serverRecord
        self.clientRecord = ckError?.clientRecord
        self.message = error.localizedDescription
    }

    public var isConflict: Bool { code == .serverRecordChanged }
}

public struct PushOutcome: Sendable {
    public private(set) var savedRecords: [CKRecord.ID: CKRecord]
    public private(set) var deletedRecordIDs: Set<CKRecord.ID>
    public private(set) var failures: [CKRecord.ID: SyncItemFailure]

    public init(
        savedRecords: [CKRecord.ID: CKRecord] = [:],
        deletedRecordIDs: Set<CKRecord.ID> = [],
        failures: [CKRecord.ID: SyncItemFailure] = [:]
    ) {
        self.savedRecords = savedRecords
        self.deletedRecordIDs = deletedRecordIDs
        self.failures = failures
    }

    public var hasFailures: Bool { !failures.isEmpty }

    public var conflicts: [CKRecord.ID: SyncItemFailure] {
        failures.filter(\.value.isConflict)
    }

    public func didSave(_ recordID: CKRecord.ID) -> Bool {
        savedRecords[recordID] != nil
    }

    public func didDelete(_ recordID: CKRecord.ID) -> Bool {
        deletedRecordIDs.contains(recordID)
    }

    public mutating func recordSave(_ record: CKRecord) {
        savedRecords[record.recordID] = record
        failures[record.recordID] = nil
    }

    public mutating func recordDeletion(_ recordID: CKRecord.ID) {
        deletedRecordIDs.insert(recordID)
        failures[recordID] = nil
    }

    public mutating func recordFailure(_ failure: SyncItemFailure, for recordID: CKRecord.ID) {
        guard savedRecords[recordID] == nil, !deletedRecordIDs.contains(recordID) else { return }
        failures[recordID] = failure
    }

    public mutating func merge(_ other: PushOutcome) {
        savedRecords.merge(other.savedRecords) { _, new in new }
        deletedRecordIDs.formUnion(other.deletedRecordIDs)
        failures.merge(other.failures) { _, new in new }
    }

    public mutating func absorbPartialErrors(from error: CKError) {
        guard let partial = error.partialErrorsByItemID else { return }
        for (itemID, itemError) in partial {
            guard let recordID = itemID as? CKRecord.ID else { continue }
            recordFailure(SyncItemFailure(error: itemError), for: recordID)
        }
    }
}
