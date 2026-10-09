import CloudKit
import Foundation

/// How one step of a sync run failed: what the failure means for sync, what the person is told,
/// and how long CloudKit asked the next attempt to wait.
public struct SyncStepFailure: Equatable, Sendable {
    public let failure: SyncFailure
    /// Nil for a cancellation.
    public let error: SyncError?
    public let retryAfter: TimeInterval?

    /// Whether CloudKit asked to slow down anywhere in the step, even where something more severe
    /// decides what the person is told. A throttle hidden behind full storage still has to be
    /// waited out.
    public let throttled: Bool

    public init(failure: SyncFailure, error: SyncError?, retryAfter: TimeInterval?, throttled: Bool? = nil) {
        self.failure = failure
        self.error = error
        self.retryAfter = retryAfter
        self.throttled = throttled ?? (failure == .busy)
    }

    public init(_ error: any Error) {
        let failure = SyncFailure(error)
        self.init(
            failure: failure,
            error: SyncError(failure),
            retryAfter: Self.retryAfter(of: error),
            throttled: Self.isThrottled(error)
        )
    }

    /// The failed items of an upload, or nil when every item went through.
    public init?(_ outcome: PushOutcome) {
        guard let failure = outcome.failure else { return nil }
        self.init(
            failure: failure,
            error: outcome.error,
            retryAfter: outcome.retryAfter,
            throttled: outcome.failures.values.contains { $0.failure == .busy }
        )
    }

    public static let pullNotSaved = SyncStepFailure(failure: .failed, error: .pullNotSaved, retryAfter: nil)

    /// The step that decides a run where the upload and the download both reported something. A
    /// blocker wins wherever it came from, since it explains the rest; otherwise the download's
    /// failure is reported, because it means other devices' changes did not arrive. A throttle and
    /// the longest wait carry over from both steps whichever one decides.
    public static func decisive(upload: SyncStepFailure?, download: SyncStepFailure?) -> SyncStepFailure? {
        let steps = [download, upload].compactMap { $0 }
        let stopping = steps.filter(\.failure.stopsUpload)
        let chosen: SyncStepFailure?
        if let worst = SyncFailure.mostSevere(stopping.map(\.failure)) {
            chosen = stopping.first { $0.failure == worst }
        } else {
            chosen = download ?? upload
        }
        guard let chosen else { return nil }
        return SyncStepFailure(
            failure: chosen.failure,
            error: chosen.error,
            retryAfter: steps.compactMap(\.retryAfter).max(),
            throttled: steps.contains(where: \.throttled)
        )
    }

    private static func isThrottled(_ error: any Error) -> Bool {
        if let interruption = error as? SyncPushInterruption {
            return isThrottled(interruption.cause)
        }
        guard let ckError = error as? CKError else { return false }
        let items = (ckError.partialErrorsByItemID ?? [:]).values.map { SyncFailure($0) }
        return SyncFailure(code: ckError.code) == .busy || items.contains(.busy)
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
