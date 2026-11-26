import CloudKit
import Foundation
import os
import TableProSyncTransport

// CloudKit as the engine's transport meets it, signed in, saving whatever it is sent. A modify can be held open until
// its task is cancelled or the test lets it go, the way an upload in flight stays open.
nonisolated final class HeldCloudKitDatabase: CloudKitDatabase, @unchecked Sendable {
    struct State {
        var signedIn = "_alice"
        var modifyCalls = 0
        var modifiesCancelled = 0
        var holdNextModify = false
        var release: CheckedContinuation<Void, any Error>?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var modifyStarted: Int {
        state.withLockUnchecked { $0.modifyCalls }
    }

    var modifiesCancelled: Int {
        state.withLockUnchecked { $0.modifiesCancelled }
    }

    func holdNextModify() {
        state.withLockUnchecked { $0.holdNextModify = true }
    }

    // Lets a held modify finish as CloudKit answered it.
    func releaseHeldModify() {
        let release = state.withLockUnchecked { state -> CheckedContinuation<Void, any Error>? in
            defer { state.release = nil }
            return state.release
        }
        release?.resume()
    }

    func accountStatus() async throws -> CKAccountStatus { .available }

    func userRecordName() async throws -> String {
        state.withLockUnchecked { $0.signedIn }
    }

    func saveZone(_ zone: CKRecordZone.ID) async throws {}

    func deleteZone(_ zone: CKRecordZone.ID) async throws {}

    func saveSubscription(_ subscription: CKSubscription) async throws {}

    func fetchChanges(in zone: CKRecordZone.ID, since token: CKServerChangeToken?) async throws -> CloudKitChangesPage {
        CloudKitChangesPage()
    }

    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        [:]
    }

    func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> CloudKitModifyResults {
        let holds = state.withLockUnchecked { state -> Bool in
            state.modifyCalls += 1
            defer { state.holdNextModify = false }
            return state.holdNextModify
        }
        if holds {
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        state.withLockUnchecked { $0.release = continuation }
                    }
                } onCancel: { [state] in
                    let release = state.withLockUnchecked { state -> CheckedContinuation<Void, any Error>? in
                        defer { state.release = nil }
                        return state.release
                    }
                    release?.resume(throwing: CancellationError())
                }
            } catch {
                state.withLockUnchecked { $0.modifiesCancelled += 1 }
                throw CKError(.operationCancelled)
            }
        }
        var results = CloudKitModifyResults()
        for record in records {
            results.saved[record.recordID] = .success(record)
        }
        for id in ids {
            results.deleted[id] = .success(())
        }
        return results
    }
}
