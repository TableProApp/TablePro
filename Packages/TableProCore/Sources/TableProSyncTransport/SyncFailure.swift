import CloudKit
import Foundation

/// What a CloudKit failure means for sync.
///
/// CloudKit reports a failure for a whole operation, or for each record inside a partial failure,
/// and a code means the same thing on either channel. Classifying it once, here, is what keeps a
/// full iCloud from reaching the person as a raw record id on one channel and as plain words on the
/// other, and keeps the retry decision and the message from disagreeing.
public enum SyncFailure: Equatable, Sendable {
    /// Every request fails until the account, the data or the app changes.
    case blocked(SyncBlocker)

    /// The device cannot reach iCloud.
    case offline

    /// CloudKit asked to be tried again later: a throttle, a busy zone, a lost response.
    case busy

    /// CloudKit refused this request, and sending it again unchanged will not help soon.
    case failed

    /// The pull position is no longer valid; a full fetch replaces it.
    case tokenExpired

    /// The operation was cancelled. Not an outcome to report.
    case cancelled

    /// Exhaustive on purpose: a code a later SDK adds is a compiler warning here, not a silent
    /// `failed`.
    public init(code: CKError.Code) {
        switch code {
        case .quotaExceeded:
            self = .blocked(.storageFull)
        case .notAuthenticated:
            self = .blocked(.signedOut)
        case .accountTemporarilyUnavailable:
            self = .blocked(.accountNotReady)
        case .managedAccountRestricted:
            self = .blocked(.accountRestricted)
        /// TablePro never deletes its zone, so a zone that is gone was removed from outside: in
        /// iCloud settings, or by an encrypted data reset. Apple says neither may be uploaded again
        /// on the app's own initiative, so both wait for the person.
        case .userDeletedZone, .zoneNotFound:
            self = .blocked(.dataDeletedFromICloud)
        case .incompatibleVersion:
            self = .blocked(.appUpdateRequired)
        case .badContainer, .missingEntitlement, .badDatabase, .permissionFailure:
            self = .blocked(.unavailable)
        case .networkUnavailable, .networkFailure:
            self = .offline
        case .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost:
            self = .busy
        case .changeTokenExpired:
            self = .tokenExpired
        case .operationCancelled:
            self = .cancelled
        case .internalError, .partialFailure, .unknownItem, .invalidArguments, .resultsTruncated,
             .serverRecordChanged, .serverRejectedRequest, .assetFileNotFound, .assetFileModified,
             .constraintViolation, .batchRequestFailed, .limitExceeded, .tooManyParticipants,
             .alreadyShared, .referenceViolation, .participantMayNeedVerification, .assetNotAvailable,
             .participantAlreadyInvited:
            self = .failed
        @unknown default:
            self = .failed
        }
    }

    /// Classifies anything a sync operation throws. A partial failure is judged by its most severe
    /// item, because its own code says only that items failed.
    public init(_ error: any Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        if let interruption = error as? SyncPushInterruption {
            self.init(interruption.cause)
            return
        }
        guard let ckError = error as? CKError else {
            self = .failed
            return
        }
        guard ckError.code == .partialFailure else {
            self.init(code: ckError.code)
            return
        }
        let items = (ckError.partialErrorsByItemID ?? [:]).values.map { SyncFailure($0) }
        self = Self.mostSevere(items) ?? .failed
    }

    /// The failure that decides a run in which several items failed differently. A blocker any item
    /// hit outweighs everything, since every other item will hit it next.
    public static func mostSevere(_ failures: some Sequence<SyncFailure>) -> SyncFailure? {
        failures.max { $0.severity < $1.severity }
    }

    /// Whether the rest of an upload is pointless once one item reports this.
    public var stopsUpload: Bool {
        switch self {
        case .blocked:
            return true
        case .offline, .busy, .failed, .tokenExpired, .cancelled:
            return false
        }
    }

    private var severity: Int {
        switch self {
        case .blocked(let blocker):
            return 100 + blocker.severity
        case .offline:
            return 50
        case .busy:
            return 40
        case .tokenExpired:
            return 30
        case .failed:
            return 20
        case .cancelled:
            return 10
        }
    }
}

private extension SyncBlocker {
    /// Account-wide conditions first: they explain every other failure in the same run.
    var severity: Int {
        switch self {
        case .unavailable:
            return 7
        case .appUpdateRequired:
            return 6
        case .accountRestricted:
            return 5
        case .signedOut:
            return 4
        case .accountNotReady:
            return 3
        case .dataDeletedFromICloud:
            return 2
        case .storageFull:
            return 1
        }
    }
}
