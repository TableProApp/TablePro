//
//  SyncRetryPolicyTests.swift
//  TableProSyncTests
//

import CloudKit
import Foundation
@testable import TableProSyncTransport
import Testing

/// The retry decisions used to be private to `CloudKitSyncEngine` and reachable only through a real
/// `CKError` off a real network, so nothing checked either of them.
@Suite("Sync retry policy")
struct SyncRetryPolicyTests {
    /// The five the server sends to mean "ask again". Listed one by one rather than as a set, so a
    /// case dropped from the switch fails here and not in the field.
    @Test("The errors CloudKit asks to be retried are retried")
    func transientCodesAreRetried() {
        let transient: [CKError.Code] = [
            .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy,
            .serverResponseLost
        ]

        for code in transient {
            #expect(SyncRetryPolicy.isTransient(code), "\(code.rawValue) should be retried")
        }
    }

    /// A decision the server has already made. Retrying these costs three more round trips and
    /// reports the last attempt's reason instead of the real one; `.quotaExceeded` and
    /// `.permissionFailure` in particular would hide themselves behind a network-shaped failure.
    @Test("A failure the server has already decided is not retried")
    func settledFailuresAreNotRetried() {
        let settled: [CKError.Code] = [
            .quotaExceeded,
            .permissionFailure,
            .notAuthenticated,
            .unknownItem,
            .invalidArguments,
            .serverRecordChanged,
            .limitExceeded,
            .partialFailure
        ]

        for code in settled {
            #expect(!SyncRetryPolicy.isTransient(code), "\(code.rawValue) should not be retried")
        }
    }

    /// Under a rate limit the server's own number is the only wait that clears it.
    @Test("The server's requested wait wins over the local backoff")
    func serverDelayWins() {
        #expect(SyncRetryPolicy.delay(retryAfterSeconds: 30, attempt: 0) == 30)
        #expect(SyncRetryPolicy.delay(retryAfterSeconds: 30, attempt: 4) == 30)
        #expect(SyncRetryPolicy.delay(retryAfterSeconds: 0.5, attempt: 2) == 0.5)
    }

    @Test("Without a requested wait the backoff doubles from one second")
    func localBackoffDoubles() {
        let waits = (0 ..< 5).map { SyncRetryPolicy.delay(retryAfterSeconds: nil, attempt: $0) }

        #expect(waits == [1, 2, 4, 8, 16])
    }

    /// `1 << attempt` is undefined for a negative shift and traps in Swift, so the floor is not
    /// decoration: it is what keeps a caller's arithmetic slip from crashing the sync.
    @Test("A negative attempt still produces the first wait")
    func negativeAttemptIsFloored() {
        #expect(SyncRetryPolicy.delay(retryAfterSeconds: nil, attempt: -1) == 1)
    }

    /// Nothing tells an app that iCloud storage was freed, so the timer is one of only two ways back.
    @Test("Full storage waits five minutes, doubling to an hour")
    func storageFullBacksOff() {
        let waits = (1 ... 6).map {
            SyncRetryPolicy.nextAttemptDelay(after: .blocked(.storageFull), consecutiveFailures: $0, retryAfter: nil)
        }

        #expect(waits == [300, 600, 1_200, 2_400, 3_600, 3_600])
    }

    @Test("The server's longer wait wins over the backoff")
    func serverWaitWinsAcrossRuns() {
        #expect(SyncRetryPolicy.nextAttemptDelay(after: .blocked(.storageFull), consecutiveFailures: 1, retryAfter: 316) == 316)
        #expect(SyncRetryPolicy.nextAttemptDelay(after: .busy, consecutiveFailures: 1, retryAfter: 90) == 90)
        #expect(SyncRetryPolicy.nextAttemptDelay(after: .busy, consecutiveFailures: 1, retryAfter: 5) == 30)
    }

    @Test("A throttle waits thirty seconds, doubling to fifteen minutes")
    func busyBacksOff() {
        #expect(SyncRetryPolicy.nextAttemptDelay(after: .busy, consecutiveFailures: 1, retryAfter: nil) == 30)
        #expect(SyncRetryPolicy.nextAttemptDelay(after: .busy, consecutiveFailures: 3, retryAfter: nil) == 120)
        #expect(SyncRetryPolicy.nextAttemptDelay(after: .busy, consecutiveFailures: 40, retryAfter: nil) == 900)
    }

    @Test("A condition only a trigger can clear has no timer", arguments: [
        SyncError.blocked(.signedOut),
        .blocked(.accountNotReady),
        .blocked(.dataDeletedFromICloud),
        .blocked(.appUpdateRequired),
        .offline,
        .recordsRejected(count: 2),
        .pullNotSaved,
        .unexpected
    ])
    func noTimerWithoutABackoff(_ error: SyncError) {
        #expect(SyncRetryPolicy.nextAttemptDelay(after: error, consecutiveFailures: 1, retryAfter: 60) == nil)
    }
}
