import CloudKit
import Foundation
import os
import TableProSyncTransport

// CloudKit as the core engine's transport meets it: a signed-in account, a zone of records, and per-call scripts for
// what CloudKit answers. A modify can be held until its task is cancelled, the way an upload in flight stays open.
final class FakeCloudKitDatabase: CloudKitDatabase, @unchecked Sendable {
    struct State {
        var status: CKAccountStatus = .available
        var signedIn = "_alice"
        var userRecordReads = 0
        var savedZones: [CKRecordZone.ID] = []
        var deletedZones: [CKRecordZone.ID] = []
        var subscriptions: [String] = []
        var fetchTokens: [CKServerChangeToken?] = []
        var page = CloudKitChangesPage()
        var records: [String: CKRecord] = [:]
        var modifyCalls: [(saves: [CKRecord], deletes: [CKRecord.ID])] = []
        var modifiesCancelled = 0
        var failure: (any Error)?
        var saveResults: [String: any Error] = [:]
        var deleteResults: [String: any Error] = [:]
        var fetchResults: [String: any Error] = [:]
        // Modifies still to hold open until their task is cancelled.
        var modifiesToHold = 0
        // The account signed in once the operation ran, as when the person switches during the call.
        var signedInAfterOperation: String?
    }

    let state = OSAllocatedUnfairLock(uncheckedState: State())

    func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { change(&$0) }
    }

    func read<Value>(_ value: (State) -> Value) -> Value {
        state.withLockUnchecked { value($0) }
    }

    var modifyStarted: Int {
        read { $0.modifyCalls.count }
    }

    func accountStatus() async throws -> CKAccountStatus {
        let (status, failure) = read { ($0.status, $0.failure) }
        if let failure { throw failure }
        return status
    }

    func userRecordName() async throws -> String {
        state.withLockUnchecked { state in
            state.userRecordReads += 1
            return state.signedIn
        }
    }

    func saveZone(_ zone: CKRecordZone.ID) async throws {
        try operation { $0.savedZones.append(zone) }
    }

    func deleteZone(_ zone: CKRecordZone.ID) async throws {
        try operation { $0.deletedZones.append(zone) }
    }

    func saveSubscription(_ subscription: CKSubscription) async throws {
        try operation { $0.subscriptions.append(subscription.subscriptionID) }
    }

    func fetchChanges(in zone: CKRecordZone.ID, since token: CKServerChangeToken?) async throws -> CloudKitChangesPage {
        try operation { state in
            state.fetchTokens.append(token)
            return state.page
        }
    }

    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        try operation { state in
            var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
            for id in ids {
                if let error = state.fetchResults[id.recordName] {
                    results[id] = .failure(error)
                } else if let record = state.records[id.recordName] {
                    results[id] = .success(record)
                } else {
                    results[id] = .failure(CKError(.unknownItem))
                }
            }
            return results
        }
    }

    func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> CloudKitModifyResults {
        let holds = state.withLockUnchecked { state -> Bool in
            state.modifyCalls.append((records, ids))
            guard state.modifiesToHold > 0 else { return false }
            state.modifiesToHold -= 1
            return true
        }
        if holds {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                update { $0.modifiesCancelled += 1 }
                throw CKError(.operationCancelled)
            }
        }
        return try operation { state in
            var results = CloudKitModifyResults()
            for record in records {
                if let error = state.saveResults[record.recordID.recordName] {
                    results.saved[record.recordID] = .failure(error)
                } else {
                    state.records[record.recordID.recordName] = record
                    results.saved[record.recordID] = .success(record)
                }
            }
            for id in ids {
                if let error = state.deleteResults[id.recordName] {
                    results.deleted[id] = .failure(error)
                } else {
                    state.records[id.recordName] = nil
                    results.deleted[id] = .success(())
                }
            }
            return results
        }
    }

    private func operation<Value>(_ body: (inout State) throws -> Value) throws -> Value {
        try state.withLockUnchecked { state in
            if let failure = state.failure { throw failure }
            let value = try body(&state)
            if let next = state.signedInAfterOperation {
                state.signedIn = next
            }
            return value
        }
    }
}
