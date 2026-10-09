import CloudKit
import Foundation
import Testing

@testable import TableProSyncTransport

@Suite("Sync failure classification")
struct SyncFailureTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    @Test("Every CloudKit code has its meaning for sync", arguments: [
        (CKError.Code.quotaExceeded, SyncFailure.blocked(.storageFull)),
        (.notAuthenticated, .blocked(.signedOut)),
        (.accountTemporarilyUnavailable, .blocked(.accountNotReady)),
        (.managedAccountRestricted, .blocked(.accountRestricted)),
        (.userDeletedZone, .blocked(.dataDeletedFromICloud)),
        (.incompatibleVersion, .blocked(.appUpdateRequired)),
        (.badContainer, .blocked(.unavailable)),
        (.missingEntitlement, .blocked(.unavailable)),
        (.badDatabase, .blocked(.unavailable)),
        (.permissionFailure, .blocked(.unavailable)),
        (.networkUnavailable, .offline),
        (.networkFailure, .offline),
        (.serviceUnavailable, .busy),
        (.requestRateLimited, .busy),
        (.zoneBusy, .busy),
        (.serverResponseLost, .busy),
        (.changeTokenExpired, .tokenExpired),
        (.zoneNotFound, .blocked(.dataDeletedFromICloud)),
        (.operationCancelled, .cancelled),
        (.internalError, .failed),
        (.invalidArguments, .failed),
        (.serverRejectedRequest, .failed),
        (.serverRecordChanged, .failed),
        (.unknownItem, .failed),
        (.limitExceeded, .failed),
        (.batchRequestFailed, .failed),
        (.constraintViolation, .failed)
    ])
    func codeIsClassified(_ code: CKError.Code, _ expected: SyncFailure) {
        #expect(SyncFailure(code: code) == expected)
        #expect(SyncFailure(CKError(code)) == expected)
    }

    /// The reported bug: 250 deletes each failed with `quotaExceeded` inside a partial failure, and
    /// the wrapper's own code said only that items failed.
    @Test("A partial failure is judged by its most severe item")
    func partialFailureUsesItsItems() {
        let first = CKRecord.ID(recordName: "Settings_columnLayout.A", zoneID: zoneID)
        let second = CKRecord.ID(recordName: "Connection_B", zoneID: zoneID)
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                first: CKError(.batchRequestFailed),
                second: CKError(.quotaExceeded)
            ]
        ])

        #expect(SyncFailure(partial) == .blocked(.storageFull))
    }

    @Test("A partial failure without items is a plain failure")
    func emptyPartialFailureFails() {
        #expect(SyncFailure(CKError(.partialFailure)) == .failed)
    }

    @Test("An interrupted push is classified by its cause")
    func interruptionUsesItsCause() {
        let interruption = SyncPushInterruption(completed: PushOutcome(), cause: CKError(.networkFailure))
        #expect(SyncFailure(interruption) == .offline)
    }

    @Test("A cancelled task is a cancellation, and a foreign error a failure")
    func nonCloudKitErrors() {
        struct Foreign: Error {}
        #expect(SyncFailure(CancellationError()) == .cancelled)
        #expect(SyncFailure(Foreign()) == .failed)
    }

    @Test("A blocker outweighs every other failure, and an account blocker outweighs full storage")
    func severityOrdersFailures() {
        #expect(SyncFailure.mostSevere([.failed, .busy, .blocked(.storageFull), .offline]) == .blocked(.storageFull))
        #expect(SyncFailure.mostSevere([.blocked(.storageFull), .blocked(.signedOut)]) == .blocked(.signedOut))
        #expect(SyncFailure.mostSevere([.failed, .busy]) == .busy)
        #expect(SyncFailure.mostSevere([.failed, .blocked(.dataDeletedFromICloud), .offline]) == .blocked(.dataDeletedFromICloud))
        #expect(SyncFailure.mostSevere([SyncFailure]()) == nil)
    }

    @Test("Only a blocker stops the rest of an upload")
    func stopsUpload() {
        #expect(SyncFailure.blocked(.storageFull).stopsUpload)
        #expect(SyncFailure.blocked(.dataDeletedFromICloud).stopsUpload)
        #expect(!SyncFailure.failed.stopsUpload)
        #expect(!SyncFailure.busy.stopsUpload)
        #expect(!SyncFailure.offline.stopsUpload)
    }

    @Test("An account status maps to the blocker it stands for", arguments: [
        (CKAccountStatus.noAccount, SyncBlocker?.some(.signedOut)),
        (.restricted, .some(.accountRestricted)),
        (.temporarilyUnavailable, .some(.accountNotReady)),
        (.couldNotDetermine, .some(.accountNotReady)),
        (.available, nil)
    ])
    func accountStatusMaps(_ status: CKAccountStatus, _ expected: SyncBlocker?) {
        #expect(SyncBlocker(accountStatus: status) == expected)
    }
}
