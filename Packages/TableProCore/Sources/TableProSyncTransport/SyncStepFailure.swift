import CloudKit
import Foundation

/// How one step of a sync run failed: what the failure means for sync, what the person is told,
/// and how long CloudKit asked the next attempt to wait.
public struct SyncStepFailure: Equatable, Sendable {
    public let failure: SyncFailure
    /// Nil for a cancellation.
    public let error: SyncError?
    public let retryAfter: TimeInterval?

    public init(failure: SyncFailure, error: SyncError?, retryAfter: TimeInterval?) {
        self.failure = failure
        self.error = error
        self.retryAfter = retryAfter
    }

    public init(_ error: any Error) {
        let failure = SyncFailure(error)
        self.init(failure: failure, error: SyncError(failure), retryAfter: Self.retryAfter(of: error))
    }

    /// The failed items of an upload, or nil when every item went through.
    public init?(_ outcome: PushOutcome) {
        guard let failure = outcome.failure else { return nil }
        self.init(failure: failure, error: outcome.error, retryAfter: outcome.retryAfter)
    }

    public static let pullNotSaved = SyncStepFailure(failure: .failed, error: .pullNotSaved, retryAfter: nil)

    /// The step that decides a run where the upload and the download both reported something. A
    /// blocker or a missing zone wins wherever it came from, since it explains the rest; otherwise
    /// the download's failure is reported, because it means other devices' changes did not arrive.
    public static func decisive(upload: SyncStepFailure?, download: SyncStepFailure?) -> SyncStepFailure? {
        let stopping = [download, upload].compactMap { $0 }.filter(\.failure.stopsUpload)
        if let worst = SyncFailure.mostSevere(stopping.map(\.failure)) {
            return stopping.first { $0.failure == worst }
        }
        return download ?? upload
    }

    private static func retryAfter(of error: any Error) -> TimeInterval? {
        if let interruption = error as? SyncPushInterruption {
            return retryAfter(of: interruption.cause)
        }
        guard let ckError = error as? CKError else { return nil }
        let itemWaits = (ckError.partialErrorsByItemID ?? [:]).values.compactMap { ($0 as? CKError)?.retryAfterSeconds }
        return ([ckError.retryAfterSeconds].compactMap { $0 } + itemWaits).max()
    }
}
