import CloudKit
import Foundation
import os

// The CloudKit operations the core engine's transport runs (core ADR 0054, The CloudKit transport), one operation per
// call. Nothing here retries, splits a batch or keeps a token: the engine does. A cancelled task cancels its operation,
// and a task cancelled before the call starts none.
public protocol CloudKitDatabase: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func userRecordName() async throws -> String
    func saveZone(_ zone: CKRecordZone.ID) async throws
    func deleteZone(_ zone: CKRecordZone.ID) async throws
    func saveSubscription(_ subscription: CKSubscription) async throws
    func fetchChanges(in zone: CKRecordZone.ID, since token: CKServerChangeToken?) async throws -> CloudKitChangesPage
    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> CloudKitModifyResults
}

public struct CloudKitChangesPage: Sendable {
    public var changed: [CKRecord]
    // Reported changed, but the fetch of the record itself failed.
    public var unread: [CKRecord.ID]
    public var deleted: [CloudKitDeletedRecord]
    public var token: CKServerChangeToken?
    public var moreComing: Bool

    public init(
        changed: [CKRecord] = [],
        unread: [CKRecord.ID] = [],
        deleted: [CloudKitDeletedRecord] = [],
        token: CKServerChangeToken? = nil,
        moreComing: Bool = false
    ) {
        self.changed = changed
        self.unread = unread
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

public struct CloudKitDeletedRecord: Sendable, Equatable {
    public let id: CKRecord.ID
    public let recordType: CKRecord.RecordType

    public init(id: CKRecord.ID, recordType: CKRecord.RecordType) {
        self.id = id
        self.recordType = recordType
    }
}

public struct CloudKitModifyResults: Sendable {
    public var saved: [CKRecord.ID: Result<CKRecord, any Error>]
    public var deleted: [CKRecord.ID: Result<Void, any Error>]

    public init(saved: [CKRecord.ID: Result<CKRecord, any Error>] = [:], deleted: [CKRecord.ID: Result<Void, any Error>] = [:]) {
        self.saved = saved
        self.deleted = deleted
    }
}

public enum CloudKitRecordID {
    // `CKRecord.ID(recordName:zoneID:)` raises past CloudKit's limit instead of failing (`SyncRecordName`), and a
    // raise inside a Swift task crashes the app later, so a name that does not fit gets no ID.
    public static func make(name: String, in zone: CKRecordZone.ID) -> CKRecord.ID? {
        let length = (name as NSString).length
        guard length > 0, length <= SyncRecordName.maximumLength else { return nil }
        return CKRecord.ID(recordName: name, zoneID: zone)
    }
}

public struct LiveCloudKitDatabase: CloudKitDatabase {
    private let containers: LazyContainer

    // The container is made on the first call, so none exists while sync stays off.
    public init(containerIdentifier: String = CloudKitSyncEngine.defaultContainerID) {
        containers = LazyContainer(identifier: containerIdentifier)
    }

    private func database() throws -> CKDatabase {
        try containers.container().privateCloudDatabase
    }

    public func accountStatus() async throws -> CKAccountStatus {
        try await containers.container().accountStatus()
    }

    public func userRecordName() async throws -> String {
        try await containers.container().userRecordID().recordName
    }

    // One zone or subscription per operation, so its own error is the call's, not the partial failure around it.
    public func saveZone(_ zone: CKRecordZone.ID) async throws {
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: zone)], recordZoneIDsToDelete: nil)
        let itemFailure = Accumulator<(any Error)?>(nil)
        try await run(operation, on: database()) { finish in
            operation.perRecordZoneSaveBlock = { _, result in
                if case .failure(let error) = result { itemFailure.update { $0 = error } }
            }
            operation.modifyRecordZonesResultBlock = { finish(Self.itemFailure(itemFailure.value, over: $0)) }
        }
    }

    public func deleteZone(_ zone: CKRecordZone.ID) async throws {
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [zone])
        let itemFailure = Accumulator<(any Error)?>(nil)
        try await run(operation, on: database()) { finish in
            operation.perRecordZoneDeleteBlock = { _, result in
                if case .failure(let error) = result { itemFailure.update { $0 = error } }
            }
            operation.modifyRecordZonesResultBlock = { finish(Self.itemFailure(itemFailure.value, over: $0)) }
        }
    }

    public func saveSubscription(_ subscription: CKSubscription) async throws {
        let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
        let itemFailure = Accumulator<(any Error)?>(nil)
        try await run(operation, on: database()) { finish in
            operation.perSubscriptionSaveBlock = { _, result in
                if case .failure(let error) = result { itemFailure.update { $0 = error } }
            }
            operation.modifySubscriptionsResultBlock = { finish(Self.itemFailure(itemFailure.value, over: $0)) }
        }
    }

    public func fetchChanges(in zone: CKRecordZone.ID, since token: CKServerChangeToken?) async throws -> CloudKitChangesPage {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: configuration])
        // One page per call, so the engine commits each page before it asks for the next.
        operation.fetchAllChanges = false
        let page = Accumulator(CloudKitChangesPage())
        let zoneFailure = Accumulator<(any Error)?>(nil)
        try await run(operation, on: database()) { finish in
            operation.recordWasChangedBlock = { id, result in
                page.update { page in
                    switch result {
                    case .success(let record): page.changed.append(record)
                    case .failure: page.unread.append(id)
                    }
                }
            }
            operation.recordWithIDWasDeletedBlock = { id, recordType in
                page.update { $0.deleted.append(CloudKitDeletedRecord(id: id, recordType: recordType)) }
            }
            operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                page.update { $0.token = token }
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (token, _, moreComing)):
                    page.update {
                        $0.token = token
                        $0.moreComing = moreComing
                    }
                case .failure(let error):
                    zoneFailure.update { $0 = error }
                }
            }
            // An expired token or a deleted zone is reported for the zone, inside a partial failure that says only that
            // something failed, so the zone's own error decides. Without one, the failed records are the page's unread.
            operation.fetchRecordZoneChangesResultBlock = { result in
                if let error = zoneFailure.value {
                    finish(.failure(error))
                } else {
                    finish(Self.keepingItemFailures(result))
                }
            }
        }
        return page.value
    }

    public func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        guard !ids.isEmpty else { return [:] }
        let operation = CKFetchRecordsOperation(recordIDs: ids)
        let results = Accumulator<[CKRecord.ID: Result<CKRecord, any Error>]>([:])
        try await run(operation, on: database()) { finish in
            operation.perRecordResultBlock = { id, result in
                results.update { $0[id] = result }
            }
            operation.fetchRecordsResultBlock = { result in
                finish(Self.keepingItemFailures(result))
            }
        }
        return results.value
    }

    public func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> CloudKitModifyResults {
        guard !records.isEmpty || !ids.isEmpty else { return CloudKitModifyResults() }
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: ids)
        // A save rebuilt from system fields that are no longer the server's is refused with the server's copy.
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = false
        let results = Accumulator(CloudKitModifyResults())
        try await run(operation, on: database()) { finish in
            operation.perRecordSaveBlock = { id, result in
                results.update { $0.saved[id] = result }
            }
            operation.perRecordDeleteBlock = { id, result in
                results.update { $0.deleted[id] = result }
            }
            operation.modifyRecordsResultBlock = { result in
                finish(Self.keepingItemFailures(result))
            }
        }
        return results.value
    }

    private static func itemFailure(_ item: (any Error)?, over result: Result<Void, any Error>) -> Result<Void, any Error> {
        if case .failure(let error as CKError) = result, error.code == .partialFailure, let item {
            return .failure(item)
        }
        return result
    }

    // Each item's failure reached its own block, so a partial failure is no failure of the call.
    private static func keepingItemFailures(_ result: Result<Void, any Error>) -> Result<Void, any Error> {
        if case .failure(let error as CKError) = result, error.code == .partialFailure {
            return .success(())
        }
        return result
    }

    private func run(
        _ operation: CKDatabaseOperation,
        on database: CKDatabase,
        configure: (@escaping @Sendable (Result<Void, any Error>) -> Void) -> Void
    ) async throws {
        try Task.checkCancellation()
        let cancellable = CancellableOperation(operation)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                configure { continuation.resume(with: $0) }
                database.add(operation)
            }
        } onCancel: {
            cancellable.cancel()
        }
    }
}

