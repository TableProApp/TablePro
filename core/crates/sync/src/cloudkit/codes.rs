// A per-record `CKError.Code` as Swift hands it over, for a fetch by name and a modify alike. Swift decides nothing
// (0054), so the engine reads each code as the Swift engine's `SyncFailure` did.

use crate::api::cloudkit::CloudKitFailure;

pub(super) enum Failure {
    // Every record that follows fails the same way: the upload stops, and the pass with it.
    Stops(CloudKitFailure),
    // CloudKit asks to be tried again later, or the network dropped: the pass ends as a throttle, so the scheduler tries
    // again.
    Later,
    TooLarge,
    Retry,
}

pub(super) const fn failure(code: i64) -> Failure {
    match code {
        9 => Failure::Stops(CloudKitFailure::NoAccount),
        25 => Failure::Stops(CloudKitFailure::QuotaExceeded),
        26 => Failure::Stops(CloudKitFailure::ZoneNotFound),
        28 => Failure::Stops(CloudKitFailure::ZoneDeletedByUser),
        32 => Failure::Stops(CloudKitFailure::Restricted),
        36 => Failure::Stops(CloudKitFailure::AccountTemporarilyUnavailable),
        // A container, entitlement, database or permission CloudKit refuses, or an app it finds too old.
        5 | 8 | 10 | 18 | 24 => Failure::Stops(CloudKitFailure::Other { code }),
        3 | 4 | 6 | 7 | 23 | 34 => Failure::Later,
        27 => Failure::TooLarge,
        _ => Failure::Retry,
    }
}

pub(super) const fn later(code: i64) -> bool {
    matches!(failure(code), Failure::Later)
}
