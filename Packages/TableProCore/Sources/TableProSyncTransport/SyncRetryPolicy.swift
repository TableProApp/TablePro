//
//  SyncRetryPolicy.swift
//  TableProSyncTransport
//
//  When a CloudKit failure is worth trying again, and how long to wait.
//

import CloudKit
import Foundation

/// Pure, so the two decisions a retry makes can be checked without a container.
///
/// Both were private to the engine and reachable only through a real `CKError` off a real network,
/// which is to say untested. The distinction that matters is the first one: retrying an error the
/// server has already decided just fails three more times and reports the last attempt's reason,
/// while not retrying a transient one drops a sync the server was only asking us to slow down.
public enum SyncRetryPolicy: Sendable {
    /// CloudKit asks to be tried again through these and only these.
    public static func isTransient(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return true
        default:
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
}
