import CloudKit
import Foundation

/// A condition of the iCloud account, or of TablePro's data in it, that fails every upload until
/// something outside the sync changes.
///
/// Kept apart from a failed run because sending the same changes again cannot clear it: only the
/// person, the account, or a later app version can. Each one is waited out in its own way.
public enum SyncBlocker: Equatable, Sendable {
    /// `quotaExceeded`. The private database counts against the person's iCloud storage, and
    /// deletes fail with it too, so nothing TablePro removes can make room. Downloads still work.
    case storageFull

    /// No Apple Account is signed in to iCloud on this device.
    case signedOut

    /// Signed in, but the account is not ready for CloudKit yet, or its state could not be read.
    /// Apple asks apps to wait for `CKAccountChanged` rather than retry.
    case accountNotReady

    /// Screen Time or device management does not allow iCloud. CloudKit calls this nonrecoverable.
    case accountRestricted

    /// TablePro's zone is gone: deleted in iCloud settings, or lost to an encrypted data reset.
    /// Apple asks apps not to upload the data again on their own, so the person decides.
    case dataDeletedFromICloud

    /// `incompatibleVersion`: the server no longer accepts this version of the app.
    case appUpdateRequired

    /// The container, database or entitlement this build syncs through is unusable. A fault of the
    /// build, which the person cannot fix.
    case unavailable

    /// The blocker an account status stands for, or nil when the account can sync.
    public init?(accountStatus: CKAccountStatus) {
        switch accountStatus {
        case .available:
            return nil
        case .noAccount:
            self = .signedOut
        case .restricted:
            self = .accountRestricted
        case .couldNotDetermine, .temporarilyUnavailable:
            self = .accountNotReady
        @unknown default:
            self = .accountNotReady
        }
    }

    /// Whether downloads keep working while this holds. Full storage limits writes only.
    public var allowsDownloads: Bool {
        self == .storageFull
    }

    /// Whether the account itself, rather than TablePro's data or build, is what stops sync. A fresh
    /// account status read settles which of these applies, since CloudKit reports all of them to an
    /// operation as `notAuthenticated`.
    public var isAccountState: Bool {
        switch self {
        case .signedOut, .accountNotReady, .accountRestricted:
            return true
        case .storageFull, .dataDeletedFromICloud, .appUpdateRequired, .unavailable:
            return false
        }
    }
}
