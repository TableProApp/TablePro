import CloudKit
import Foundation

public struct SyncItemFailure: Sendable {
    public let code: CKError.Code
    public let serverRecord: CKRecord?
    public let clientRecord: CKRecord?

    /// The wait CloudKit named for this item, which it sends with a throttle and with full storage.
    public let retryAfter: TimeInterval?

    /// CloudKit's own description, for the log only: untranslated, with the record id in it.
    public let message: String

    public init(
        code: CKError.Code,
        serverRecord: CKRecord?,
        clientRecord: CKRecord?,
        retryAfter: TimeInterval? = nil,
        message: String
    ) {
        self.code = code
        self.serverRecord = serverRecord
        self.clientRecord = clientRecord
        self.retryAfter = retryAfter
        self.message = message
    }

    public init(error: Error) {
        let ckError = error as? CKError
        self.code = ckError?.code ?? .internalError
        self.serverRecord = ckError?.serverRecord
        self.clientRecord = ckError?.clientRecord
        self.retryAfter = ckError?.retryAfterSeconds
        self.message = error.localizedDescription
    }

    public var failure: SyncFailure { SyncFailure(code: code) }

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

    public var isEmpty: Bool {
        savedRecords.isEmpty && deletedRecordIDs.isEmpty && failures.isEmpty
    }

    public var conflicts: [CKRecord.ID: SyncItemFailure] {
        failures.filter(\.value.isConflict)
    }

    /// What the failed items amount to. Nil when every item went through.
    public var failure: SyncFailure? {
        SyncFailure.mostSevere(failures.values.map(\.failure))
    }

    /// The longest wait any failed item named.
    public var retryAfter: TimeInterval? {
        failures.values.compactMap(\.retryAfter).max()
    }

    /// The run's outcome as the person sees it. Items refused one by one are counted; any other
    /// failure stands for the whole run, because every item it touched failed for the same reason.
    public var error: SyncError? {
        guard let failure else { return nil }
        guard failure == .failed else { return SyncError(failure) }
        return .recordsRejected(count: failures.count)
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

    public mutating func acceptMissingDeletions(of deletions: [CKRecord.ID]) {
        for recordID in deletions where failures[recordID]?.code == .unknownItem {
            failures[recordID] = nil
            deletedRecordIDs.insert(recordID)
        }
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

public struct SyncPushInterruption: Error, Sendable {
    public let completed: PushOutcome
    public let cause: any Error

    public init(completed: PushOutcome, cause: any Error) {
        self.completed = completed
        self.cause = cause
    }

    public static func after(_ completed: PushOutcome, failingWith error: any Error) -> any Error {
        if let interruption = error as? SyncPushInterruption {
            var merged = completed
            merged.merge(interruption.completed)
            return SyncPushInterruption(completed: merged, cause: interruption.cause)
        }
        guard !completed.isEmpty else { return error }
        return SyncPushInterruption(completed: completed, cause: error)
    }
}