// A build without the iCloud entitlement fails every call as CloudKit itself would; creating the container would crash
// it.
private final class LazyContainer: Sendable {
    private let identifier: String
    private let made = OSAllocatedUnfairLock<CKContainer?>(uncheckedState: nil)

    init(identifier: String) {
        self.identifier = identifier
    }

    func container() throws -> CKContainer {
        let container = made.withLockUnchecked { made -> CKContainer? in
            if let made { return made }
            guard CloudKitEntitlement.isGrantedToCurrentProcess() else { return nil }
            made = CKContainer(identifier: identifier)
            return made
        }
        guard let container else { throw CKError(.missingEntitlement) }
        return container
    }
}

// An operation cancelled before it is added finishes at once with `operationCancelled` once added.
private final class CancellableOperation: @unchecked Sendable {
    private let operation: Operation

    init(_ operation: Operation) {
        self.operation = operation
    }

    func cancel() {
        operation.cancel()
    }
}

// CloudKit calls an operation's blocks on its own queue, one at a time, and the completion block last.
private final class Accumulator<Value>: @unchecked Sendable {
    private let stored: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        stored = OSAllocatedUnfairLock(uncheckedState: value)
    }

    var value: Value {
        stored.withLockUnchecked { $0 }
    }

    func update(_ change: (inout Value) -> Void) {
        stored.withLockUnchecked { change(&$0) }
    }
}
