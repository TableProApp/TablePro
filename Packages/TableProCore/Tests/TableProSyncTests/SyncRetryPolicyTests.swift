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
            .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy
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
}
