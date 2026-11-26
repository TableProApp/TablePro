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
        // A cancel that came before the hold was in place, which the hold then answers at once.
        var cancelledBeforeHold = false
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
            defer { state.holdNextModify = false }
            if !state.holdNextModify {
                state.modifyCalls += 1
            }
            return state.holdNextModify
        }
        if holds {
            try await hold()
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

    // Counted as started once the hold is in place, so a test that waits for the start cancels a held call.
    private func hold() async throws {
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let cancelled = state.withLockUnchecked { state -> Bool in
                        state.modifyCalls += 1
                        guard !state.cancelledBeforeHold else { return true }
                        state.release = continuation
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: { [state] in
                let release = state.withLockUnchecked { state -> CheckedContinuation<Void, any Error>? in
                    guard let release = state.release else {
                        state.cancelledBeforeHold = true
                        return nil
                    }
                    state.release = nil
                    return release
                }
                release?.resume(throwing: CancellationError())
            }
        } catch {
            state.withLockUnchecked { state in
                state.modifiesCancelled += 1
                state.cancelledBeforeHold = false
            }
            throw CKError(.operationCancelled)
        }
    }
}
