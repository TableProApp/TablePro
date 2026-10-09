import CloudKit
import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync error")
struct SyncErrorTests {
    @Test("A classified failure becomes the outcome the person is shown", arguments: [
        (SyncFailure.blocked(.storageFull), SyncError.blocked(.storageFull)),
        (SyncFailure.blocked(.signedOut), SyncError.blocked(.signedOut)),
        (SyncFailure.offline, SyncError.offline),
        (SyncFailure.busy, SyncError.busy),
        (SyncFailure.failed, SyncError.unexpected),
        (SyncFailure.tokenExpired, SyncError.unexpected)
    ])
    func failureMapsToOutcome(_ failure: SyncFailure, _ expected: SyncError) {
        #expect(SyncError(failure) == expected)
    }

    /// A debounced run cancelled by the next edit used to settle as an unknown error and flash
    /// "Sync Error" until the next run replaced it.
    @Test("A cancellation is not an outcome")
    func cancellationIsNotAnOutcome() {
        #expect(SyncError(SyncFailure.cancelled) == nil)
        #expect(SyncError(CancellationError()) == nil)
        #expect(SyncError(CKError(.operationCancelled)) == nil)
    }

    @Test("A thrown CloudKit error is classified the same way")
    func thrownErrorIsClassified() {
        #expect(SyncError(CKError(.quotaExceeded)) == .blocked(.storageFull))
        #expect(SyncError(CKError(.requestRateLimited)) == .busy)
        #expect(SyncError(CKError(.internalError)) == .unexpected)
    }

    @Test("Only a blocked outcome names a blocker")
    func blockerIsExposed() {
        #expect(SyncError.blocked(.accountRestricted).blocker == .accountRestricted)
        #expect(SyncError.offline.blocker == nil)
        #expect(SyncError.recordsRejected(count: 2).blocker == nil)
    }

    @Test("Rejections with different counts are not equal")
    func rejectionsCompareByPayload() {
        #expect(SyncError.recordsRejected(count: 1) != .recordsRejected(count: 2))
        #expect(SyncError.recordsRejected(count: 1) == .recordsRejected(count: 1))
    }
}
