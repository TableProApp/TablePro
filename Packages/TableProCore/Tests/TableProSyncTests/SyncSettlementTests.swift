import CloudKit
import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync settlement")
struct SyncSettlementTests {
    private static let storageFull = SyncStepFailure(
        failure: .blocked(.storageFull),
        error: .blocked(.storageFull),
        retryAfter: 316
    )

    @Test("A clean full run is synced, moves Last Synced and restarts the backoff")
    func cleanFullRun() {
        let settlement = SyncSettlement(failure: nil, admission: .full, previousError: .blocked(.storageFull))

        #expect(settlement.status == .idle)
        #expect(settlement.stampsLastSync)
        #expect(settlement.resetsRetry)
        #expect(settlement.countedFailure == nil)
        #expect(!settlement.needsUpload)
    }

    /// The reported bug: the person saw the first item's raw CloudKit text, and "Last Synced" was
    /// the only hint that nothing had gone up in 24 days.
    @Test("Full storage is the status, counts as a failure and leaves Last Synced alone")
    func storageFullRun() {
        let settlement = SyncSettlement(failure: Self.storageFull, admission: .full, previousError: nil)

        #expect(settlement.status == .error(.blocked(.storageFull)))
        #expect(!settlement.stampsLastSync)
        #expect(settlement.countedFailure == .blocked(.storageFull))
    }

    @Test("A download while uploads are held keeps the blocker and the backoff")
    func downloadWhileHeld() {
        let settlement = SyncSettlement(failure: nil, admission: .downloadOnly, previousError: .blocked(.storageFull))

        #expect(settlement.status == .error(.blocked(.storageFull)))
        #expect(!settlement.stampsLastSync)
        #expect(!settlement.resetsRetry)
        #expect(settlement.countedFailure == nil)
    }

    @Test("A download that stumbles while uploads are held keeps the reason they are held")
    func downloadFailureKeepsBlocker() {
        let offline = SyncStepFailure(failure: .offline, error: .offline, retryAfter: nil)
        let settlement = SyncSettlement(failure: offline, admission: .downloadOnly, previousError: .blocked(.storageFull))

        #expect(settlement.status == .error(.blocked(.storageFull)))
        #expect(settlement.countedFailure == nil)
    }

    @Test("A blocker found by a download replaces the one it ran under")
    func downloadFindsAnotherBlocker() {
        let signedOut = SyncStepFailure(failure: .blocked(.signedOut), error: .blocked(.signedOut), retryAfter: nil)
        let settlement = SyncSettlement(failure: signedOut, admission: .downloadOnly, previousError: .blocked(.storageFull))

        #expect(settlement.status == .error(.blocked(.signedOut)))
    }

    @Test("Deleted data found again by a download clears the blocker")
    func deletedDataComesBack() {
        let settlement = SyncSettlement(
            failure: nil,
            admission: .downloadOnly,
            previousError: .blocked(.dataDeletedFromICloud)
        )

        #expect(settlement.status == .idle)
        #expect(settlement.resetsRetry)
        #expect(!settlement.stampsLastSync)
        #expect(settlement.needsUpload)
    }

    /// A cancelled run used to come back as no error, which the coordinator read as success.
    @Test("A cancelled run reports nothing, success least of all")
    func cancellationChangesNothing() {
        let cancelled = SyncStepFailure(CancellationError())
        let fromIdle = SyncSettlement(failure: cancelled, admission: .full, previousError: nil)
        let fromError = SyncSettlement(failure: cancelled, admission: .full, previousError: .offline)

        #expect(fromIdle.status == .idle)
        #expect(!fromIdle.stampsLastSync)
        #expect(fromIdle.countedFailure == nil)
        #expect(fromError.status == .error(.offline))
    }

    @Test("Records refused one by one still move Last Synced: everything else went through")
    func recordRejectionsStampLastSync() {
        let rejected = SyncStepFailure(failure: .failed, error: .recordsRejected(count: 2), retryAfter: nil)
        let settlement = SyncSettlement(failure: rejected, admission: .full, previousError: nil)

        #expect(settlement.status == .error(.recordsRejected(count: 2)))
        #expect(settlement.stampsLastSync)
    }

    @Test("A failed download in a full run does not move Last Synced")
    func failedDownload() {
        let settlement = SyncSettlement(failure: .pullNotSaved, admission: .full, previousError: nil)

        #expect(settlement.status == .error(.pullNotSaved))
        #expect(!settlement.stampsLastSync)
    }

    @Test("The upload's blocker decides a run whose download failed for a lesser reason")
    func blockerWinsOverDownloadFailure() {
        let offline = SyncStepFailure(failure: .offline, error: .offline, retryAfter: nil)

        #expect(SyncStepFailure.decisive(upload: Self.storageFull, download: offline) == Self.storageFull)
        #expect(SyncStepFailure.decisive(upload: nil, download: offline) == offline)
        #expect(SyncStepFailure.decisive(upload: offline, download: .pullNotSaved) == .pullNotSaved)
        #expect(SyncStepFailure.decisive(upload: nil, download: nil) == nil)
    }

    @Test("A step failure reads the wait CloudKit named, including inside a partial failure")
    func stepFailureReadsRetryAfter() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
        let item = CKRecord.ID(recordName: "Connection_A", zoneID: zoneID)
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [item: CKError(.quotaExceeded, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 316)])]
        ])

        let failure = SyncStepFailure(partial)

        #expect(failure.failure == .blocked(.storageFull))
        #expect(failure.error == .blocked(.storageFull))
        #expect(failure.retryAfter == 316)
    }
}
