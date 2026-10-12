import Foundation

/// What a finished run changes: the status to publish, whether Last Synced moves, and what happens
/// to the retry clock.
///
/// Pure and shared, so the Mac and the iPhone settle a run by the same rules. When each coordinator
/// carried its own, they drifted: one stamped Last Synced over a failed download, the other never
/// moved it past a rejected upload.
public struct SyncSettlement: Equatable, Sendable {
    public let status: SyncStatus

    /// Last Synced is the last run that sent this device's changes and brought the others' in.
    public let stampsLastSync: Bool

    /// Starts the backoff over: the condition that held the upload back is gone.
    public let resetsRetry: Bool

    /// The outcome that counts as one more failure in a row and sets the next attempt.
    public let countedFailure: SyncError?

    /// A full run has to follow at once: the zone came back, and the changes this device held while
    /// it was gone have not gone up yet.
    public let needsUpload: Bool

    /// CloudKit asked to slow down. Kept apart from the status, because a download that was
    /// throttled while uploads are held still has to wait, though the notice keeps the reason the
    /// uploads are held.
    public let throttles: Bool

    public init(failure: SyncStepFailure?, admission: SyncAdmission, previousError: SyncError?) {
        let unchanged: SyncStatus = previousError.map { .error($0) } ?? .idle
        let throttles = failure?.throttled ?? false

        guard let failure else {
            if admission == .full {
                self.init(status: .idle, stampsLastSync: true, resetsRetry: true, countedFailure: nil)
            } else if previousError == .blocked(.dataDeletedFromICloud) {
                /// The zone answered a download, so another device uploaded the data again.
                self.init(status: .idle, stampsLastSync: false, resetsRetry: true, countedFailure: nil, needsUpload: true)
            } else {
                /// A download while uploads were held back changes nothing about why they were held.
                self.init(status: unchanged, stampsLastSync: false, resetsRetry: false, countedFailure: nil)
            }
            return
        }

        guard let error = failure.error else {
            /// A cancelled run reports nothing, success least of all.
            self.init(status: unchanged, stampsLastSync: false, resetsRetry: false, countedFailure: nil)
            return
        }

        /// A download that stumbles while uploads are held keeps the reason they are held; losing
        /// it would let the next edit resend everything into the same wall.
        if admission == .downloadOnly, error.blocker == nil, previousError != nil {
            self.init(status: unchanged, stampsLastSync: false, resetsRetry: false, countedFailure: nil, throttles: throttles)
            return
        }

        var onlyRecordsRejected = false
        if case .recordsRejected = error {
            onlyRecordsRejected = true
        }
        self.init(
            status: .error(error),
            stampsLastSync: admission == .full && onlyRecordsRejected,
            resetsRetry: false,
            countedFailure: error,
            throttles: throttles
        )
    }

    private init(
        status: SyncStatus,
        stampsLastSync: Bool,
        resetsRetry: Bool,
        countedFailure: SyncError?,
        needsUpload: Bool = false,
        throttles: Bool = false
    ) {
        self.status = status
        self.stampsLastSync = stampsLastSync
        self.resetsRetry = resetsRetry
        self.countedFailure = countedFailure
        self.needsUpload = needsUpload
        self.throttles = throttles
    }
}
