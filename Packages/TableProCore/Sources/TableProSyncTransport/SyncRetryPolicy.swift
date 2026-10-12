//
//  SyncRetryPolicy.swift
//  TableProSyncTransport
//
//  When a CloudKit failure is worth trying again, and how long to wait.
//

import CloudKit
import Foundation

/// Pure, so the decisions a retry makes can be checked without a container.
///
/// Two horizons. Inside one run the engine retries a request CloudKit only asked it to repeat. Across
/// runs the coordinator holds the next attempt back for the conditions a quick retry cannot clear,
/// because sending the same changes on every trigger just fails the same way each time.
public enum SyncRetryPolicy: Sendable {
    /// Whether the engine repeats the request inside the same run. Read off the one classification
    /// the rest of sync uses, so the retry and the message can never disagree about a code.
    public static func isTransient(_ code: CKError.Code) -> Bool {
        switch SyncFailure(code: code) {
        case .offline, .busy:
            return true
        case .blocked, .failed, .tokenExpired, .cancelled:
            return false
        }
    }

    /// The server's own `retryAfterSeconds` wins whenever it sends one: under a rate limit it is the
    /// only wait that clears the limit, and backing off less only spends the next attempt. Without
    /// one the wait doubles from one second, so attempt 0 waits 1 and attempt 4 waits 16.
    public static func delay(retryAfterSeconds: Double?, attempt: Int) -> Double {
        if let retryAfterSeconds {
            return retryAfterSeconds
        }
        return Double(1 << max(0, attempt))
    }

    /// How long a run that ended in `error` holds the next upload back, or nil when only a trigger
    /// that changes the situation can help: the network returning, the account changing, the person
    /// choosing. `consecutiveFailures` counts this one, so the first failure passes 1.
    ///
    /// Full storage starts at five minutes and doubles to an hour. Nothing tells an app that space
    /// was freed, so a timer and the person's own Sync Now are the only ways back, and the server's
    /// wait is honored when it names a longer one.
    public static func nextAttemptDelay(
        after error: SyncError,
        consecutiveFailures: Int,
        retryAfter: TimeInterval?
    ) -> TimeInterval? {
        let backoff: (base: TimeInterval, cap: TimeInterval)
        switch error {
        case .blocked(.storageFull):
            backoff = (base: 300, cap: 3_600)
        case .busy:
            backoff = (base: 30, cap: 900)
        case .blocked, .offline, .recordsRejected, .pullNotSaved, .unexpected:
            return nil
        }
        let doublings = min(max(0, consecutiveFailures - 1), 16)
        let local = min(backoff.base * Double(1 << doublings), backoff.cap)
        return max(local, retryAfter ?? 0)
    }
}
